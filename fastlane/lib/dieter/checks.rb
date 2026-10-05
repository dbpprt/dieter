# frozen_string_literal: true

require "optparse"
require "yaml"
require_relative "runtime"
require_relative "platforms/linux_capture"

module Dieter
  module Checks
    def self.cli(argv)
      $stdout.sync = true
      options = {}
      parser =
        OptionParser.new do |flags|
          flags.banner = "just check-changed [--dry-run] [--base REF] [--native] [--ci]"
          flags.on("--dry-run", "Inspect typed requests without executing checks") do
            options[:dry_run] = true
          end
          flags.on("--base REF", "Include branch changes against this merge base") do |value|
            options[:base] = value
          end
          flags.on("--ci", "Write affected component outputs to GITHUB_OUTPUT") do
            options[:ci] = true
          end
          flags.on("--native", "Also execute selected device/desktop integration checks") do
            options[:native] = true
          end
        end
      parser.parse!(argv)
      raise PipelineError, "Unexpected check arguments" unless argv.empty?
      invoke(options)
    end

    def self.invoke(options)
      options = options.transform_keys(&:to_sym)
      unless (options.keys - %i[dry_run base ci native output]).empty?
        raise PipelineError, "Unknown check options"
      end
      ci = boolean(options.fetch(:ci, false))
      dry = boolean(options.fetch(:dry_run, false))
      context = RunContext.new(Config.new(Runtime::ROOT), output: options[:output])
      begin
        base = options[:base] || (ci ? ENV["CI_CHANGE_BASE"] : nil)
        all =
          ci &&
            (
              %w[schedule workflow_dispatch].include?(ENV["GITHUB_EVENT_NAME"]) || base.nil? ||
                base.empty? || base.match?(/\A0+\z/)
            )
        plan =
          (
            if all
              {
                "paths" => [],
                "checks" => [],
                "ci" => %w[core macos ios android kmp].to_h { |name| [name, true] }
              }
            else
              Contract.new(context).call(
                "affected-checks",
                { base: base || "", kind: ci ? "ci" : "local" }
              )
            end
          )
        unless ci || boolean(options.fetch(:native, false))
          plan["nativeChecks"], plan["checks"] =
            plan
              .fetch("checks")
              .partition do |request|
                request["operation"] == "e2e" ||
                  %w[screens_native_test screens_test screens_hevc_test].include?(
                    request["operation"]
                  )
              end
        end
        Atomic.json(File.join(context.output, "affected-checks.json"), plan)
      ensure
        context.close
      end
      puts "Changed paths:"
      plan.fetch("paths").each { |path| puts "  #{path.inspect}" }
      if ci
        output = ENV.fetch("GITHUB_OUTPUT") { raise PipelineError, "--ci requires GITHUB_OUTPUT" }
        File.open(output, "a") do |file|
          plan.fetch("ci").each { |name, enabled| file.puts("#{name}=#{enabled}") }
        end
        puts "Selected CI components: #{plan.fetch("ci").select { |_name, enabled| enabled }.keys.join(", ")}"
        return plan
      end
      puts "Selected checks:"
      plan.fetch("checks").each { |request| puts "  #{JSON.generate(request)}" }
      unless plan.fetch("nativeChecks", []).empty?
        puts "Related native checks (select --native or execute specific catalog cases):"
        plan.fetch("nativeChecks").each { |request| puts "  #{JSON.generate(request)}" }
      end
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
      puts "Checking #{component}/#{operation}; evidence: #{context.output}"
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
      when %w[core apple_test]
        Core.new(context).apple_test(options)
      when %w[mac core_test]
        Mac.new(context).core_test(options)
      when %w[mac screens_native_test]
        Mac.new(context).screens_native_test
      when %w[mac screens_test]
        Mac.new(context).screens_test
      when %w[mac screens_hevc_test]
        Mac.new(context).screens_hevc_test
      when %w[mac markdown_check]
        markdown(context)
      when %w[gateway deployment_test]
        context.command(
          %w[python3 -m unittest discover -s deploy/gateway/tests -p test_*.py],
          timeout: 600,
          log: File.join(context.output, "deployment.log")
        )
      when %w[gateway deployment_integration]
        context.command(
          %w[python3 deploy/gateway/tests/integration.py],
          timeout: 1200,
          log: File.join(context.output, "gateway-transports.log")
        )
      when %w[daemon linux_capture_test]
        LinuxCapture.new(context).test
      when %w[portable contracts]
        context.command(
          [
            RbConfig.ruby,
            "-I",
            "fastlane/spec",
            "-e",
            "Dir['fastlane/spec/*_test.rb'].sort.each { |file| require_relative file }"
          ],
          timeout: 300,
          log: File.join(context.output, "pipeline-contracts.log")
        )
        Contract.new(context).call("lint")
      when %w[portable support_tests]
        %w[scripts fastlane/spec/native].each do |directory|
          next unless File.directory?(File.join(context.root, directory))
          context.command(
            ["python3", "-m", "unittest", "discover", "-s", directory, "-p", "*test.py"],
            timeout: 1200,
            log: File.join(context.output, "#{File.basename(directory)}-tests.log")
          )
        end
      when %w[portable justfile_check]
        context.command(%w[just --fmt --check], timeout: 30)
        Dir
          .glob(File.join(context.root, "just/*.just"))
          .each do |path|
            context.command(["just", "--justfile", path, "--fmt", "--check"], timeout: 30)
          end
      when %w[portable workflow_check]
        workflows(context)
      when %w[portable proto]
        context.command(%w[bash scripts/generate-proto.sh], timeout: 600)
        if RUBY_PLATFORM.include?("darwin")
          context.command(%w[bash apps/mac/scripts/sync-proto.sh], timeout: 600)
        end
      when %w[portable go_test], %w[portable go_vet]
        unless !packages.empty? &&
                 packages.all? { |name|
                   name.is_a?(String) && name.match?(%r{\A(?:\./|[A-Za-z0-9])[A-Za-z0-9_./-]*\z})
                 }
          raise PipelineError, "Invalid Go package selection"
        end

        go_mod_tidy(context) if operation == "go_test"
        argv = operation == "go_test" ? %w[go test -race -p 2] : %w[go vet]
        context.command(
          [*argv, *packages],
          timeout: 3600,
          log: File.join(context.output, "#{operation}.log")
        )
      when %w[portable harness_test]
        # -mod=mod would quietly rewrite untidy module files; check them first.

        context.command(
          %w[npm --prefix internal/harness/runtime test],
          timeout: 1200,
          log: File.join(context.output, "harness-tests.log")
        )
      when %w[portable site_build]
        context.command(%w[just site build], timeout: 300)
      else
        raise PipelineError, "Unknown typed check #{component}/#{operation}"
      end
    end

    # Fails when go.mod or go.sum differ from `go mod tidy`; never rewrites them.
    def self.go_mod_tidy(context)
      context.command(
        %w[go mod tidy -diff],
        timeout: 600,
        log: File.join(context.output, "go-mod-tidy.log")
      )
    end

    def self.markdown(context)
      %w[ci test].each do |operation|
        context.command(["npm", "--prefix", "apps/mac/MarkdownPreview", operation], timeout: 300)
      end
      context.command(%w[npm --prefix apps/mac/MarkdownPreview run check], timeout: 300)
    end

    def self.workflows(context)
      Dir
        .glob(File.join(context.root, ".github/{workflows/*.yml,actions/*/action.yml}"))
        .each do |path|
          walk =
            lambda do |node|
              case node
              when Hash
                if node.key?("run") &&
                     !node["run"].match?(/\Ajust (?:pipeline|check-changed|site) [^\r\n]+\z/)
                  raise PipelineError, "Workflow shell steps must call the shared facade: #{path}"
                end
                if node["uses"] && !node["uses"].start_with?("./") &&
                     !node["uses"].match?(/@[0-9a-f]{40}\z/)
                  raise PipelineError, "Action must be pinned to a full SHA: #{path}"
                end
                node.each_value { |value| walk.call(value) }
              when Array
                node.each { |value| walk.call(value) }
              end
            end
          walk.call(YAML.safe_load(File.read(path), aliases: true))
        end
      context.command(%w[go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12], timeout: 300)
    end
  end
end
