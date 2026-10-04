# frozen_string_literal: true

require "json"
require "rbconfig"
require_relative "../errors"

module Dieter
  # Fastlane owns Apple command construction. The parent retains deadlines,
  # output redaction and process-group ownership, including cancellation.
  module NativeAction
    ACTIONS = %w[run_tests build_app].freeze

    def self.start(context, name, options, log:)
      raise PipelineError, "Unsupported native action #{name}" unless ACTIONS.include?(name)
      context.start([RbConfig.ruby, "-r", File.expand_path(__FILE__), "-e", "Dieter::NativeAction.worker"],
                    input: JSON.generate(action: name, options: options), log: log,
                    environment: {"FASTLANE_SKIP_UPDATE_CHECK" => "true", "FASTLANE_OPT_OUT_USAGE" => "true", "FASTLANE_SKIP_DOCS" => "true",
                                  "FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT" => "120", "FASTLANE_XCODEBUILD_SETTINGS_RETRIES" => "0"})
    end

    def self.run(context, name, options, timeout:, log:)
      process = start(context, name, options, log: log)
      context.wait(process, timeout: timeout, label: "Fastlane #{name}")
    end

    def self.configuration_options(options)
      values = options.transform_keys(&:to_sym).merge(disable_package_automatic_updates: true)
      values[:xcodebuild_formatter] = "xcpretty" if values[:xcodebuild_formatter].to_s.empty?
      # A verified xctestrun consumes existing products. Re-resolving the package
      # graph for every native case adds network work and cannot improve them.
      values[:skip_package_dependencies_resolution] = true if values[:test_without_building]
      values
    end

    def self.worker
      $stdout.sync = true
      require "fastlane"
      Fastlane.load_actions
      request = JSON.parse($stdin.read(1024 * 1024))
      name = request.fetch("action")
      raise PipelineError, "Unsupported native action" unless ACTIONS.include?(name)
      klass = Fastlane::Actions.const_get(name.split("_").map(&:capitalize).join + "Action")
      options = configuration_options(request.fetch("options"))
      configuration = FastlaneCore::Configuration.create(klass.available_options, options)
      Fastlane::Actions.execute_action(name) { klass.run(configuration) }
    end
  end
end
