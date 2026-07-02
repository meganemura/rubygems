# frozen_string_literal: true

# An in-memory Gem::CredentialStore backend for specs that exercise
# credential-store-enabled code paths without touching a real OS credential store.
class FakeCredentialBackend
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
