# frozen_string_literal: true

require "digest"
require "tmpdir"
require_relative "../pipeline/artifacts"

module Dieter
  class SharedFramework
    TARGETS = %w[MacosArm64 IosArm64 IosSimulatorArm64].freeze
    SLICES = {"macos" => %w[MacosArm64], "ios-simulator" => %w[IosSimulatorArm64], "ios-device" => %w[IosArm64], "all" => TARGETS}.freeze

    def initialize(context)
      @context, @root = context, context.root
    end

    def build(configuration: "debug", platforms: "macos")
      raise PipelineError, "Expected debug or release framework" unless %w[debug release].include?(configuration)
      selected = SLICES.fetch(platforms) { raise PipelineError, "Unknown framework slice set #{platforms}" }.dup
      @context.lease("apple-build")
      @context.lease("shared-framework")
      output = File.join(@root, "apps/mac/Frameworks")
      framework = File.join(output, "DieterShared.xcframework")
      manifest = File.join(output, ".DieterShared.inputs")
      existing = File.file?(manifest) ? File.read(manifest).lines.map(&:strip) : []
      if existing.first&.end_with?(" #{configuration}")
        selected |= TARGETS.select { |target| existing.include?("slice #{target}") }
      end
      selected = TARGETS.select { |target| selected.include?(target) }
      digest = input_digest
      content = "inputs #{digest} #{configuration}\n" + selected.map { |target| "slice #{target}\n" }.join
      if File.directory?(framework) && existing.first == "inputs #{digest} #{configuration}" && selected.all? { |target| existing.include?("slice #{target}") } && existing.include?("artifact #{ArtifactSet.sha256(framework)}")
        puts "Reusing verified DieterShared #{configuration}: #{selected.join(', ')}"
        return framework
      end
      tasks = selected.map { |target| ":apple:link#{configuration.capitalize}Framework#{target}" }
      @context.command([File.join(@root, "apps/core/gradlew"), "--project-dir", "apps/core", "--console=plain", *tasks], log: File.join(@context.output, "framework-build.log"), timeout: 2400)
      FileUtils.mkdir_p(output)
      Dir.mktmpdir(".DieterShared-", output) do |stage|
        products = selected.flat_map do |target|
          name = target.sub(/\A./) { |character| character.downcase }
          ["-framework", File.join(@root, "apps/core/apple/build/bin", name, "#{configuration}Framework/DieterShared.framework")]
        end
        staged = File.join(stage, "DieterShared.xcframework")
        @context.command(["xcodebuild", "-create-xcframework", *products, "-output", staged], timeout: 300)
        same = false
        if File.directory?(framework)
          command = ["python3", "-c", "import sys; from fastlane.lib.dieter.native.tree import tree_digest; sys.exit(0 if tree_digest(sys.argv[1]) == tree_digest(sys.argv[2]) else 1)", staged, framework]
          process = @context.start(command)
          process.wait(timeout: 120, check: false)
          same = process.status.success?
        end
        unless same
          # A single OS exchange leaves one complete publication even on SIGKILL.
          @context.command(["python3", "-c", "import sys; from pathlib import Path; from fastlane.lib.dieter.native.mac_bundle import exchange; exchange(Path(sys.argv[1]),Path(sys.argv[2]))", staged, framework], timeout: 30)
        end
        Atomic.write(manifest, content + "artifact #{ArtifactSet.sha256(framework)}\n")
      end
      framework
    end

    private

    def input_digest
      paths = @context.command(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", "apps/core", "api/proto", "fastlane/lib/dieter/platforms/framework.rb"], timeout: 30, binary: true).split("\0").uniq.sort
      digest = Digest::SHA256.new
      paths.each do |path|
        next if path.end_with?(".md") || path.start_with?("apps/core/testing/")
        next if path.include?("/src/") && path.split("/src/", 2).last.split("/").first.end_with?("Test")
        full = File.join(@root, path)
        digest.update(path + "\0" + File.binread(full)) if File.file?(full)
      end
      java = @context.environment["JAVA_HOME"] || ENV["JAVA_HOME"]
      java_command = java ? File.join(java, "bin/java") : "java"
      [["xcodebuild", "-version"], [java_command, "-version"]].each { |argv| digest.update(@context.command(argv, timeout: 30)) }
      %w[DEVELOPER_DIR JAVA_HOME GRADLE_OPTS JAVA_TOOL_OPTIONS].each do |name|
        digest.update(name + "\0" + (@context.environment[name] || ENV[name] || "") + "\0")
      end
      digest.hexdigest
    end
  end
end
