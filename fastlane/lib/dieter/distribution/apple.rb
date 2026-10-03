# frozen_string_literal: true

require "base64"
require "shellwords"
require "securerandom"

module Dieter
  class AppleSigning
    def initialize(context)
      @context = context
    end

    def secret(name)
      value = ENV[name]
      raise Unavailable, "Missing signing credential #{name}" unless value && !value.empty?
      @context.secrets << value
      value
    end

    def decoded(name, filename)
      data = Base64.strict_decode64(secret(name))
      raise PipelineError, "Invalid/oversized signing credential #{name}" if data.empty? || data.bytesize > 2 * 1024 * 1024
      @context.secrets << data.force_encoding(Encoding::UTF_8).scrub
      path = File.join(@context.private_dir, filename)
      Atomic.write(path, data)
      path
    rescue ArgumentError
      raise PipelineError, "Invalid base64 signing credential #{name}"
    end

    def keychain(certificate:, password:, kind: "Developer ID Application")
      raise PipelineError, "Distribution signing requires trusted CI main" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main"
      @context.lease("apple-signing")
      original = Shellwords.split(@context.command(["security", "list-keychains", "-d", "user"], timeout: 30))
      path = File.join(@context.private_dir, "signing-#{SecureRandom.uuid}.keychain-db")
      pin = SecureRandom.hex(32)
      @context.secrets << pin
      created = false
      begin
        @context.command(["security", "create-keychain", "-p", pin, path], timeout: 30)
        created = true
        @context.command(["security", "set-keychain-settings", "-lut", "21600", path], timeout: 30)
        @context.command(["security", "unlock-keychain", "-p", pin, path], timeout: 30)
        @context.command(["security", "import", certificate, "-k", path, "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productsign"], timeout: 30)
        @context.command(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", pin, path], timeout: 30)
        @context.command(["security", "list-keychains", "-d", "user", "-s", path, *original], timeout: 30)
        identities = @context.command(["security", "find-identity", "-v", path], timeout: 30)
        matches = identities.scan(/"(#{Regexp.escape(kind)}:[^"\n]+)"/).flatten.uniq
        raise PipelineError, "Temporary keychain must contain exactly one #{kind} identity" unless matches.length == 1
        yield(path, matches.first)
      ensure
        @context.during_cleanup do
          errors = []
          begin
            @context.command(["security", "list-keychains", "-d", "user", "-s", *original], timeout: 30)
          rescue StandardError => error
            errors << error.message
          end
          begin
            @context.command(["security", "delete-keychain", path], timeout: 30) if created
          rescue StandardError => error
            errors << error.message
          end
          raise CleanupError, errors.join("; ") unless errors.empty?
        end
      end
    end

    def notarize(path, staple: false, type: "execute")
      key = decoded("NOTARY_KEY_BASE64", "notary.p8")
      args = ["--key", key, "--key-id", secret("NOTARY_KEY_ID"), "--issuer", secret("NOTARY_ISSUER_ID")]
      output = @context.command(["xcrun", "notarytool", "submit", path, *args, "--wait", "--timeout", "30m", "--output-format", "json"], timeout: 1900, binary: true)
      result = JSON.parse(output)
      Atomic.json(File.join(@context.output, "notary-#{File.basename(path)}.json"), result.slice("id", "status", "message"))
      raise PipelineError, "Notarization #{result['status']} for #{File.basename(path)}" unless result["status"] == "Accepted"
      if staple
        @context.command(["xcrun", "stapler", "staple", path], timeout: 120)
        @context.command(["xcrun", "stapler", "validate", path], timeout: 120)
        @context.command(["spctl", "--assess", "--type", type, "--verbose=2", path], timeout: 120)
      end
    end

    def with_profiles(profiles, root: File.join(Dir.home, "Library/Developer/Xcode/UserData/Provisioning Profiles"))
      @context.lease("apple-signing")
      FileUtils.mkdir_p(root)
      originals = {}
      begin
        profiles.each do |uuid, input|
          raise PipelineError, "Unsafe provisioning UUID" unless uuid.match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
          path = File.join(root, "#{uuid}.mobileprovision")
          raise PipelineError, "Provisioning path is not a regular file" if File.symlink?(path) || (File.exist?(path) && !File.file?(path))
          originals[path] = File.file?(path) ? [File.binread(path), File.stat(path).mode & 0o777] : nil
          Atomic.write(path, File.binread(input))
        end
        yield
      ensure
        @context.during_cleanup do
          originals.each { |path, previous| previous ? Atomic.write(path, previous[0], mode: previous[1]) : File.unlink(path) if previous || File.exist?(path) }
        end
      end
    end

    def sign_mac_app(bundle)
      certificate = decoded("CERTIFICATE_BASE64", "developer-id.p12")
      keychain(certificate: certificate, password: secret("CERTIFICATE_PASSWORD")) do |keychain, identity|
        # Sign leaves before their enclosing bundles; the Kotlin framework also
        # embeds native code and needs the same Developer ID identity.
        frameworks = Dir.glob(File.join(bundle, "Contents/Frameworks/*.framework"))
        frameworks.each do |framework|
          @context.command(["codesign", "--force", "--options", "runtime", "--timestamp", "--keychain", keychain, "--sign", identity, framework], timeout: 120)
        end
        @context.command(["codesign", "--force", "--options", "runtime", "--timestamp", "--keychain", keychain, "--sign", identity, bundle], timeout: 120)
        @context.command(["codesign", "--verify", "--deep", "--strict", bundle], timeout: 120)
      end
      submission = File.join(@context.private_dir, "Dieter.zip")
      @context.command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, submission], timeout: 120)
      notarize(submission)
      @context.command(["xcrun", "stapler", "staple", bundle], timeout: 120)
      @context.command(["xcrun", "stapler", "validate", bundle], timeout: 120)
      @context.command(["spctl", "--assess", "--type", "execute", bundle], timeout: 120)
    end

    def sign_daemon(stage)
      certificate = decoded("CERTIFICATE_BASE64", "developer-id.p12")
      keychain(certificate: certificate, password: secret("CERTIFICATE_PASSWORD")) do |keychain, identity|
        {"dieter" => "com.dbpprt.dieter.daemon", "dieter-capture" => "com.dbpprt.dieter.capture"}.each do |name, identifier|
          path = File.join(stage, name)
          @context.command(["codesign", "--force", "--options", "runtime", "--timestamp", "--identifier", identifier, "--keychain", keychain, "--sign", identity, path], timeout: 120)
          @context.command(["codesign", "--verify", "--strict", path], timeout: 120)
        end
      end
      submission = File.join(@context.private_dir, "daemon.zip")
      @context.command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", stage, submission], timeout: 120)
      notarize(submission)
      @context.command(["go", "test", "./internal/serviceruntime", "-run", "^TestSignedServiceRuntimeSmoke$", "-count=1", "-v"], environment: {"DIETER_SIGNED_SERVICE_SOURCE" => stage}, timeout: 1200, log: File.join(@context.output, "signed-runtime.log"))
    end

    def installer(stage, version)
      output = File.join(@context.output, "dieter-darwin-arm64.pkg")
      @context.command(["python3", "-c", "import sys; from pathlib import Path; from fastlane.lib.dieter.native.installer import build; build(Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3])", stage, output, version], timeout: 120)
      certificate = decoded("INSTALLER_CERTIFICATE_BASE64", "installer.p12")
      signed = File.join(@context.private_dir, "signed.pkg")
      keychain(certificate: certificate, password: secret("INSTALLER_CERTIFICATE_PASSWORD"), kind: "Developer ID Installer") do |keychain, identity|
        @context.command(["productsign", "--sign", identity, "--keychain", keychain, output, signed], timeout: 120)
      end
      @context.command(["pkgutil", "--check-signature", signed], timeout: 120)
      notarize(signed, staple: true, type: "install")
      FileUtils.mv(signed, output)
      output
    end
  end
end
