# frozen_string_literal: true

# Checks the driver's rules inside a real Zammad with the package installed. Sends nothing.
#   bundle exec rails r /path/to/driver_checks.rb

driver = Channel::Driver::Sms::Smstunnel
event  = driver::SignedEvent
failed = 0

check = lambda do |name, passed|
  puts "#{passed ? 'PASS' : 'FAIL'}  #{name}"
  failed += 1 if !passed
end

# The test vector from SMSTunnel's API reference.
secret    = 'whsec_test_secret_for_docs'
body      = '{"event":"sms.received","id":"6745e3c2a1b2c3d4e5f60718","from":"+14155550100","message":"Hello"}'
signature = 'sha256=523c53167f5741fcbde6a13211ecefd5605ee8c76365c8c61bbef7e136be9e13'

check.call('the published test vector verifies', event.valid_signature?(secret, body, signature))
check.call('uppercase hex verifies', event.valid_signature?(secret, body, "sha256=#{signature.delete_prefix('sha256=').upcase}"))
check.call('another secret fails', !event.valid_signature?('whsec_other', body, signature))
check.call('another body fails', !event.valid_signature?(secret, "#{body} ", signature))
check.call('no signature fails', !event.valid_signature?(secret, body, nil))
check.call('no prefix fails', !event.valid_signature?(secret, body, signature.delete_prefix('sha256=')))
check.call('an empty secret fails', !event.valid_signature?('', body, "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', '', body)}"))
check.call('a nil secret fails', !event.valid_signature?(nil, body, signature))

{
  '+14155550100'        => '+14155550100',
  '+1 415 555 0100'     => '+14155550100',
  '+1-415-555-0100'     => '+14155550100',
  " +40722123456\n"     => '+40722123456',
  '0722123456'          => nil,
  '40722123456'         => nil,
  '0040722123456'       => nil,
  '+0722123456'         => nil,
  '+49 (0) 171 1234567' => nil,
  '+123456'             => nil,
  '+1234567890123456'   => nil,
  '+14155550100,+1415'  => nil,
  'abc'                 => nil,
  ''                    => nil,
}.each do |written, expected|
  check.call("number #{written.inspect} -> #{expected.inspect}", driver.international_number(written) == expected)
end

signed = ->(overrides) { event.new({ 'event' => 'sms.received', 'id' => 'a1', 'from' => '+14155550100', 'message' => 'Hi' }.merge(overrides)) }

check.call('a normal text is a ticket', signed.call({}).ticket_worthy?)
check.call('a national number is a ticket', signed.call('from' => '0722123456').ticket_worthy?)
check.call('a test event is not', !signed.call('test' => true).ticket_worthy?)
check.call('an encrypted text is not', !signed.call('encrypted' => true, 'message' => nil).ticket_worthy?)
check.call('a sender name is not', !signed.call('from' => 'MYBANK').ticket_worthy?)
check.call('a short code is not', !signed.call('from' => '12345').ticket_worthy?)
check.call('an empty text is not', !signed.call('message' => " \n ").ticket_worthy?)
check.call('another event is not', !signed.call('event' => 'other').ticket_worthy?)
check.call('an unusable id is not', !signed.call('id' => "x' OR 1=1").ticket_worthy?)
check.call('control characters are removed', signed.call('message' => "a\u0000b\r\nc\u0007").body == "ab\nc")
check.call('a phone id is kept only in its own format', signed.call('phone' => { 'deviceId' => 'a' * 24 }).phone_id == 'a' * 24 && signed.call('phone' => { 'deviceId' => 'x y' }).phone_id.nil?)

begin
  driver.new.process({}, { 'event' => 'sms.received', 'from' => '+14155550100', 'message' => 'x', 'id' => 'a1' }, nil)
  check.call('an unsigned hash is refused', false)
rescue Exceptions::Forbidden
  check.call('an unsigned hash is refused', true)
end

begin
  driver.new.deliver({ token: 'sk_live_not_used' }, { recipient: '+14155550100', message: 'x' })
  check.call('sending outside the SMS job and the test button is refused', false)
rescue driver::NotSent
  check.call('sending outside the SMS job and the test button is refused', true)
end

puts failed.zero? ? 'All checks passed' : "#{failed} failed"
exit(failed.zero? ? 0 : 1)
