# frozen_string_literal: true

##
# Gem::CredentialStore is opt-in storage for authentication secrets (API
# keys, host credentials) in the operating system's native secret store
# instead of a plain text file:
#
# * macOS: Keychain, via the +security+ command line tool.
# * Linux: the Secret Service API (GNOME Keyring, KWallet, ...), via
#   +secret-tool+.
# * Windows: Credential Manager, via the +Windows.Security.Credentials.PasswordVault+
#   API from PowerShell.
#
# A third party can add another backend (1Password, pass, HashiCorp Vault,
# ...) by shipping a gem that provides
# <tt>rubygems/credential_store/backends/<name></tt> and calls
# .register_backend from it. Users then select it by name instead of +true+
# (see .resolve_backend).
#
# Every public method traps all errors and returns +nil+/+false+ instead of
# raising, so that callers can transparently fall back to their existing
# file-based storage when the native store is unavailable or fails (a
# locked keychain over SSH, a headless Linux session without a keyring
# daemon, ...).

class Gem::CredentialStore
  SERVICE_NAME = "rubygems"

  ##
  # Returns the store to use for +spec+, or +nil+ when the credential store
  # is off. +spec+ is either +true+ (use this platform's native backend) or
  # the name of a registered backend such as "1password". The store is
  # memoized per +spec+ for the life of the process, so the read cache and
  # any expensive backend startup are shared across callers. A test may
  # install a stand-in via #instance= that is returned here for any enabled
  # +spec+.

  def self.for(spec)
    return nil unless spec
    return @override if defined?(@override) && @override

    (@instances ||= {})[spec] ||= new(backend: backend_for(spec))
  end

  ##
  # The default-backed store for this platform, i.e. <tt>for(true)</tt>.
  # Kept for callers and tests that only care about the native backend.

  def self.instance
    self.for(true)
  end

  ##
  # Installs a stand-in store that .for returns for any enabled setting.
  # Intended for tests that inject a fake backend.

  def self.instance=(store)
    @override = store
  end

  ##
  # Clears the memoized stores, the injected override, and the one-time
  # warning flag. Intended for tests only.

  def self.reset!
    @override = nil
    @instances = nil
    @warned = false
  end

  def self.warn_once(message)
    return if @warned
    @warned = true
    Gem.ui.alert_warning message
  end

  ##
  # Registers +backend+ under +name+ so it can be selected with
  # <tt>credential_store = <name></tt>. A third-party backend gem calls this
  # from the file RubyGems loads for that name (see .resolve_backend).

  def self.register_backend(name, backend)
    (@backends ||= {})[name.to_s] = backend
  end

  BACKEND_NAME = /\A[a-z0-9_-]+\z/

  ##
  # Resolves a registered backend by +name+, requiring
  # <tt>rubygems/credential_store/backends/<name></tt> on first use so a
  # backend shipped as its own gem loads only when actually selected.
  # Returns +nil+ (warning once) when the name is malformed or no gem
  # provides it, which makes callers fall back to file storage. The fixed
  # require prefix and the restricted name charset keep the setting a piece
  # of data, never a path or a command.

  def self.resolve_backend(name)
    name = name.to_s
    unless BACKEND_NAME.match?(name)
      warn_once "Ignoring invalid credential store backend name #{name.inspect}."
      return nil
    end

    return @backends[name] if @backends&.key?(name)

    begin
      require "rubygems/credential_store/backends/#{name}"
    rescue LoadError
      warn_once "Credential store backend #{name.inspect} is not installed; falling back to file storage."
      return nil
    end

    @backends && @backends[name]
  end

  def self.backend_for(spec)
    spec == true ? default_backend : resolve_backend(spec)
  end
  private_class_method :backend_for

  def self.default_backend
    if Gem.win_platform?
      require_relative "credential_store/native/windows"
      WindowsBackend
    elsif RUBY_PLATFORM.include?("darwin")
      require_relative "credential_store/native/macos"
      MacOSBackend
    elsif RUBY_PLATFORM.include?("linux")
      require_relative "credential_store/native/linux"
      LinuxBackend if LinuxBackend.available?
    end
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
