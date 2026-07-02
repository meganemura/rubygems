# frozen_string_literal: true

require "open3"

class Gem::CredentialStore; end unless defined?(Gem::CredentialStore)

##
# Stores credentials in the macOS Keychain via the +security+ command line
# tool. +security+ has no way to read a password from stdin as raw bytes
# for +add-generic-password+, so #set uses +security -i+ (batch/interactive
# mode, one tokenized command per stdin line) to keep the secret off argv
# and out of +ps+ output.
#
# The secret is limited to printable ASCII. A newline would start a second
# command in the +security -i+ batch, and +security find-generic-password
# -w+ prints any non-printable byte back as a hex string rather than the
# original value, so a non-ASCII secret would round-trip corrupted. #set
# rejects such secrets so the caller falls back to file storage instead of
# silently storing something it cannot read back. The account and service
# are likewise refused a newline to keep them from injecting a second batch
# command.

class Gem::CredentialStore::MacOSBackend
  NOT_FOUND_STATUS = 44
  PRINTABLE_ASCII = /\A[\x20-\x7e]*\z/

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
    raise ArgumentError, "credential secret must be printable ASCII for the macOS keychain" unless secret.match?(PRINTABLE_ASCII)
    raise ArgumentError, "credential account must not contain a newline" if account.include?("\n")
    raise ArgumentError, "credential service must not contain a newline" if service.include?("\n")

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

  # security deletes one entry per call, so keep deleting the given service
  # until it reports there is nothing left (exit 44). This only touches the
  # given service and leaves entries for other services intact.
  def self.delete_all(service)
    loop do
      _out, status = Open3.capture2(
        "security", "delete-generic-password", "-s", service,
        err: File::NULL
      )
      return true if status.exitstatus == NOT_FOUND_STATUS
      return false unless status.success?
    end
  end

  def self.quote(value)
    %("#{value.gsub("\\", "\\\\\\\\").gsub('"', '\\"')}")
  end
  private_class_method :quote
end
