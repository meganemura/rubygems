# frozen_string_literal: true

require_relative "helper"
require "rubygems/credential_store/native/macos"
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

  def test_set_rejects_non_ascii_secret
    # security find-generic-password -w returns non-printable bytes as a hex
    # string, so a non-ASCII secret would round-trip corrupted. Reject it so
    # the caller falls back to file storage instead.
    assert_raise(ArgumentError) do
      Gem::CredentialStore::MacOSBackend.set("rubygems", "example.org", "péあ")
    end
  end

  def test_set_rejects_account_with_newline
    assert_raise(ArgumentError) do
      Gem::CredentialStore::MacOSBackend.set("rubygems", "acct\nadd-generic-password", "secret")
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

  def test_delete_all_loops_until_not_found
    # security deletes one entry per call; stub exits 0 twice, then 44.
    counter = File.join(@tempdir, "counter")
    File.write(counter, "0")
    script = <<~RUBY
      #!/usr/bin/env ruby
      c = File.read(#{counter.inspect}).to_i
      File.write(#{counter.inspect}, (c + 1).to_s)
      exit(c < 2 ? 0 : 44)
    RUBY
    File.write(File.join(@fake_bin_dir, "security"), script)
    File.chmod(0o755, File.join(@fake_bin_dir, "security"))

    with_env(ENV.to_h.merge("PATH" => [@fake_bin_dir, ENV["PATH"]].join(File::PATH_SEPARATOR))) do
      assert Gem::CredentialStore::MacOSBackend.delete_all("rubygems")
    end

    assert_equal 3, File.read(counter).to_i
  end

  def test_delete_all_returns_false_on_error
    with_fake_env(exit: 1) do
      refute Gem::CredentialStore::MacOSBackend.delete_all("rubygems")
    end
  end

  def test_get_returns_no_credential_when_command_missing
    empty_dir = File.join(@tempdir, "empty-bin")
    FileUtils.mkdir_p(empty_dir)

    # A missing security binary must not yield a credential. MRI raises
    # Errno::ENOENT from Open3; other implementations (JRuby) report a
    # failure status instead of raising, so accept either and assert only
    # that nothing is returned. Gem::CredentialStore#get traps the error
    # class either way.
    with_env(ENV.to_h.merge("PATH" => empty_dir)) do
      result =
        begin
          Gem::CredentialStore::MacOSBackend.get("rubygems", "example.org")
        rescue StandardError
          nil
        end

      assert_nil result
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
