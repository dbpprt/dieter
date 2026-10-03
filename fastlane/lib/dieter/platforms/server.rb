# frozen_string_literal: true

require "fileutils"
require_relative "../pipeline/artifacts"
require_relative "../pipeline/source"

module Dieter
  class Server
    def initialize(context, component:, actions: nil)
      @context, @component, @root = context, component, context.root
      @target = "./cmd/dieter#{component == 'gateway' ? '-gateway' : ''}"
      @name = "dieter#{component == 'gateway' ? '-gateway' : ''}"
    end

    def unit(options)
      packages = @context.command(["go", "list", "-deps", @target], timeout: 120).lines.map(&:strip).select { |name| name.start_with?("github.com/dbpprt/dieter/") }
      argv = ["go", "test", "-race", "-p", "2", *packages]
      argv += ["-run", options["filter"]] if options["filter"]
      @context.command(argv, timeout: 3600, log: File.join(@context.output, "unit.log"))
      return unless @component == "gateway"
      @context.command(["python3", "-m", "unittest", "discover", "-s", "deploy/gateway/tests", "-p", "test_*.py"], timeout: 600, log: File.join(@context.output, "deployment.log"))
    end

    def build(options)
      os, arch = target(options)
      version = @context.environment["DIETER_RELEASE_VERSION"] || SourceIdentity.version(@context)
      binary = File.join(@context.output, @name)
      @context.command(["go", "build", "-trimpath", "-ldflags", "-s -w -X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion=#{version}", "-o", binary, @target], environment: {"CGO_ENABLED" => "0", "GOOS" => os, "GOARCH" => arch}, timeout: 1200, log: File.join(@context.output, "build.log"))
      source = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      ArtifactSet.new(component: @component, source: source, configuration: options.fetch("configuration", "debug"), products: {"binary" => binary}).write(File.join(@context.output, "artifacts.json"))
      binary
    end

    def candidate(options, identity)
      @context.environment.merge!(identity.environment)
      os, arch = target(options)
      asset = "#{@name}-#{os}-#{arch}"
      stage = File.join(@context.output, asset)
      Dir.mkdir(stage, 0o700)
      binary = build(options)
      FileUtils.cp(binary, File.join(stage, @name))
      FileUtils.cp(File.join(@root, "LICENSE"), stage)
      Atomic.write(File.join(stage, "VERSION"), identity.version + "\n")
      if @component == "daemon"
        FileUtils.cp(File.join(@root, "scripts/install.sh"), stage)
        helper = File.join(stage, "dieter-capture")
        script = os == "linux" ? "native/linux-capture/build-release.sh" : "native/macos-capture/build.sh"
        @context.command(["bash", script, helper], environment: {"GOARCH" => arch}, timeout: 600)
        if os == "darwin"
          raise PipelineError, "Apple signing adapter is required" unless block_given?
          yield(stage)
        end
      end
      host_os = @context.command(["go", "env", "GOHOSTOS"], timeout: 30).strip
      host_arch = @context.command(["go", "env", "GOHOSTARCH"], timeout: 30).strip
      if os == host_os && arch == host_arch
        actual = @context.command([File.join(stage, @name), "--version"], timeout: 30).strip
        raise PipelineError, "Packaged #{@component} identity mismatch: #{actual}" unless actual == identity.version
        if @component == "daemon"
          capabilities = JSON.parse(@context.command([File.join(stage, "dieter-capture"), "--capabilities", "--synthetic", "true"], timeout: 30))
          raise PipelineError, "Packaged capture helper lacks H264" unless JSON.generate(capabilities).include?("H264")
        end
      else
        raise Unavailable, "Release target #{os}/#{arch} must be executed on a qualified matching runner"
      end
      archive = File.join(@context.output, "#{asset}.tar.gz")
      @context.command(["tar", "-C", @context.output, "-czf", archive, asset], timeout: 120)
      archive
    end

    def vulncheck
      toolchain = File.read(File.join(@root, "go.mod"))[/^go (.+)$/, 1]
      @context.command(["go", "run", "golang.org/x/vuln/cmd/govulncheck@v1.8.0", @target], environment: {"GOTOOLCHAIN" => "go#{toolchain}"}, timeout: 1200, log: File.join(@context.output, "vulnerabilities.log"))
    end

    def target(options)
      profile = @context.config.profile(options["profile"] || @context.config.default_profile(@component), component: @component)
      os, arch = profile.values_at("target_os", "architecture")
      os = @context.command(["go", "env", "GOHOSTOS"], timeout: 30).strip if os == "native"
      arch = @context.command(["go", "env", "GOHOSTARCH"], timeout: 30).strip if arch == "native"
      [os, arch]
    end
  end
end
