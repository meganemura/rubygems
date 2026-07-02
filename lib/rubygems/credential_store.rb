# frozen_string_literal: true

##
# Gem::CredentialStore is opt-in storage for authentication secrets (API
# keys, host credentials) in the operating system's native secret store
# instead of a plain text file. Platform backends (macOS Keychain, Linux
# Secret Service, Windows Credential Manager) register themselves with
# #default_backend as they land; see the credential_store/ directory.
#
# Every public method traps all errors and returns +nil+/+false+ instead of
# raising, so that callers can transparently fall back to their existing
# file-based storage when the native store is unavailable or fails (a
# locked keychain over SSH, a headless Linux session without a keyring
# daemon, ...).

class Gem::CredentialStore
  SERVICE_NAME = "rubygems"

  ##
  # The single, process-wide store instance. Reusing one instance keeps the
  # backend selection and the read cache shared across every caller in the
  # process, which matters most on Windows where each PowerShell
  # invocation costs hundreds of milliseconds.

  def self.instance
    @instance ||= new
  end

  ##
  # Overrides the memoized #instance. Intended for tests that need to
  # inject a store backed by a fake backend.

  def self.instance=(instance)
    @instance = instance
  end

  ##
  # Resets the memoized #instance and the one-time warning flag. Intended
  # for tests only.

  def self.reset!
    @instance = nil
    @warned = false
  end

  def self.warn_once(message)
    return if @warned
    @warned = true
    Gem.ui.alert_warning message
  end

  ##
  # No native backend is registered yet; macOS, Linux, and Windows support
  # land in follow-up commits, each adding its own branch here and
  # requiring only its own backend file.

  def self.default_backend
    nil
  end

  ##
  # +backend+ is only used by tests to inject a fake backend regardless of
  # the platform the test suite happens to run on.

  def initialize(backend: self.class.default_backend)
    @backend = backend
    @cache = {}
  end

  ##
  # True if a native credential backend is usable on this platform.

  def available?
    !@backend.nil?
  end

  ##
  # Returns the secret stored for +account+, or +nil+ if there is none or
  # the backend is unavailable/fails.

  def get(account)
    return nil unless @backend
    return @cache[account] if @cache.key?(account)

    @cache[account] = @backend.get(SERVICE_NAME, account)
  rescue StandardError => e
    warn_failure(e)
    nil
  end

  ##
  # Stores +secret+ for +account+. Returns +true+ on success.

  def set(account, secret)
    return false unless @backend

    if @backend.set(SERVICE_NAME, account, secret)
      @cache[account] = secret
      true
    else
      false
    end
  rescue StandardError => e
    warn_failure(e)
    false
  end

  ##
  # Removes the secret stored for +account+. Returns +true+ if the entry is
  # gone, whether or not it existed beforehand.

  def delete(account)
    return false unless @backend

    result = @backend.delete(SERVICE_NAME, account)
    @cache.delete(account)
    result
  rescue StandardError => e
    warn_failure(e)
    false
  end

  private

  def warn_failure(error)
    self.class.warn_once "Credential store unavailable (#{error.class}: #{error.message}); falling back to file storage."
  end
end
