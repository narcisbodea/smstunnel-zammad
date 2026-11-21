# Copyright (c) 2026 NARBOWEB SRL. Licensed under the MIT License.

# SMSTunnel as an SMS provider in Zammad. Texts go out as ordinary texts from the user's own
# Android phone, and the texts that phone receives reach Zammad through the SMS webhook.
#
# Nothing here writes a phone number, a text or a key to Zammad's log.
class Channel::Driver::Sms::Smstunnel < Channel::Driver::Sms::Base
  NAME = 'sms/smstunnel'.freeze

  # Fixed on purpose: no setting can point the API key at another host.
  SEND_URL = 'https://smstunnel.io/api/v1/sms/send'.freeze

  SIGNATURE_HEADER = 'X-SMSTunnel-Signature'.freeze

  # SMSTunnel answers a repeated Idempotency-Key from memory for 24 hours. A text older than
  # this is not tried at all, because past that window a repeat could reach someone twice.
  RETRY_WINDOW = 23.hours

  NOT_INTERNATIONAL = 'A number is not in international format (+ and country code), so nothing was sent to it.'.freeze
  REFUSED           = 'SMSTunnel refused a number or the text, so nothing was sent to it.'.freeze
  UNCLEAR           = 'No clear answer from SMSTunnel. The text may already have gone out, so check the phone before sending it again.'.freeze
  UNKNOWN_CALLER    = 'This version of Zammad sends SMS in a way the SMSTunnel package does not know, so the text was not sent. Update the package.'.freeze

  # No answer, the key, the phone or the limit: the next number would fail the same way, so the job
  # stops here and Zammad's retry picks it up. Any other failure belongs to one number, and SMSTunnel
  # may remember it for that number's key, so it must not cost the numbers after it their text.
  STOPS_EVERY_NUMBER = [0, 401, 403, 404, 429].freeze

  # What #process answers. The webhook controller ignores it; SMSTunnel only reads the status.
  RECEIVED = ['application/json; charset=UTF-8', '{}'].freeze

  # What no retry can change, so agents are told at once.
  NEVER_WILL_SEND = [NOT_INTERNATIONAL, REFUSED].freeze

  # CommunicateSmsJob's `retry_on ... attempts: 4`.
  LAST_TRY = 4

  # Why a text was not handed over. Its message reaches agents and the log, so it never holds a
  # number, the text or the key.
  class NotSent < StandardError
    attr_reader :final

    def initialize(message, channel_at_fault: false, final: false)
      super(message)
      @channel_at_fault = channel_at_fault
      @final            = final
    end

    # Zammad's way of asking whether to mark the whole channel as failing.
    def retryable?
      !@channel_at_fault
    end
  end

  # What the running CommunicateSmsJob knows about the text. Zammad gives a driver only a number
  # and a body, and repeats the whole job after any failure, so the key that makes those repeats
  # safe has to come from the article.
  class TextJob
    def self.current
      job = ActiveSupport::ExecutionContext.to_h[:job]
      return if !job.is_a?(CommunicateSmsJob)

      article = Ticket::Article.find_by(id: job.arguments.first)
      new(job, article) if article
    end

    def initialize(job, article)
      @job     = job
      @article = article
    end

    def check!
      channel = Channel.find_by(id: channel_id)
      raise NotSent, 'This SMS channel is turned off, so the text was not sent.' if channel && !channel.active
      return if @article.created_at >= RETRY_WINDOW.ago

      raise NotSent.new('This text is more than 23 hours old, so it was not sent. Send it again if it still matters.', final: true)
    end

    # Per article and number: a repeat of this job gets the first answer back instead of a second
    # text, and two articles with the same words stay two texts. The time keeps an article id that
    # a restored backup hands out again from meeting the key of the article it replaced.
    def idempotency_key(number)
      "zammad-#{@article.id}-#{@article.created_at.to_i}-#{Digest::SHA256.hexdigest(number)[0, 16]}"
    end

    # The phone that received the customer's last text, so that a reply comes from the number the
    # customer wrote to. Nil for a notification, which goes from the account's main phone.
    def phone_id
      return if system_article?

      customer  = Ticket::Article::Sender.find_by(name: 'Customer')
      last_text = Ticket::Article
        .where(ticket_id: @article.ticket_id, type_id: @article.type_id, sender_id: customer.id)
        .where('id < ?', @article.id)
        .reorder(id: :desc)
        .first
      last_text&.preferences&.dig('sms', 'PhoneId')
    end

    # A number that can't be used must not cost the numbers after it their text, so a refusal is
    # raised only once every number of this article has had its turn.
    def after_turn(recipient, refusal)
      refusals = @job.instance_variable_get(:@smstunnel_refusals) || {}
      refusals = refusals.merge(recipient => refusal) if refusal
      @job.instance_variable_set(:@smstunnel_refusals, refusals)
      return if refusals.empty? || recipient != numbers.last

      message = refusals.values.first
      message = "#{refusals.size} of #{numbers.size} numbers: #{message}" if numbers.size > 1
      raise NotSent.new(message, final: refusals.values.all? { |text| NEVER_WILL_SEND.include?(text) })
    end

    # Zammad means to add a "Delivery failed" note when an SMS fails for good, but in 7.2 that step
    # crashes first (the job calls a max_attempts that doesn't exist), and a text that never left
    # would look sent in the ticket. So the package adds the same note, once per text, unless this
    # Zammad can do it itself. A failure to write the note never changes what happens to the text.
    def report(failure)
      return if !failure.final && @job.executions < LAST_TRY
      return if @job.respond_to?(:max_attempts, true) || reported?

      Ticket::Article.create!(
        ticket_id:     @article.ticket_id,
        content_type:  'text/plain',
        body:          "Unable to send SMS message: #{failure.message}",
        internal:      true,
        sender:        Ticket::Article::Sender.find_by(name: 'System'),
        type:          Ticket::Article::Type.find_by(name: 'note'),
        preferences:   { delivery_article_id_related: @article.id, delivery_message: true },
        updated_by_id: 1,
        created_by_id: 1,
      )
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error "SMSTunnel: could not add the delivery note (#{e.class})"
    end

    private

    def reported?
      Ticket::Article
        .where(ticket_id: @article.ticket_id, internal: true, type_id: Ticket::Article::Type.find_by(name: 'note').id)
        .any? { |note| note.preferences['delivery_article_id_related'] == @article.id }
    end

    def system_article?
      @article.sender&.name == 'System'
    end

    def channel_id
      return @article.preferences['channel_id'] if system_article?

      Ticket.find_by(id: @article.ticket_id)&.preferences&.fetch('channel_id', nil)
    end

    def numbers
      return [@article.to] if !system_article?

      Array(@article.preferences['sms_recipients']).uniq
    end
  end

  # A forwarded event whose signature was checked. The webhook controller is the only place that
  # makes one, and #process refuses anything else. The text and the sender inside it are whatever
  # a stranger typed into a phone, so they are cleaned here and treated as plain data.
  class SignedEvent
    SIGNATURE = %r{\Asha256=([0-9a-f]{64})\z}i
    SENDER    = %r{\A(?:\+[1-9]\d{6,14}|\d{7,15})\z}
    TEXT_ID   = %r{\A[A-Za-z0-9_-]{1,64}\z}
    PHONE_ID  = %r{\A[0-9a-f]{24}\z}

    attr_reader :from, :body, :message_id, :phone_id

    def self.from_request(secret:, body:, signature:)
      return if !valid_signature?(secret, body, signature)

      data = JSON.parse(body)
      new(data) if data.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def self.valid_signature?(secret, body, signature)
      return false if secret.blank? || body.nil?

      given = SIGNATURE.match(signature.to_s.strip)
      return false if !given

      expected = OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, body)
      ActiveSupport::SecurityUtils.secure_compare(expected, given[1].downcase)
    end

    def initialize(data)
      @event      = data['event']
      @test       = data['test'] == true
      @encrypted  = data['encrypted'] == true
      @from       = sender(data['from'])
      @body       = clean(data['message'])
      text_id     = data['id'].to_s
      @message_id = "smstunnel:#{text_id}" if text_id.match?(TEXT_ID)
      phone       = data['phone'].is_a?(Hash) ? data['phone']['deviceId'].to_s : ''
      @phone_id   = phone if phone.match?(PHONE_ID)
    end

    # False for SMSTunnel's "Send a test", for a text only the phone can read, and for a sender
    # that is a name or a short code: nobody can answer those, and they are mostly automated
    # messages such as sign-in codes, which don't belong in a shared helpdesk.
    def ticket_worthy?
      @event == 'sms.received' && !@test && !@encrypted && from.present? && body.present? && message_id.present?
    end

    def title
      body.squish
    end

    private

    def sender(value)
      number = value.to_s.gsub(%r{[[:space:]-]}, '')
      number if number.match?(SENDER)
    end

    def clean(value)
      return '' if !value.is_a?(String)

      value.scrub('').gsub("\r\n", "\n").gsub(%r{[\p{Cc}&&[^\n\t]]}, '').strip
    end
  end

  # The active SMSTunnel account channel this webhook token belongs to, if any.
  def self.webhook_channel(token)
    Channel.where(active: true, area: 'Sms::Account').find do |channel|
      channel.options[:adapter] == 'sms/smstunnel' && token_of?(channel, token)
    end
  end

  # Whether this package answers a webhook request: for the token of an SMSTunnel channel, on or off,
  # and for SMSTunnel's own requests to an address no channel has any more. Those carry a number and
  # a private text, which Zammad's controller would write to its log. Every other request is left to
  # Zammad, including one with this header that names another provider's channel.
  def self.webhook_request?(request)
    token   = request.path_parameters[:token]
    channel = Channel.where(area: 'Sms::Account').find { |candidate| token_of?(candidate, token) }
    return channel.options[:adapter] == 'sms/smstunnel' if channel

    request.headers[SIGNATURE_HEADER].present?
  end

  def self.token_of?(channel, token)
    channel.options[:webhook_token].present? && token.present? &&
      ActiveSupport::SecurityUtils.secure_compare(channel.options[:webhook_token].to_s, token.to_s)
  end

  # The number as SMSTunnel should get it, or nil: only + and a country code are ever sent, so the
  # API can never complete a bare number with a default country. Spaces and dashes are dropped.
  # Brackets are not, because "+49 (0) 171" would become a different number.
  def self.international_number(value)
    number = value.to_s.gsub(%r{[[:space:]-]}, '')
    number if number.match?(%r{\A\+[1-9]\d{6,14}\z})
  end

  def fetchable?(_channel)
    false
  end

  def deliver(options, attr, _notification = false)
    return true if Setting.get('import_mode')

    job = TextJob.current
    raise NotSent, UNKNOWN_CALLER if !job && !test_button?

    job&.check!

    number  = self.class.international_number(attr[:recipient])
    refusal = number ? hand_over(options, number, attr[:message], job) : NOT_INTERNATIONAL
    raise NotSent, refusal if refusal && !job

    job&.after_turn(attr[:recipient], refusal)
    true
  rescue NotSent => e
    job&.report(e)
    raise
  end

  def process(_options, attr, channel)
    raise Exceptions::Forbidden, 'This text was not signed by SMSTunnel.' if !attr.is_a?(SignedEvent)
    return RECEIVED if !attr.ticket_worthy?

    # One text at a time per channel: SMSTunnel may repeat a text whose answer came late, and two
    # texts from one number must land on one ticket.
    channel.with_lock do
      next if Ticket::Article.exists?(message_id_md5: Digest::MD5.hexdigest(attr.message_id), type_id: article_type_sms.id)

      user = user_by_mobile(attr.from)
      UserInfo.current_user_id = user.id

      process_ticket(attr, channel, user)
    end

    RECEIVED
  end

  def create_ticket(attr, channel, user)
    ticket = Ticket.new(
      group_id:    channel.group_id,
      title:       cut_title(attr.title),
      state_id:    Ticket::State.find_by(default_create: true).id,
      priority_id: Ticket::Priority.find_by(default_create: true).id,
      customer_id: user.id,
      preferences: {
        channel_id: channel.id,
        sms:        { From: attr.from, PhoneId: attr.phone_id },
      }
    )
    ticket.save!
    ticket
  end

  def create_article(attr, channel, ticket)
    Ticket::Article.create!(
      ticket_id:    ticket.id,
      type:         article_type_sms,
      sender:       Ticket::Article::Sender.find_by(name: 'Customer'),
      body:         attr.body,
      from:         attr.from,
      message_id:   attr.message_id,
      content_type: 'text/plain',
      preferences:  {
        channel_id: channel.id,
        sms:        { From: attr.from, PhoneId: attr.phone_id },
      }
    )
  end

  def self.definition
    {
      name:         'SMSTunnel',
      adapter:      'sms/smstunnel',
      account:      [
        { name: 'options::webhook_token', display: __('Webhook Token'), tag: 'input', type: 'text', limit: 200, null: false, default: SecureRandom.hex(20), disabled: true, readonly: true },
        { name: 'options::token', display: 'API Key', tag: 'input', type: 'password', single: true, limit: 200, null: false, placeholder: 'sk_live_...', autocomplete: 'new-password' },
        { name: 'options::app_secret', display: 'Signing Secret', tag: 'input', type: 'password', single: true, limit: 200, null: true, placeholder: 'whsec_...', autocomplete: 'new-password' },
        { name: 'group_id', display: __('Destination Group'), tag: 'tree_select', null: false, relation: 'Group', nulloption: true, filter: { active: true } },
      ],
      notification: [
        { name: 'options::token', display: 'API Key', tag: 'input', type: 'password', single: true, limit: 200, null: false, placeholder: 'sk_live_...', autocomplete: 'new-password' },
      ],
    }
  end

  private

  # The only send without a job, and never repeated. Outside these two, a retry could not be made
  # safe, so nothing is sent.
  def test_button?
    ActiveSupport::ExecutionContext.to_h[:controller].is_a?(ChannelsSmsController)
  end

  # Nil when SMSTunnel took the text, or a sentence when this one number failed. What would fail for
  # every number raises: Zammad then repeats the job, and the same Idempotency-Key keeps that harmless.
  def hand_over(options, number, message, job)
    return if Setting.get('developer_mode')

    key = api_key(options)

    text        = { to: number, message: message.to_s }
    idempotency = job&.idempotency_key(number)
    phone_id    = job&.phone_id
    result      = post_text(phone_id ? text.merge(deviceId: phone_id) : text, key, idempotency)

    # A 404 sends nothing: that phone has left the account, so its main phone answers instead. It
    # gets its own key, because SMSTunnel ties a key to the phone it was first used with.
    result = post_text(text, key, idempotency && "#{idempotency}-main") if phone_id && result.code.to_i == 404

    status = result.code.to_i
    return if status.between?(200, 299) && result.data.is_a?(Hash) && result.data['success'] == true

    failure = failure_for(status)
    raise failure if STOPS_EVERY_NUMBER.include?(status)

    failure.message
  end

  def post_text(text, key, idempotency)
    headers = { 'X-API-Key' => key, 'Accept' => 'application/json' }
    headers['Idempotency-Key'] = idempotency if idempotency

    UserAgent.post(
      SEND_URL,
      text,
      {
        json:                    true,
        headers:                 headers,
        do_not_follow_redirects: true,
        open_timeout:            10,
        read_timeout:            30,
        total_timeout:           40,
      }
    )
  end

  def api_key(options)
    key = options[:token].to_s.strip
    raise NotSent.new('No SMSTunnel API key is set for this channel.', channel_at_fault: true) if key.empty?
    # Zammad's test form holds the mask of a saved key, never the key itself.
    raise NotSent, 'Enter the SMSTunnel API key again to test this channel.' if key.match?(%r{\A\*+\z})

    key
  end

  def failure_for(status)
    case status
    when 400
      NotSent.new(REFUSED)
    when 401
      NotSent.new('SMSTunnel refused the API key, so nothing was sent. Check it under Channels > SMS.', channel_at_fault: true)
    when 403
      NotSent.new('This SMSTunnel API key may not send texts, so nothing was sent.', channel_at_fault: true)
    when 404
      NotSent.new('SMSTunnel found no phone to send this from, so nothing was sent.', channel_at_fault: true)
    when 409
      NotSent.new('SMSTunnel is still handling this text. It will not be sent twice.')
    when 422
      NotSent.new('SMSTunnel already has a different text for this send, so this one was not sent.')
    when 429
      NotSent.new('SMSTunnel limit reached (too many requests, or the daily allowance of the plan), so this text was not sent.')
    else
      NotSent.new(UNCLEAR)
    end
  end
end
