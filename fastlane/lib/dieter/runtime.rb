# frozen_string_literal: true

require_relative "config"
require_relative "pipeline/context"
require_relative "pipeline/engine"
require_relative "platforms/android"
require_relative "platforms/mac"
require_relative "platforms/ios"
require_relative "platforms/core"
require_relative "fixtures/screen"
require_relative "pipeline/source"
require_relative "platforms/server"
require_relative "pipeline/candidate"
require_relative "distribution/coordinator"
require_relative "distribution/testflight"
require_relative "distribution/retention"

module Dieter
  module Runtime
    def self.native_ci(options)
      raise PipelineError, "Native CI composition requires Actions" unless ENV["GITHUB_ACTIONS"] == "true"
      values = options.transform_keys(&:to_s)
      raise PipelineError, "Unknown native CI options" unless (values.keys - %w[component cases suite profile]).empty?
      component = values.delete("component")
      raise PipelineError, "Invalid native CI component" unless %w[mac ios android].include?(component)
      values.reject! { |_key, value| value == "" }
      if values["suite"] && !%w[smoke functional sync performance sdk screens].include?(values["suite"])
        raise PipelineError, "Invalid native CI suite"
      end
      invoke("e2e", component, values)
    end

    ROOT = File.expand_path("../../..", __dir__)

    def self.invoke(operation, component, options, actions: nil)
      request = PipelineRequest.new(operation, component, options)
      config = Config.new(ROOT)
      context = RunContext.new(config, output: request.options["output"])
      begin
        context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
        if %w[daemon gateway].include?(component)
          adapter = Server.new(context, component: component, actions: actions)
        else
          klass = {"android" => Android, "mac" => Mac, "ios" => IOS, "core" => Core}.fetch(component)
          adapter = component == "core" ? klass.new(context) : klass.new(context, actions: actions)
        end
      rescue Exception
        context.close
        raise
      end
      puts "Pipeline evidence: #{context.output}"
      Pipeline.new(context, request, adapter).run
    end

    def self.catalog(options)
      unknown = options.keys.map(&:to_s) - %w[action platform suite cases device changed base output]
      raise PipelineError, "Unknown catalog options: #{unknown.join(', ')}" unless unknown.empty?
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        action = options.fetch(:action, "lint")
        raise PipelineError, "catalog action must be lint, list or plan" unless %w[lint list plan].include?(action)
        request = {
          platform: options.fetch(:platform, "android"), suite: options.fetch(:suite, ""),
          ids: options.fetch(:cases, "").split(","), device: options.fetch(:device, "iphone"),
          changed: options[:changed] == "true" || options[:changed] == true, base: options.fetch(:base, "")
        }
        result = Contract.new(context).call(action == "lint" ? "lint" : "plan", request)
        puts JSON.pretty_generate(result)
        Atomic.json(File.join(context.output, "catalog.json"), result)
        result
      ensure
        context.close
      end
    end

    def self.core_apple(options)
      request = PipelineRequest.new("test_unit", "core", options)
      context = RunContext.new(Config.new(ROOT), output: request.options["output"])
      begin
        Core.new(context).apple_test(request.options)
      ensure
        context.close
      end
    end

    def self.configure(options)
      path = File.join(ROOT, "fastlane/local.json")
      raise PipelineError, "Local configuration already exists; edit it explicitly" if File.exist?(path)
      config = JSON.parse(File.read(File.join(ROOT, "fastlane/local.example.json")))
      context = RunContext.new(Config.new(ROOT, ci: true))
      begin
        runtime = options[:runtime]
        if RUBY_PLATFORM.include?("darwin")
          runtimes = JSON.parse(context.command(["xcrun", "simctl", "list", "runtimes", "-j"], timeout: 30, binary: true)).fetch("runtimes").select { |entry| entry["isAvailable"] && entry["platform"] == "iOS" }
          runtime ||= runtimes.first.fetch("identifier") if runtimes.length == 1
          raise PipelineError, "Select runtime:IDENTIFIER from installed iOS runtimes" unless runtime && runtimes.any? { |entry| entry["identifier"] == runtime }
          %w[ios-iphone ios-ipad].each { |name| config.fetch("profiles").fetch(name)["runtime"] = runtime }
        end
        merged = Config.new(ROOT, ci: true).data
        merge = lambda { |base, override| base.merge(override) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? merge.call(a, b) : b } }
        JSON::Validator.validate!(File.join(ROOT, "fastlane/config.schema.json"), merge.call(merged, config))
        Atomic.json(path, config)
        puts "Created ignored fastlane/local.json; physical profiles remain disabled until explicitly configured."
      ensure
        context.close
      end
    end

    def self.doctor
      config = Config.new(ROOT)
      puts "Ruby #{RUBY_VERSION}; local configuration #{config.local_loaded ? 'loaded' : 'ignored/absent'}"
      config.data.fetch("profiles").each do |name, profile|
        begin
          config.profile(name)
          puts "#{name}: configured (#{profile.fetch('kind')})"
        rescue Unavailable => error
          puts "#{name}: unavailable: #{error.message}"
        end
      end
      config.environment.each { |key, _value| puts "#{key}: configured" }
    end

    def self.candidate(component, options, actions: nil)
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        pipeline = CandidatePipeline.new(context, component, options, actions: actions)
      rescue Exception
        context.close
        raise
      end
      pipeline.run
    end

    def self.release(options, actions: nil)
      unknown = options.keys.map(&:to_s) - %w[action identity output source channel tag release_id]
      raise PipelineError, "Unknown release options: #{unknown.join(', ')}" unless unknown.empty?
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        github = GitHubDestination.new(context)
        action = options.fetch(:action, "reserve")
        return ReleaseRetention.new(context).prune if action == "prune"
        if action == "reserve"
          identity = github.reserve(options[:source] || ENV.fetch("GITHUB_SHA"))
          if ENV["GITHUB_OUTPUT"]
            File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("tag=#{identity.tag}\nversion=#{identity.version}\nbuild=#{identity.build}\nsource=#{identity.source}") }
          end
          puts "Reserved #{identity.tag} · dev from #{identity.source}"
          return identity
        end
        if options[:identity]
          identity = ReleaseIdentity.load(options.fetch(:identity))
        else
          tag = options[:tag]
          tag ||= github.api("releases/#{Integer(options.fetch(:release_id))}").fetch("tag_name")
          ref = github.api("git/ref/tags/#{URI.encode_www_form_component(tag)}")
          raise PipelineError, "Release tag is not a pipeline reservation" unless ref.dig("object", "type") == "tag"
          object = github.api("git/tags/#{ref.fetch('object').fetch('sha')}")
          raise PipelineError, "Release tag is not a pipeline identity" unless object.fetch("message").start_with?("Dieter pipeline identity\n")
          identity = ReleaseIdentity.new(JSON.parse(object.fetch("message").delete_prefix("Dieter pipeline identity\n")))
          raise PipelineError, "Reserved tag/source changed" unless identity.tag == tag && identity.source == object.dig("object", "sha") && identity.data["repository"] == github.repository
          github.download(identity, "identity.json", File.join(context.output, "identity.json"))
          raise PipelineError, "Retained identity changed" unless ReleaseIdentity.load(File.join(context.output, "identity.json")).data == identity.data
        end
        coordinator = ReleaseCoordinator.new(context, identity)
        case action
        when "assemble" then coordinator.assemble
        when "publish"
          result = coordinator.publish(channel: options.fetch(:channel, "dev"))
          File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("tag=#{identity.tag}\nrelease_id=#{result.fetch('id')}") } if ENV["GITHUB_OUTPUT"] && result
          result
        when "distribute" then TestFlightDestination.new(context, identity, actions: actions).deliver
        when "promote" then coordinator.promote
        when "gateway_prepare" then coordinator.prepare_gateway
        when "pin"
          coordinator.verify_retained
          github.with_claim(identity, "retention") { github.receipt(identity, "retention", {"pinned" => true}) }
        when "verify" then coordinator.verify_retained
        else raise PipelineError, "Unknown release action #{action}"
        end
      ensure
        context.close
      end
    end
  end
end
