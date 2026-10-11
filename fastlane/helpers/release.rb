# frozen_string_literal: true

require "time"
require_relative "dieter"

module Dieter
  # Pure release helpers; the lanes call the toolchains and Fastlane actions.
  module Release
    module_function

    def ids
      prefix = Dieter.identity.fetch("bundle_prefix")
      {
        "ios" => "#{prefix}.ios",
        "ios_share" => "#{prefix}.ios.share",
        "mac" => "#{prefix}.mac",
        "android" => "#{prefix}.android",
        "daemon" => "#{prefix}.daemon",
        "capture" => "#{prefix}.capture",
        "privacy" => "#{prefix}.privacy"
      }
    end

    def signer =
      "https://github.com/#{Dieter.identity.fetch("repository")}/.github/workflows/release.yml@refs/heads/main"

    # The release identity of a CI build: DIETER_RELEASE_VERSION and the
    # monotonic DIETER_RELEASE_BUILD reserved by the `version` lane.
    def current
      version =
        ENV.fetch("DIETER_RELEASE_VERSION") do
          raise Unavailable, "DIETER_RELEASE_VERSION is required"
        end
      unless version.match?(/\A\d+\.\d+\.\d+\z/)
        raise ArgumentError, "Release version must be numeric SemVer"
      end
      build = Integer(ENV.fetch("DIETER_RELEASE_BUILD") { version.split(".").last })
      {
        "version" => version,
        "build" => build,
        "apple_build" => Dieter.apple_build(build),
        "revision" => ENV["GITHUB_SHA"] || Dieter.capture("git", "rev-parse", "HEAD").strip
      }
    end

    def ldflags(version, revision)
      package =
        "#{File.read(Dieter.path("go.mod"))[/^module (\S+)/, 1]}/internal/platform/buildinfo"
      built = Dieter.capture("git", "show", "-s", "--format=%cI", "HEAD").strip
      "-s -w -X #{package}.ReleaseVersion=#{version} -X #{package}.SourceRevision=#{revision} -X #{package}.BuiltAt=#{built}"
    end

    # The stable notes: the CHANGELOG.md section of exactly this version.
    def changelog_section(text, version)
      lines = text.lines
      start = lines.index { |line| line.match?(/\A##\s+\[?v?#{Regexp.escape(version)}\]?(\s|\z)/) }
      raise Unavailable, "CHANGELOG.md has no section for #{version}" unless start
      body = lines[(start + 1)..].take_while { |line| !line.start_with?("## ") }.join.strip
      raise Unavailable, "CHANGELOG.md section #{version} is empty" if body.empty?
      body
    end

    # Rewrites the version, release URL and SHA-256 of a tap formula or cask.
    def homebrew(text, version:, sha256:, repository:)
      unless text.scan(/^\s+version "/).length == 1 && text.scan(/^\s+sha256 "/).length == 1
        raise ArgumentError, "Unexpected tap file layout"
      end
      text
        .sub(/^(\s+)version "[^"\n]*"/) { "#{Regexp.last_match(1)}version \"#{version}\"" }
        .sub(/^(\s+)sha256 "[^"\n]*"/) { "#{Regexp.last_match(1)}sha256 \"#{sha256}\"" }
        .gsub(
          %r{https://github\.com/[^/\s"]+/[^/\s"]+/releases/download/v[^/\s"]+/},
          "https://github.com/#{repository}/releases/download/v#{version}/"
        )
    end

    # Retention: dev prereleases beyond the newest `count` and older than `days`.
    def expired(releases, count:, days:, now: Time.now.utc)
      devs =
        releases
          .select do |release|
            release["prerelease"] && !release["draft"] && release["published_at"]
          end
          .sort_by { |release| release["published_at"] }
          .reverse
      devs
        .drop(count)
        .select { |release| Time.parse(release["published_at"]) < now - days * 86_400 }
    end

    # The preinstall script of the side-by-side daemon package: it refuses an
    # existing versioned destination and never touches a running service.
    def preinstall(version)
      <<~SH
        #!/bin/sh
        set -eu
        prefix="${3:-/}"
        prefix="${prefix%/}"
        for component in usr local libexec dieter #{version}; do
            prefix="$prefix/$component"
            if [ -L "$prefix" ]; then
                echo "Dieter cannot install through a symbolic link: $prefix" >&2
                exit 1
            fi
        done
        if [ -e "$prefix" ]; then
            echo "Dieter #{version} is already installed at $prefix. Nothing was changed." >&2
            exit 1
        fi
      SH
    end

    def install_note(version)
      <<~TEXT
        Dieter #{version}

        CLI: /usr/local/libexec/dieter/#{version}/dieter
        DieterPrivacyHelper.app supplies the separately approved privacy input service.
        This installer does not start, stop, replace or configure a daemon service.
        Each release installs into its own directory; existing versions remain.
      TEXT
    end
  end
end
