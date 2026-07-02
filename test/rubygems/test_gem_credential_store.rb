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

  def test_for_returns_nil_when_disabled
    assert_nil Gem::CredentialStore.for(false)
    assert_nil Gem::CredentialStore.for(nil)
  end

  def test_for_memoizes_per_spec
    Gem::CredentialStore.register_backend("faux", FakeBackend.new)

    assert_same Gem::CredentialStore.for("faux"), Gem::CredentialStore.for("faux")
  end

  def test_register_and_resolve_backend_roundtrip
    backend = FakeBackend.new
    Gem::CredentialStore.register_backend("faux", backend)

    assert_same backend, Gem::CredentialStore.resolve_backend("faux")

    store = Gem::CredentialStore.for("faux")
    assert store.set("example.org", "s3cr3t")
    assert_equal "s3cr3t", store.get("example.org")
    assert_includes backend.calls, [:set, Gem::CredentialStore::SERVICE_NAME, "example.org", "s3cr3t"]
  end

  def test_resolve_backend_rejects_invalid_name
    use_ui(@ui) do
      assert_nil Gem::CredentialStore.resolve_backend("../evil")
      assert_nil Gem::CredentialStore.resolve_backend("Foo Bar")
    end

    assert_match(/invalid credential store backend name/, @ui.errs.string)
  end

  def test_resolve_backend_requires_convention_path_and_registers
    backends_dir = File.join(@tempdir, "rubygems", "credential_store", "backends")
    FileUtils.mkdir_p(backends_dir)
    File.write(File.join(backends_dir, "faux_ext.rb"), <<~RUBY)
      Gem::CredentialStore.register_backend("faux_ext", Object.new)
    RUBY

    $LOAD_PATH.unshift(@tempdir)

    refute_nil Gem::CredentialStore.resolve_backend("faux_ext")
  ensure
    $LOAD_PATH.delete(@tempdir)
  end

  def test_resolve_backend_unknown_name_returns_nil_and_warns
    use_ui(@ui) do
      assert_nil Gem::CredentialStore.resolve_backend("definitely_not_installed_xyz")
    end

    assert_match(/is not installed/, @ui.errs.string)
  end

  def test_instance_override_wins_for_any_enabled_spec
    fake = Gem::CredentialStore.new(backend: FakeBackend.new)
    Gem::CredentialStore.instance = fake

    assert_same fake, Gem::CredentialStore.for(true)
    assert_same fake, Gem::CredentialStore.for("1password")
  end
end
