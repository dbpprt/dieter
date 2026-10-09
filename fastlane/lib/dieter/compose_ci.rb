# frozen_string_literal: true

require_relative "compose_spike"
require_relative "pipeline/preview"

module Dieter
  module ComposeCI
    COMPONENTS = %w[core android ios].freeze

    def self.invoke(options)
      values = options.transform_keys(&:to_s)
      unless (values.keys - %w[action component artifact output]).empty?
        raise PipelineError, "Unknown Compose CI option"
      end
      component = values.fetch("component")
      raise PipelineError, "Unknown Compose CI component" unless COMPONENTS.include?(component)
      action = values.fetch("action", "check")
      raise PipelineError, "Unknown Compose CI action" unless %w[check verify].include?(action)
      context = RunContext.new(Config.new(Runtime::ROOT), output: values["output"])
      puts "Compose CI evidence: #{context.output}"
      begin
        if action == "verify"
          raise PipelineError, "Core has no preview" if component == "core"
          PreviewArtifact.verify(
            File.expand_path(values.fetch("artifact"), context.root),
            source: context.command(%w[git rev-parse HEAD], timeout: 30).strip,
            component: "compose-#{component}",
            kind: component == "ios" ? "simulator-app" : "apk"
          )
        else
          raise PipelineError, "artifact is only valid for verification" if values["artifact"]
          context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
          check(context, component)
        end
      ensure
        context.close
      end
      if action == "check" && component != "core" && ENV["GITHUB_OUTPUT"]
        run, attempt = ENV.fetch("GITHUB_RUN_ID"), ENV.fetch("GITHUB_RUN_ATTEMPT")
        unless [run, attempt].all? { |value| value.match?(/\A[1-9]\d*\z/) }
          raise PipelineError, "Invalid preview run identity"
        end
        File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
          file.puts("preview_name=compose-preview-input-#{component}-#{run}-#{attempt}")
        end
      end
    end

    def self.check(context, component)
      case component
      when "core"
        ComposeSpike.gradle(context, "apps/core", %w[:mobile:jvmTest])
      when "android"
        ComposeSpike.android_build(context)
        PreviewArtifact.stage(
          context,
          manifest: File.join(context.output, "artifacts.json"),
          component: "compose-android",
          product: "apk",
          metadata: {
            "bundle_id" => "com.dbpprt.dieter.compose.spike",
            "target" => "android"
          }
        )
      when "ios"
        output = ComposeSpike.ios_qualify(context)
        manifest_path = File.join(output, "artifacts.json")
        built = ArtifactSet.load(manifest_path, component: "compose-ios").manifest
        products =
          built.fetch("products").find { |entry| entry["kind"] == "test-products" }.fetch("path")
        app = File.join(products, "Debug-iphonesimulator/DieterComposeSpike.app")
        # Retain only the tested app as the downloadable product.
        ArtifactSet.new(
          component: "compose-ios",
          source: built.fetch("source_revision"),
          configuration: "debug",
          products: {
            "app" => app
          }
        ).write(File.join(context.output, "preview-input.json"))
        PreviewArtifact.stage(
          context,
          manifest: File.join(context.output, "preview-input.json"),
          component: "compose-ios",
          product: "app",
          archive: true,
          metadata: {
            "bundle_id" => "com.dbpprt.dieter.compose.spike.ios",
            "target" => "ios-simulator-arm64",
            "profiles" => %w[ios-iphone ios-ipad]
          }
        )
      end
    end
  end
end
