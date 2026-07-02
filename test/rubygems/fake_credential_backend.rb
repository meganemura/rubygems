# frozen_string_literal: true

##
# An in-memory Gem::CredentialStore backend for tests that need to exercise
# credential-store-enabled code paths without touching a real OS credential store.
# Inject it via <tt>Gem::CredentialStore.instance = Gem::CredentialStore.new(backend: Gem::FakeCredentialBackend.new)</tt>.

class Gem::FakeCredentialBackend
  def initialize
    @data = {}
  end

  def get(service, account)
    @data[[service, account]]
  end

  def set(service, account, secret)
    @data[[service, account]] = secret
    true
  end

  def delete(service, account)
    @data.delete([service, account])
    true
  end
end
