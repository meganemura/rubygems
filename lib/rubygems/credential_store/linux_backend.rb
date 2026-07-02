# frozen_string_literal: true

require "open3"

class Gem::CredentialStore; end unless defined?(Gem::CredentialStore)

##
# Stores credentials in the Secret Service API (GNOME Keyring, KWallet,
# ...) via the +secret-tool+ command line tool from libsecret.

class Gem::CredentialStore::LinuxBackend
  def self.available?
    return @available if defined?(@available)

    @available = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, "secret-tool"))
    end
  end

  ##
  # Clears the memoized #available? result. Intended for tests only.

  def self.reset!
    remove_instance_variable(:@available) if defined?(@available)
  end

  def self.get(service, account)
    out, status = Open3.capture2(
      "secret-tool", "lookup", "service", service, "account", account,
      err: File::NULL
    )
    return nil unless status.success?

    secret = out.chomp
    secret.empty? ? nil : secret
  end

  def self.set(service, account, secret)
    _out, status = Open3.capture2(
      "secret-tool", "store", "--label=RubyGems", "service", service, "account", account,
      stdin_data: secret
    )
    status.success?
  end

  def self.delete(service, account)
    _out, err, status = Open3.capture3(
      "secret-tool", "clear", "service", service, "account", account
    )
    return true if status.success?

    # secret-tool clear exits 1 with no stderr when nothing matched.
    status.exitstatus == 1 && err.to_s.strip.empty?
  end
end
