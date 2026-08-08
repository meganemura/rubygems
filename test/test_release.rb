# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../tool/release"
require_relative "rubygems/helper"

class ReleaseBundlerTest < Test::Unit::TestCase
  def test_write_release_date_writes_only_built_at
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/bundler"))
      File.write(File.join(dir, "lib/bundler/build_metadata.rb"), <<~RUBY)
        module Bundler
          module BuildMetadata
            # begin ivars
            @built_at = nil
            # end ivars
          end
        end
      RUBY

      Release::Bundler.new("9.9.9").write_release_date(released_at: Time.new(2026, 8, 6), dir: dir)

      ivars = File.read(File.join(dir, "lib/bundler/build_metadata.rb"))[/# begin ivars.*# end ivars/m]
      assert_match(/^\s*@built_at = "2026-08-06"(\.freeze)?$/, ivars)
      assert_no_match(/@git_commit_sha/, ivars)
    end
  end
end
