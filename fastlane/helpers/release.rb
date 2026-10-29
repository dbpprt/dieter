# frozen_string_literal: true

require "erb"

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

    # The linker flags of a release binary. A daemon also pins the SHA-256 of
    # its platform's prebuilt harness runtime archive, which it then downloads
    # from its own release instead of running npm.
    def ldflags(version, revision, harness_runtime_sha256: nil)
      package =
        "#{File.read(Dieter.path("go.mod"))[/^module (\S+)/, 1]}/internal/platform/buildinfo"
      built = Dieter.capture("git", "show", "-s", "--format=%cI", "HEAD").strip
      flags =
        "-s -w -X #{package}.ReleaseVersion=#{version} -X #{package}.SourceRevision=#{revision} -X #{package}.BuiltAt=#{built}"
      return flags unless harness_runtime_sha256
      unless harness_runtime_sha256.match?(/\A\h{64}\z/)
        raise ArgumentError, "The harness runtime pin must be a SHA-256"
      end
      "#{flags} -X #{package}.HarnessRuntimeSHA256=#{harness_runtime_sha256}"
    end

    # The release asset carrying one platform's prebuilt harness runtime
    # (harness.RuntimeArchiveName).
    def harness_runtime_archive(os, arch) = "dieter-harness-runtime-#{os}-#{arch}.tar.gz"

    # The stable notes: the CHANGELOG.md section of exactly this version.
    def changelog_section(text, version)
      lines = text.lines
      start = lines.index { |line| line.match?(/\A##\s+\[?v?#{Regexp.escape(version)}\]?(\s|\z)/) }
      raise Unavailable, "CHANGELOG.md has no section for #{version}" unless start
      body = lines[(start + 1)..].take_while { |line| !line.start_with?("## ") }.join.strip
      raise Unavailable, "CHANGELOG.md section #{version} is empty" if body.empty?
      body
    end

    # The tap's formula and cask, rendered from deploy/homebrew/*.rb.erb with the
    # identity and the promoted release: tap path => asset whose digest it pins.
    HOMEBREW = {
      "Formula/dieter.rb" => %w[dieter.rb.erb dieter-darwin-arm64.tar.gz],
      "Casks/dieter-app.rb" => %w[dieter-app.rb.erb Dieter-macOS-arm64.zip]
    }.freeze

    def homebrew(template, version:, sha256:, identity: Dieter.identity)
      unless version.match?(/\A\d+\.\d+\.\d+\z/) && sha256.match?(/\A\h{64}\z/)
        raise ArgumentError, "Homebrew needs a release version and a SHA-256"
      end
      values = {
        version: version,
        sha256: sha256,
        repository: identity.fetch("repository"),
        tap: identity.fetch("homebrew_tap"),
        mac_bundle_id: "#{identity.fetch("bundle_prefix")}.mac"
      }
      ERB.new(File.read(Dieter.path("deploy/homebrew", template)), trim_mode: "-").result_with_hash(
        values
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
