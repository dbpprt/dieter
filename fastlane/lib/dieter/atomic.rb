# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module Dieter
  module Atomic
    def self.write(path, contents, mode: 0o600)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      Tempfile.create([".pipeline-", ".tmp"], File.dirname(path)) do |file|
        file.chmod(mode)
        file.binmode
        file.write(contents)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def self.json(path, value)
      write(path, JSON.pretty_generate(value) + "\n")
    end
  end
end
