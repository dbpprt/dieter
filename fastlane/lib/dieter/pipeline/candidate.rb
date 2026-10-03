# frozen_string_literal: true

require_relative "identity"
require_relative "artifacts"
require_relative "../distribution/github"
require_relative "../distribution/apple"
require_relative "../distribution/gateway"
require_relative "../platforms/server"

module Dieter
  class CandidatePipeline
    def initialize(context, component, options, actions: nil, github: nil)
      @context, @component, @options, @actions = context, component, options.transform_keys(&:to_s), actions
      @options.delete("profile") if @options["profile"] == ""
      raise PipelineError, "Unknown candidate options" unless (@options.keys - %w[identity profile output phase products]).empty?
      @phase = @options.fetch("phase", "full")
      raise PipelineError, "Candidate phase must be prepare, retain or full" unless %w[prepare retain full].include?(@phase)
      @identity = ReleaseIdentity.load(@options.fetch("identity"), policy: context.config.policy)
      @github = github || GitHubDestination.new(context)
    end

    def run
      source = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      raise PipelineError, "Candidate checkout does not match reserved source" unless source == @identity.source
      @context.environment.merge!(@identity.environment)
      target = if %w[daemon gateway].include?(@component)
                 Server.new(@context, component: @component).target(@options).join("-")
               end
      name = [@component, target].compact.join("-")
      raise PipelineError, "Unrequired candidate #{name}" unless @context.config.policy.fetch("required_components").include?(name)
      if ENV["GITHUB_OUTPUT"]
        File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("tag=#{@identity.tag}\ncomponent=#{name}") }
      end
      manifest_name = "candidate-#{name}.json"
      if @phase == "retain"
        directory = File.expand_path(@options.fetch("products"), @context.root)
        manifest = read_manifest(File.join(directory, manifest_name))
        self.class.validate(manifest, @identity, directory, expected: name)
        return retain(name, manifest, directory, manifest_name)
      end
      producer = File.join(@context.output, "producer")
      Dir.mkdir(producer, 0o700)
      assets = @github.release(@identity.tag).fetch("assets")
      if assets.any? { |asset| asset["name"] == manifest_name }
        @github.download(@identity, manifest_name, File.join(producer, manifest_name))
        manifest = read_manifest(File.join(producer, manifest_name))
        manifest.fetch("artifacts").each { |item| @github.download(@identity, item.fetch("name"), File.join(producer, item.fetch("name"))) }
        self.class.validate(manifest, @identity, producer, expected: name)
        checkpoint_output(false)
        puts "Reused retained immutable #{name} candidate"
        return manifest
      end
      recovered = recover_producer(name, producer, manifest_name)
      if recovered
        checkpoint_output(false)
        return @phase == "prepare" ? recovered : retain(name, recovered, producer, manifest_name)
      end
      # A payload without its producer checkpoint cannot be reconstructed by
      # signing another copy under an already used immutable reservation.
      expected_names = @github.receipts(@identity, "candidate-#{name}").flat_map { |receipt| receipt.fetch("artifacts", []) }
      if !expected_names.empty? || assets.any? { |asset| expected_product_names(name).include?(asset["name"]) }
        raise Unavailable, "Partial candidate has no recoverable producer artifact; preserve this draft and reserve a new source revision"
      end
      puts "Candidate #{name}: build, sign, package, verify"
      products = produce
      manifest = {"schema_version" => 1, "component" => name, "identity_sha256" => @identity.digest, "source_revision" => source, "release_version" => @identity.version, "native_build" => @identity.build, "qualification" => "passed", "artifacts" => products.map { |path| {"name" => File.basename(path), "sha256" => ArtifactSet.sha256(path), "bytes" => File.size(path)} }}
      products.each { |path| FileUtils.cp(path, producer) }
      Atomic.json(File.join(producer, manifest_name), manifest)
      self.class.validate(manifest, @identity, producer, expected: name)
      checkpoint_output(true)
      @phase == "prepare" ? manifest : retain(name, manifest, producer, manifest_name)
    ensure
      @context.close
    end

    def self.validate(manifest, identity, directory, expected: nil)
      raise PipelineError, "Invalid candidate manifest" unless manifest.is_a?(Hash) && manifest["schema_version"] == 1 && manifest["qualification"] == "passed" && manifest["artifacts"].is_a?(Array) && (1..16).cover?(manifest["artifacts"].length)
      raise PipelineError, "Candidate identity mismatch" unless manifest["identity_sha256"] == identity.digest && manifest["source_revision"] == identity.source && manifest["release_version"] == identity.version && manifest["native_build"] == identity.build
      raise PipelineError, "Candidate component mismatch" if expected && manifest["component"] != expected
      names = []
      manifest.fetch("artifacts").each do |item|
        raise PipelineError, "Invalid candidate artifact fields" unless item.is_a?(Hash) && item.keys.sort == %w[bytes name sha256] && item["name"].is_a?(String) && item["sha256"].is_a?(String) && item["sha256"].match?(/\A[0-9a-f]{64}\z/) && item["bytes"].is_a?(Integer) && (1..1_073_741_824).cover?(item["bytes"])
        name = item.fetch("name")
        raise PipelineError, "Unsafe/duplicate candidate artifact name" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]+\z/) && !names.include?(name)
        names << name
        path = File.join(directory, name)
        raise PipelineError, "Candidate bytes/hash mismatch for #{name}" unless File.file?(path) && !File.symlink?(path) && File.size(path) == item.fetch("bytes") && ArtifactSet.sha256(path) == item.fetch("sha256")
      end
      manifest
    end

    private

    def checkpoint_output(required)
      return unless ENV["GITHUB_OUTPUT"]
      File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("checkpoint_required=#{required}") }
    end

    def read_manifest(path)
      raise PipelineError, "Candidate manifest must be a bounded regular file" if File.symlink?(path) || !File.file?(path) || File.size(path) > 128 * 1024
      JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false)
    end

    def retain(name, manifest, directory, manifest_name)
      @github.with_claim(@identity, "candidate-#{name}") do
        @github.receipt(@identity, "candidate-#{name}", {"state" => "retaining", "artifacts" => manifest.fetch("artifacts").map { |item| item.fetch("name") }})
        manifest.fetch("artifacts").each { |item| @github.upload_immutable(@identity, File.join(directory, item.fetch("name"))) }
        @github.upload_immutable(@identity, File.join(directory, manifest_name))
      end
      manifest
    end

    def recover_producer(name, directory, manifest_name)
      artifact_name = "producer-#{@identity.tag}-#{name}"
      values = @github.api("actions/artifacts?per_page=100&name=#{URI.encode_www_form_component(artifact_name)}").fetch("artifacts")
      matching = values.select { |artifact| artifact["name"] == artifact_name && !artifact["expired"] && artifact.dig("workflow_run", "head_sha") == @identity.source }
      matching.sort_by { |artifact| artifact.fetch("id") }.reverse_each do |artifact|
        workflow = @github.api("actions/runs/#{artifact.fetch('workflow_run').fetch('id')}")
        next unless workflow["path"] == ".github/workflows/release.yml" && workflow["head_branch"] == "main" && workflow["head_sha"] == @identity.source
        @context.command(["gh", "run", "download", artifact.fetch("workflow_run").fetch("id").to_s, "--repo", @github.repository, "--name", artifact_name, "--dir", directory], timeout: 600)
        manifest = read_manifest(File.join(directory, manifest_name))
        self.class.validate(manifest, @identity, directory, expected: name)
        puts "Recovered exact #{name} producer bytes from run #{workflow.fetch('id')}"
        return manifest
      end
      nil
    end

    def expected_product_names(name)
      return %w[Dieter-Android.apk] if name == "android"
      return %w[Dieter-iOS.ipa] if name == "ios"
      return %w[Dieter-macOS-arm64.zip] if name == "mac"
      return %w[dieter-gateway-deploy.tar.gz gateway-manifest.json gateway-manifest.sigstore.json gateway-release.lock.json] if name == "gateway-oci"
      ["#{name.sub(/\Adaemon-/, 'dieter-').sub(/\Agateway-/, 'dieter-gateway-')}.tar.gz"]
    end

    def produce
      signer = AppleSigning.new(@context)
      case @component
      when "gateway-oci"
        GatewayOCI.new(@context, @identity).candidate
      when "daemon", "gateway"
        adapter = Server.new(@context, component: @component)
        adapter.vulncheck
        installer = nil
        archive = adapter.candidate(@options, @identity) do |stage|
          signer.sign_daemon(stage)
          installer = signer.installer(stage, @identity.version)
        end
        [archive, installer].compact
      when "android"
        android_candidate(signer)
      when "mac"
        bundle = Mac.new(@context, actions: @actions).build({"configuration" => "release"})
        @context.command(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleShortVersionString #{@identity.version}", File.join(bundle, "Contents/Info.plist")], timeout: 30)
        @context.command(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleVersion #{@identity.apple_build}", File.join(bundle, "Contents/Info.plist")], timeout: 30)
        signer.sign_mac_app(bundle)
        archive = File.join(@context.output, "Dieter-macOS-arm64.zip")
        @context.command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive], timeout: 120)
        extracted = File.join(@context.private_dir, "mac-export")
        @context.command(["ditto", "-x", "-k", archive, extracted], timeout: 120)
        @context.command(["codesign", "--verify", "--deep", "--strict", File.join(extracted, "Dieter.app")], timeout: 120)
        [archive]
      when "ios"
        [ios_candidate(signer)]
      end
    end

    def android_candidate(signer)
      keystore = signer.decoded("ANDROID_KEYSTORE_BASE64", "android-release.jks")
      @context.environment.merge!({"DIETER_ANDROID_KEYSTORE_PATH" => keystore, "DIETER_ANDROID_KEYSTORE_PASSWORD" => signer.secret("DIETER_ANDROID_KEYSTORE_PASSWORD"), "DIETER_ANDROID_KEY_ALIAS" => signer.secret("DIETER_ANDROID_KEY_ALIAS"), "DIETER_ANDROID_KEY_PASSWORD" => signer.secret("DIETER_ANDROID_KEY_PASSWORD")})
      path = Android.new(@context, actions: @actions).build({"configuration" => "release"})
      archive = File.join(@context.output, "Dieter-Android.apk")
      FileUtils.cp(path, archive)
      sdk = @context.environment.fetch("ANDROID_HOME")
      tools = File.join(sdk, "build-tools/37.0.0")
      @context.command([File.join(tools, "apksigner"), "verify", "--verbose", "--print-certs", archive], timeout: 120)
      badging = @context.command([File.join(tools, "aapt2"), "dump", "badging", archive], timeout: 30)
      raise PipelineError, "Release APK identity/debug mismatch" unless badging.start_with?("package: name='com.dbpprt.dieter' ") && badging.include?("versionName='#{@identity.version}'") && badging.include?("versionCode='#{@identity.build}'") && !badging.include?("application-debuggable")
      manifest = @context.command([File.join(tools, "aapt2"), "dump", "xmltree", archive, "--file", "AndroidManifest.xml"], timeout: 30)
      raise PipelineError, "Release APK contains instrumentation" if manifest.match?(/E: instrumentation|com.dbpprt.dieter.e2e|androidx.compose.ui.test/)
      [archive]
    end

    def ios_candidate(signer)
      @context.lease("apple-build")
      SharedFramework.new(@context).build(configuration: "release", platforms: "all")
      metadata = JSON.parse(@context.command(["python3", "-c", "import os,json; from fastlane.lib.dieter.native.ios_metadata import load_material; m=load_material(os.environ); print(json.dumps({'app':m.metadata,'share':m.share_metadata}))"], timeout: 120, binary: true))
      app, share = metadata.values_at("app", "share")
      certificate = signer.decoded("IOS_DISTRIBUTION_CERTIFICATE_BASE64", "ios-distribution.p12")
      profiles = {app.fetch("profile_uuid") => signer.decoded("IOS_PROVISIONING_PROFILE_BASE64", "app.mobileprovision"), share.fetch("profile_uuid") => signer.decoded("IOS_SHARE_PROVISIONING_PROFILE_BASE64", "share.mobileprovision")}
      signer.with_profiles(profiles) do
        signer.keychain(certificate: certificate, password: signer.secret("IOS_DISTRIBUTION_CERTIFICATE_PASSWORD"), kind: "Apple Distribution") do |_keychain, identity|
          archive = File.join(@context.output, "Dieter.xcarchive")
          @context.command(["xcodebuild", "-skipPackagePluginValidation", "-project", "apps/ios/DieterIOS.xcodeproj", "-scheme", "DieterIOS", "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", File.join(@context.root, "apps/ios/.build/DerivedData"), "-archivePath", archive, "archive", "MARKETING_VERSION=#{@identity.version}", "CURRENT_PROJECT_VERSION=#{@identity.apple_build}", "DIETER_RELEASE_VERSION=#{@identity.version}", "DIETER_IOS_BUNDLE_ID=#{app.fetch('bundle_id')}", "DIETER_IOS_TEAM_ID=#{app.fetch('team_id')}", "DIETER_IOS_SIGN_STYLE=Manual", "DIETER_IOS_SIGN_IDENTITY=#{identity}", "DIETER_IOS_PROFILE_SPECIFIER=#{app.fetch('profile_uuid')}", "DIETER_IOS_SHARE_PROFILE_SPECIFIER=#{share.fetch('profile_uuid')}"], timeout: 2400, log: File.join(@context.output, "archive.log"))
          @context.command(["python3", "-c", "from pathlib import Path; import sys; from fastlane.lib.dieter.native.ios_metadata import validate_archive; validate_archive(Path(sys.argv[1]),sys.argv[2],sys.argv[3],sys.argv[4],signed=True)", archive, @identity.version, @identity.apple_build, app.fetch("bundle_id")], timeout: 120)
          options = {"method" => "app-store-connect", "destination" => "export", "signingStyle" => "manual", "teamID" => app.fetch("team_id"), "signingCertificate" => identity, "provisioningProfiles" => {app.fetch("bundle_id") => app.fetch("profile_uuid"), share.fetch("bundle_id") => share.fetch("profile_uuid")}, "manageAppVersionAndBuildNumber" => false, "uploadSymbols" => true}
          spec = File.join(@context.private_dir, "ExportOptions.plist")
          @context.command(["python3", "-c", "import sys,json,plistlib; from pathlib import Path; Path(sys.argv[1]).write_bytes(plistlib.dumps(json.load(sys.stdin)))", spec], input: JSON.generate(options), timeout: 30)
          export = File.join(@context.private_dir, "Export")
          @context.command(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", export, "-exportOptionsPlist", spec], timeout: 1200, log: File.join(@context.output, "export.log"))
          ipa = @context.command(["python3", "-c", "from pathlib import Path; import sys; from fastlane.lib.dieter.native.ios_metadata import validate_ipa; print(validate_ipa(Path(sys.argv[1]),sys.argv[2],sys.argv[3],sys.argv[4]))", export, @identity.version, @identity.apple_build, app.fetch("bundle_id")], timeout: 120).strip
          destination = File.join(@context.output, "Dieter-iOS.ipa")
          FileUtils.cp(ipa, destination)
          return destination
        end
      end
    end
  end
end
