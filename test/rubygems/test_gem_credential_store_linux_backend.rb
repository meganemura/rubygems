# frozen_string_literal: true

require_relative "helper"
require "rubygems/credential_store/native/linux"
require "json"

class TestGemCredentialStoreLinuxBackend < Gem::TestCase
  FAKE_COMMAND = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"
    stdin_content = $stdin.read
    if record_path = ENV["RUBYGEMS_FAKE_CMD_RECORD"]
      File.write(record_path, {"argv" => ARGV, "stdin" => stdin_content}.to_json)
    end
    $stdout.write(ENV["RUBYGEMS_FAKE_CMD_STDOUT"].to_s)
    $stderr.write(ENV["RUBYGEMS_FAKE_CMD_STDERR"].to_s)
    exit(ENV["RUBYGEMS_FAKE_CMD_EXIT"].to_i)
  RUBY

  def setup
    super
    pend "fake shebang executables aren't supported on native Windows" if Gem.win_platform?

    @fake_bin_dir = File.join(@tempdir, "fake-bin")
    FileUtils.mkdir_p(@fake_bin_dir)
    fake_path = File.join(@fake_bin_dir, "secret-tool")
    File.write(fake_path, FAKE_COMMAND)
    File.chmod(0o755, fake_path)

    @record_path = File.join(@tempdir, "record.json")
    Gem::CredentialStore::LinuxBackend.reset!
  end

  def teardown
    Gem::CredentialStore::LinuxBackend.reset!
    super
  end

  def test_available_is_true_when_secret_tool_is_on_path
    with_env(ENV.to_h.merge("PATH" => [@fake_bin_dir, ENV["PATH"]].join(File::PATH_SEPARATOR))) do
      Gem::CredentialStore::LinuxBackend.reset!
      assert Gem::CredentialStore::LinuxBackend.available?
    end
  end

  def test_available_is_false_when_secret_tool_is_missing
    empty_dir = File.join(@tempdir, "empty-bin")
    FileUtils.mkdir_p(empty_dir)

    with_env(ENV.to_h.merge("PATH" => empty_dir)) do
      Gem::CredentialStore::LinuxBackend.reset!
      refute Gem::CredentialStore::LinuxBackend.available?
    end
  end

  def test_get_returns_stripped_secret_on_success
    with_fake_env(stdout: "s3cr3t\n", exit: 0) do
      assert_equal "s3cr3t", Gem::CredentialStore::LinuxBackend.get("rubygems", "example.org")
    end
  end

  def test_get_returns_nil_when_not_found
    with_fake_env(stdout: "", exit: 1) do
      assert_nil Gem::CredentialStore::LinuxBackend.get("rubygems", "example.org")
    end
  end

  def test_get_uses_expected_argv
    with_fake_env(stdout: "s3cr3t\n", exit: 0) do
      Gem::CredentialStore::LinuxBackend.get("rubygems", "example.org")
    end

    record = read_record
    assert_equal %w[lookup service rubygems account example.org], record["argv"]
  end

  def test_set_returns_true_on_success
    with_fake_env(exit: 0) do
      assert Gem::CredentialStore::LinuxBackend.set("rubygems", "example.org", "s3cr3t")
    end
  end

  def test_set_passes_secret_via_stdin_not_argv
    with_fake_env(exit: 0) do
      Gem::CredentialStore::LinuxBackend.set("rubygems", "example.org", "s3cr3t")
    end

    record = read_record
    refute_includes record["argv"], "s3cr3t"
    assert_equal "s3cr3t", record["stdin"]
  end

  def test_delete_returns_true_on_success
    with_fake_env(exit: 0) do
      assert Gem::CredentialStore::LinuxBackend.delete("rubygems", "example.org")
    end
  end

  def test_delete_returns_true_when_nothing_matched
    with_fake_env(stderr: "", exit: 1) do
      assert Gem::CredentialStore::LinuxBackend.delete("rubygems", "example.org")
    end
  end

  def test_delete_returns_false_on_other_failure
    with_fake_env(stderr: "unexpected D-Bus error", exit: 1) do
      refute Gem::CredentialStore::LinuxBackend.delete("rubygems", "example.org")
    end
  end

  private

  def with_fake_env(stdout: "", stderr: "", exit: 0)
    overrides = ENV.to_h.merge(
      "PATH" => [@fake_bin_dir, ENV["PATH"]].join(File::PATH_SEPARATOR),
      "RUBYGEMS_FAKE_CMD_STDOUT" => stdout,
      "RUBYGEMS_FAKE_CMD_STDERR" => stderr,
      "RUBYGEMS_FAKE_CMD_EXIT" => exit.to_s,
      "RUBYGEMS_FAKE_CMD_RECORD" => @record_path
    )
    with_env(overrides) { yield }
  end

  def read_record
    JSON.parse(File.read(@record_path))
  end
end
