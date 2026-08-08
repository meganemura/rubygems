# frozen_string_literal: true

require_relative "path"
require_relative "helpers"

module Spec
  module BuildMetadata
    include Spec::Path
    include Spec::Helpers

    def write_build_metadata(dir: source_root)
      build_metadata_file = File.expand_path("lib/bundler/build_metadata.rb", dir)
      contents = File.read(build_metadata_file)

      contents.sub!(/^\s+@git_commit_sha\s*=.*\n/, "")
      contents.sub!(/^(\s+# end ivars)/, "    @git_commit_sha = #{git_commit_sha.dump}.freeze\n\\1")

      File.open(build_metadata_file, "w") {|f| f << contents }
    end

    def reset_built_at(dir: source_root)
      build_metadata_file = File.expand_path("lib/bundler/build_metadata.rb", dir)
      contents = File.read(build_metadata_file)

      contents.sub!(/^(\s+)@built_at\s*=.*$/, '\1@built_at = nil')

      File.open(build_metadata_file, "w") {|f| f << contents }
    end

    private

    def git_commit_sha
      ruby_core_tarball? ? "unknown" : git("rev-parse --short HEAD", source_root).strip
    end

    extend self
  end
end
