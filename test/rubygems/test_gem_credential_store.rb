# frozen_string_literal: true

require_relative "helper"
require "rubygems/credential_store"

class TestGemCredentialStore < Gem::TestCase
  class FakeBackend
    attr_reader :calls

    def initialize
      @calls = []
      @data = {}
      @get_calls = 0
    end

    def get(service, account)
      @calls << [:get, service, account]
      @get_calls += 1
      @data[[service, account]]
    end

    def set(service, account, secret)
      @calls << [:set, service, account, secret]
      @data[[service, account]] = secret
      true
    end

    def delete(service, account)
      @calls << [:delete, service, account]
      @data.delete([service, account])
      true
    end

    def get_call_count
      @get_calls
    end
  end

  class RaisingBackend
    def get(_service, _account)
      raise Errno::ENOENT, "security"
    end

    def set(_service, _account, _secret)
      raise Errno::ENOENT, "security"
    end

    def delete(_service, _account)
      raise Errno::ENOENT, "security"
    end
  end

  def setup
    super
    Gem::CredentialStore.reset!
  end

  def teardown
    Gem::CredentialStore.reset!
    super
  end

  def test_available_without_backend
    store = Gem::CredentialStore.new(backend: nil)
    refute store.available?
  end

  def test_available_with_backend
    store = Gem::CredentialStore.new(backend: FakeBackend.new)
    assert store.available?
  end

  def test_get_set_delete_roundtrip
    store = Gem::CredentialStore.new(backend: FakeBackend.new)

    assert_nil store.get("example.org")
    assert store.set("example.org", "s3cr3t")
    assert_equal "s3cr3t", store.get("example.org")
    assert store.delete("example.org")
  end

  def test_set_uses_service_name
    backend = FakeBackend.new
    store = Gem::CredentialStore.new(backend: backend)

    store.set("example.org", "s3cr3t")

    assert_includes backend.calls, [:set, Gem::CredentialStore::SERVICE_NAME, "example.org", "s3cr3t"]
  end

  def test_get_is_memoized_per_account
    backend = FakeBackend.new
    backend.set(Gem::CredentialStore::SERVICE_NAME, "example.org", "s3cr3t")
    store = Gem::CredentialStore.new(backend: backend)

    3.times { store.get("example.org") }

    assert_equal 1, backend.get_call_count
  end

  def test_set_updates_cache_without_extra_get
    backend = FakeBackend.new
    store = Gem::CredentialStore.new(backend: backend)

    store.set("example.org", "s3cr3t")
    assert_equal "s3cr3t", store.get("example.org")

    assert_equal 0, backend.get_call_count
  end

  def test_delete_clears_cache
    backend = FakeBackend.new
    backend.set(Gem::CredentialStore::SERVICE_NAME, "example.org", "s3cr3t")
    store = Gem::CredentialStore.new(backend: backend)
    store.get("example.org")

    store.delete("example.org")
    store.get("example.org")

    assert_equal 2, backend.get_call_count
  end

  def test_operations_without_backend_are_safe_noops
    store = Gem::CredentialStore.new(backend: nil)

    assert_nil store.get("example.org")
    refute store.set("example.org", "s3cr3t")
    refute store.delete("example.org")
  end

  def test_get_swallows_backend_errors_and_returns_nil
    store = Gem::CredentialStore.new(backend: RaisingBackend.new)

    assert_nil store.get("example.org")
  end

  def test_set_swallows_backend_errors_and_returns_false
    store = Gem::CredentialStore.new(backend: RaisingBackend.new)

    refute store.set("example.org", "s3cr3t")
  end

  def test_delete_swallows_backend_errors_and_returns_false
    store = Gem::CredentialStore.new(backend: RaisingBackend.new)

    refute store.delete("example.org")
  end

  def test_warning_is_emitted_only_once_per_process
    store = Gem::CredentialStore.new(backend: RaisingBackend.new)

    use_ui(@ui) do
      store.get("a")
      store.get("b")
      store.set("c", "x")
    end

    warning_count = @ui.errs.string.scan(/WARNING:/).length
    assert_equal 1, warning_count
  end

  def test_instance_returns_the_same_object
    assert_same Gem::CredentialStore.instance, Gem::CredentialStore.instance
  end
end
