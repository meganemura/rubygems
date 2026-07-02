# frozen_string_literal: true

require_relative "helper"
require "rubygems/credential_store/macos_backend"
require "json"

class TestGemCredentialStoreMacosBackend < Gem::TestCase
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
    fake_path = File.join(@fake_bin_dir, "security")
    File.write(fake_path, FAKE_COMMAND)
    File.chmod(0o755, fake_path)

    @record_path = File.join(@tempdir, "record.json")
  end

  def test_get_returns_stripped_secret_on_success
    with_fake_env(stdout: "s3cr3t\n", exit: 0) do
      assert_equal "s3cr3t", Gem::CredentialStore::MacOSBackend.get("rubygems", "example.org")
    end
  end

  def test_get_returns_nil_when_not_found
    with_fake_env(stdout: "", exit: 44) do
      assert_nil Gem::CredentialStore::MacOSBackend.get("rubygems", "example.org")
    end
  end

  def test_get_uses_expected_argv
    with_fake_env(stdout: "s3cr3t\n", exit: 0) do
      Gem::CredentialStore::MacOSBackend.get("rubygems", "example.org")
    end

    record = read_record
    assert_equal %w[find-generic-password -a example.org -s rubygems -w], record["argv"]
  end

  def test_set_returns_true_on_success
    with_fake_env(exit: 0) do
      assert Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", "s3cr3t")
    end
  end

  def test_set_returns_false_on_failure
    with_fake_env(exit: 1) do
      refute Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", "s3cr3t")
    end
  end

  def test_set_passes_secret_via_stdin_not_argv
    with_fake_env(exit: 0) do
      Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", "s3cr3t")
    end

    record = read_record
    refute_includes record["argv"], "s3cr3t"
    assert_includes record["stdin"], "s3cr3t"
  end

  def test_set_escapes_quotes_and_backslashes_in_the_stdin_command
    with_fake_env(exit: 0) do
      Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", %(pa"ss\\word))
    end

    record = read_record
    assert_equal %(add-generic-password -U -a "example.org" -s "rubygems" -w "pa\\"ss\\\\word"\n), record["stdin"]
  end

  def test_set_rejects_secret_with_newline
    assert_raise(ArgumentError) do
      Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", "line1\nline2")
    end
  end

  def test_delete_returns_true_on_success
    with_fake_env(exit: 0) do
      assert Gem::CredentialStore::MacOSBackend.delete("rubygems", "example.org")
    end
  end

  def test_delete_returns_true_when_not_found
    with_fake_env(exit: 44) do
      assert Gem::CredentialStore::MacOSBackend.delete("rubygems", "example.org")
    end
  end

  def test_delete_returns_false_on_other_failure
    with_fake_env(exit: 1) do
      refute Gem::CredentialStore::MacOSBackend.delete("rubygems", "example.org")
    end
  end

  def test_get_raises_when_command_missing
    empty_dir = File.join(@tempdir, "empty-bin")
    FileUtils.mkdir_p(empty_dir)

    with_env(ENV.to_h.merge("PATH" => empty_dir)) do
      assert_raise(Errno::ENOENT) do
        Gem::CredentialStore::MacOSBackend.get("rubygems", "example.org")
      end
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
