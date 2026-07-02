# frozen_string_literal: true

require "open3"

class Gem::CredentialStore; end unless defined?(Gem::CredentialStore)

##
# Stores credentials in the macOS Keychain via the +security+ command line
# tool. +security+ has no way to read a password from stdin as raw bytes
# for +add-generic-password+, so #set uses +security -i+ (batch/interactive
# mode, one tokenized command per stdin line) to keep the secret off argv
# and out of +ps+ output. This means a secret containing a literal newline
# cannot be stored; that is a documented limitation, not a bug.

class Gem::CredentialStore::MacOSBackend
  NOT_FOUND_STATUS = 44

  def self.get(service, account)
    out, status = Open3.capture2(
      "security", "find-generic-password", "-a", account, "-s", service, "-w",
      err: File::NULL
    )
    return nil unless status.success?

    secret = out.chomp
    secret.empty? ? nil : secret
  end

  def self.set(service, account, secret)
    raise ArgumentError, "credential secret must not contain a newline" if secret.include?("\n")

    command = "add-generic-password -U -a #{quote(account)} -s #{quote(service)} -w #{quote(secret)}\n"
    _out, status = Open3.capture2("security", "-i", stdin_data: command, err: File::NULL)
    status.success?
  end

  def self.delete(service, account)
    _out, status = Open3.capture2(
      "security", "delete-generic-password", "-a", account, "-s", service,
      err: File::NULL
    )
    status.success? || status.exitstatus == NOT_FOUND_STATUS
  end

  def self.quote(value)
    %("#{value.gsub("\\", "\\\\\\\\").gsub('"', '\\"')}")
  end
  private_class_method :quote
end
