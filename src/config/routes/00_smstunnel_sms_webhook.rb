# Copyright (c) 2026 NARBOWEB SRL. Licensed under the MIT License.

# The file name sorts this before Zammad's channel_sms.rb. The constraint matches only the token of
# an active SMSTunnel channel, so every other webhook request goes on to Zammad's own route.
Zammad::Application.routes.draw do
  api_path = Rails.configuration.api_path

  match "#{api_path}/sms_webhook/:token",
        to:          'channels_sms_smstunnel#webhook',
        via:         %i[get post],
        constraints: ->(request) { Channel::Driver::Sms::Smstunnel.webhook_channel(request.path_parameters[:token]).present? }
end
