# frozen_string_literal: true

require "optparse"
require "yaml"
require_relative "runtime"
require_relative "platforms/linux_capture"

module Dieter
  module Checks
    def self.cli(argv)
      options = {}
      parser = OptionParser.new do |flags|
        flags.banner = "just check-changed [--dry-run] [--base REF] [--ci]"
        flags.on("--dry-run", "Inspect typed requests without executing checks") { options[:dry_run] = true }
        flags.on("--base REF", "Include branch changes against this merge base") { |value| options[:base] = value }
        flags.on("--ci", "Write affected component outputs to GITHUB_OUTPUT") { options[:ci] = true }
      end
      parser.parse!(argv)
      raise PipelineError, "Unexpected check arguments" unless argv.empty?
      invoke(options)
    end

    def self.invoke(options)
      options = options.transform_keys(&:to_sym)
      raise PipelineError, "Unknown check options" unless (options.keys - %i[dry_run base ci output]).empty?
      ci = boolean(options.fetch(:ci, false))
      dry = boolean(options.fetch(:dry_run, false))
      context = RunContext.new(Config.new(Runtime::ROOT), output: options[:output])
      begin
        base = options[:base] || (ci ? ENV["CI_CHANGE_BASE"] : nil)
        all = ci && (%w[schedule workflow_dispatch].include?(ENV["GITHUB_EVENT_NAME"]) || base.nil? || base.empty? || base.match?(/\A0+\z/))
        plan = all ? {"paths" => [], "checks" => [], "ci" => %w[core macos ios android kmp].to_h { |name| [name, true] }} : Contract.new(context).call("affected-checks", {base: base || "", kind: ci ? "ci" : "local"})
        Atomic.json(File.join(context.output, "affected-checks.json"), plan)
      ensure
        context.close
      end
      puts "Changed paths:"
      plan.fetch("paths").each { |path| puts "  #{path.inspect}" }
      if ci
        output = ENV.fetch("GITHUB_OUTPUT") { raise PipelineError, "--ci requires GITHUB_OUTPUT" }
        File.open(output, "a") { |file| plan.fetch("ci").each { |name, enabled| file.puts("#{name}=#{enabled}") } }
        puts "Selected CI components: #{plan.fetch('ci').select { |_name, enabled| enabled }.keys.join(', ')}"
        return plan
      end
      puts "Selected checks:"
      plan.fetch("checks").each { |request| puts "  #{JSON.generate(request)}" }
      return plan if dry
      plan.fetch("checks").each { |request| execute(request) }
      plan
    end

    def self.boolean(value)
      return true if value == true || value == "true"
      return false if value == false || value == "false"
      raise PipelineError, "Expected true or false"
    end

    def self.execute(request)
      component, operation = request.values_at("component", "operation")
      options = request.fetch("options", {})
      if %w[test_unit build e2e].include?(operation)
        return Runtime.invoke(operation, component, options)
      end
      context = RunContext.new(Config.new(Runtime::ROOT))
      begin
        packages = request.fetch("packages", [])
        packages = packages.split(",") if packages.is_a?(String)
        perform(context, component, operation, options, packages: packages)
      ensure
        context.close
      end
    end

    def self.perform(context, component, operation, options = {}, packages: [])
      case [component, operation]
      when ["core", "apple_test"] then Core.new(context).apple_test(options)
      when ["mac", "core_test"] then Mac.new(context).core_test(options)
      when ["mac", "screens_native_test"] then Mac.new(context).screens_native_test
      when ["mac", "screens_test"] then Mac.new(context).screens_test
      when ["mac", "screens_hevc_test"] then Mac.new(context).screens_hevc_test
      when ["mac", "markdown_check"] then markdown(context)
      when ["gateway", "deployment_test"]
        context.command(["python3", "-m", "unittest", "discover", "-s", "deploy/gateway/tests", "-p", "test_*.py"], timeout: 600, log: File.join(context.output, "deployment.log"))
      when ["gateway", "deployment_integration"]
        context.command(["python3", "deploy/gateway/tests/integration.py"], timeout: 1200, log: File.join(context.output, "gateway-transports.log"))
      when ["daemon", "linux_capture_test"] then LinuxCapture.new(context).test
      when ["portable", "contracts"]
        context.command([RbConfig.ruby, "-I", "fastlane/spec", "-e", "Dir['fastlane/spec/*_test.rb'].sort.each { |file| require_relative file }"], timeout: 300, log: File.join(context.output, "pipeline-contracts.log"))
        Contract.new(context).call("lint")
      when ["portable", "support_tests"]
        %w[scripts fastlane/spec/native].each do |directory|
          next unless File.directory?(File.join(context.root, directory))
          context.command(["python3", "-m", "unittest", "discover", "-s", directory, "-p", "*test.py"], timeout: 1200, log: File.join(context.output, "#{File.basename(directory)}-tests.log"))
        end
      when ["portable", "justfile_check"]
        context.command(["just", "--fmt", "--check"], timeout: 30)
        Dir.glob(File.join(context.root, "just/*.just")).each { |path| context.command(["just", "--justfile", path, "--fmt", "--check"], timeout: 30) }
      when ["portable", "workflow_check"] then workflows(context)
      when ["portable", "proto"]
        context.command(["bash", "scripts/generate-proto.sh"], timeout: 600)
        context.command(["bash", "apps/mac/scripts/sync-proto.sh"], timeout: 600) if RUBY_PLATFORM.include?("darwin")
      when ["portable", "go_test"], ["portable", "go_vet"]
        raise PipelineError, "Invalid Go package selection" unless !packages.empty? && packages.all? { |name| name.is_a?(String) && name.match?(/\A(?:\.\/|[A-Za-z0-9])[A-Za-z0-9_.\/-]*\z/) }
        argv = operation == "go_test" ? ["go", "test", "-race", "-p", "2"] : ["go", "vet"]
        context.command([*argv, *packages], timeout: 3600, log: File.join(context.output, "#{operation}.log"))
      when ["portable", "harness_test"]
        context.command(["npm", "--prefix", "internal/harness/runtime", "test"], timeout: 1200, log: File.join(context.output, "harness-tests.log"))
      when ["portable", "site_build"] then context.command(["just", "site", "build"], timeout: 300)
      else raise PipelineError, "Unknown typed check #{component}/#{operation}"
      end
    end

    def self.markdown(context)
      %w[ci test].each { |operation| context.command(["npm", "--prefix", "apps/mac/MarkdownPreview", operation], timeout: 300) }
      context.command(["npm", "--prefix", "apps/mac/MarkdownPreview", "run", "check"], timeout: 300)
    end

    def self.workflows(context)
      Dir.glob(File.join(context.root, ".github/{workflows/*.yml,actions/*/action.yml}")).each do |path|
        walk = lambda do |node|
          case node
          when Hash
            if node.key?("run") && !node["run"].match?(/\Ajust (?:pipeline|check-changed|site) [^\r\n]+\z/)
              raise PipelineError, "Workflow shell steps must call the shared facade: #{path}"
            end
            if node["uses"] && !node["uses"].start_with?("./") && !node["uses"].match?(/@[0-9a-f]{40}\z/)
              raise PipelineError, "Action must be pinned to a full SHA: #{path}"
            end
            node.each_value { |value| walk.call(value) }
          when Array then node.each { |value| walk.call(value) }
          end
        end
        walk.call(YAML.safe_load(File.read(path), aliases: true))
      end
      context.command(["go", "run", "github.com/rhysd/actionlint/cmd/actionlint@v1.7.12"], timeout: 300)
    end
  end
end
