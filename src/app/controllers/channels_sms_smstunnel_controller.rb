# Copyright (c) 2026 NARBOWEB SRL. Licensed under the MIT License.

# Zammad's SMS webhook address, for requests that belong to SMSTunnel (see
# config/routes/00_smstunnel_sms_webhook.rb). Every other request keeps going to Zammad's own
# controller. A text is taken only with a valid SMSTunnel signature over the exact bytes received;
# a refusal changes nothing, not even the channel's status.
class ChannelsSmsSmstunnelController < ApplicationController
  # A forwarded text is a few KB. Anything far larger is refused before it is read or hashed.
  MAX_BODY_BYTES = 2.megabytes

  # A server calling with a signature: no browser session, and nothing may read the unverified body.
  skip_before_action :verify_csrf_token, :session_update, :user_device_log, raise: false
  skip_after_action  :set_csrf_token_headers, raise: false

  def webhook
    # The answer Zammad gives for a channel that is off or gone.
    channel = Channel::Driver::Sms::Smstunnel.webhook_channel(request.path_parameters[:token])
    return render(json: { message: 'channel not found' }, status: :not_found) if !channel
    return head(:method_not_allowed) if !request.post?

    event = Channel::Driver::Sms::Smstunnel::SignedEvent.from_request(
      secret:    channel.options[:app_secret],
      body:      request.raw_post,
      signature: request.headers[Channel::Driver::Sms::Smstunnel::SIGNATURE_HEADER],
    )
    if !event
      Rails.logger.warn 'SMSTunnel webhook: refused a request without a valid signature.'
      return head(:unauthorized)
    end

    ApplicationHandleInfo.in_context('sms') { channel.process(event) }
    head :ok
  end

  private

  # Rails writes every request's parameters to the log, and these are a phone number and a
  # private text. This request alone is logged with all of its values filtered.
  def process_action(*)
    request.set_header('action_dispatch.parameter_filter', [%r{.}])
    # No session row and no cookie for a caller that isn't a browser, signed or not.
    request.session_options[:skip] = true
    return head(:payload_too_large) if request.content_length.to_i > MAX_BODY_BYTES

    super
  end
end
