# Copyright (c) 2026 NARBOWEB SRL. Licensed under the MIT License.

# Nothing to add on install. On uninstall the SMSTunnel channels go too: without this package they
# could only fail, and their API key and signing secret should not stay behind in the database.
class SmstunnelChannelCleanup
  def self.up; end

  def self.down
    Channel.where(area: %w[Sms::Account Sms::Notification]).find_each do |channel|
      channel.destroy! if channel.options[:adapter] == 'sms/smstunnel'
    end
  end
end
