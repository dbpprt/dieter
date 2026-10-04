# frozen_string_literal: true

require "digest"

module Dieter
  module BuildInputs
    IOS = %w[apps/mac apps/ios apps/core api/proto fastlane/lib/dieter/platforms fastlane/lib/dieter/pipeline/action.rb].freeze

    def self.digest(context, paths: IOS)
      files = context.command(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", *paths], timeout: 30, binary: true).split("\0").uniq.sort
      digest = Digest::SHA256.new
      files.each do |path|
        next if path.end_with?(".md")
        full = File.join(context.root, path)
        digest.update(path + "\0" + File.binread(full)) if File.file?(full)
      end
      digest.update(context.environment.fetch("DIETER_RELEASE_VERSION", ""))
      digest.hexdigest
    end
  end
end
