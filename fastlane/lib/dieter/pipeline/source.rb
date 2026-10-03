# frozen_string_literal: true

module Dieter
  module SourceIdentity
    def self.version(context)
      supplied = ENV["DIETER_RELEASE_VERSION"]
      return supplied if supplied && !supplied.empty?
      tags = context.command(["git", "tag", "--list", "v*", "--sort=-version:refname"], timeout: 30).lines.map(&:strip)
      latest = tags.find { |tag| tag.match?(/\Av\d+\.\d+\.\d+\z/) } || "v0.0.0"
      major, minor, patch = latest.delete_prefix("v").split(".").map(&:to_i)
      count = context.command(["git", "rev-list", "--count", "HEAD"], timeout: 30).strip
      sha = context.command(["git", "rev-parse", "--short=8", "HEAD"], timeout: 30).strip
      dirty = !context.command(["git", "status", "--porcelain", "--untracked-files=no"], timeout: 30).empty?
      "#{major}.#{minor}.#{patch + 1}-dev.#{count}+#{sha}#{dirty ? '.dirty' : ''}"
    end
  end
end
