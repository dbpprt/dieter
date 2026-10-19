# frozen_string_literal: true

require_relative "dieter"

module Dieter
  # SwiftPM test runs that fail closed: a run that stops early (for example a
  # test that stops the main run loop exits 0 mid-run) reports fewer tests than
  # the package's minimum and fails.
  module Swift
    PACKAGES = {
      "kit" => "apps/apple/DieterKit",
      "native" => "native/macos",
      "mac" => "apps/apple/mac"
    }.freeze

    module_function

    # Xcode can restore an explicit WebRTC module built against an older binary
    # artifact, then reject it after SwiftPM replaces the framework headers.
    # Invalidate only that generated module when its declared artifact changes.
    def prepare_xcode_webrtc_cache(
      derived,
      manifest: Dieter.path("apps/apple/DieterKit/Package.swift")
    )
      artifact = File.read(manifest)[/\.binaryTarget\(\s*name: "WebRTC",.*?\n\s*\)/m]
      raise "WebRTC binary target not found in #{manifest}" unless artifact
      identity = Digest::SHA256.hexdigest(artifact)
      stamp = File.join(derived, ".dieter-webrtc-module-identity")
      return if File.file?(stamp) && File.read(stamp) == identity

      modules = File.join(derived, "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules")
      Dir.glob(File.join(modules, "WebRTC-*.pcm")).each { |file| FileUtils.rm(file) }
      FileUtils.mkdir_p(derived)
      File.write(stamp, identity)
    end

    # Tests reported by swift-testing's summary and XCTest's totals.
    def count(output)
      testing = output.scan(/Test run with (\d+) tests?\b.*?(?:passed|failed)/).sum { |(n)| n.to_i }
      xctest =
        output.scan(/Executed (\d+) tests?, with \d+ failures?/).map { |(n)| n.to_i }.max.to_i
      testing + xctest
    end

    def failed?(output) =
      output.match?(/Test run with \d+ tests?\b.*\bfailed\b/) ||
        output.match?(/Executed \d+ tests?, with [1-9]\d* failures?/)

    def test(name, minimum:, evidence:, filter: nil, env: {})
      package = PACKAGES.fetch(name)
      junit = File.join(evidence, "swift-#{name}.xml")
      argv = [
        "swift",
        "test",
        "--package-path",
        package,
        "--only-use-versions-from-resolved-file",
        "--disable-index-store",
        "--no-parallel",
        "--xunit-output",
        junit
      ]
      argv += ["--filter", filter] if filter
      output = Dieter.group("swift test #{package}") { Dieter.sh(*argv, env: env) }
      File.write(File.join(evidence, "swift-#{name}.log"), output)
      tests = count(output)
      raise "#{package}: test failures reported" if failed?(output)
      required = filter ? 1 : minimum
      if tests < required
        raise "#{package}: #{tests} tests ran, expected at least #{required}; the run stopped early"
      end
      puts "#{package}: #{tests} tests passed (minimum #{required})"
      tests
    end
  end
end
