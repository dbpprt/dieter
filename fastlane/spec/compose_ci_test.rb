# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "yaml"
require_relative "../lib/dieter/compose_ci"

class ComposeCITest < Minitest::Test
  def test_portable_preview_survives_download_and_rejects_mutation_wrong_source_and_wrong_app
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      Dir.mkdir(output)
      apk = File.join(root, "app.apk")
      File.write(apk, "tested APK bytes")
      artifacts = File.join(root, "artifacts.json")
      source = "a" * 40
      Dieter::ArtifactSet.new(
        component: "compose-android",
        source: source,
        configuration: "debug",
        products: {
          "apk" => apk
        }
      ).write(artifacts)
      context =
        Struct.new(:root, :output, :environment).new(
          root,
          output,
          { "DIETER_RELEASE_VERSION" => "0.4.414-dev.1+abcdef01" }
        )
      context.define_singleton_method(:command) { |*, **| source }
      staged =
        Dieter::PreviewArtifact.stage(
          context,
          manifest: artifacts,
          component: "compose-android",
          product: "apk"
        )
      download = File.join(root, "download")
      FileUtils.cp_r(staged, download)
      FileUtils.rm_r(staged)
      path = File.join(download, "manifest.json")
      verify = ->(**options) do
        Dieter::PreviewArtifact.verify(
          path,
          source: source,
          component: "compose-android",
          kind: "apk",
          **options
        )
      end
      value = verify.call
      assert_equal "0.4.414-dev.1+abcdef01", value.dig("toolchain", "version")
      assert_equal File.join(download, "compose-android.apk"),
                   value.fetch("products").first.fetch("path")
      assert_raises(Dieter::PipelineError) { verify.call(source: "b" * 40) }
      assert_raises(Dieter::PipelineError) { verify.call(component: "android") }
      assert_raises(Dieter::PipelineError) { verify.call(kind: "simulator-app") }
      File.write(File.join(download, "compose-android.apk"), "changed after testing")
      assert_raises(Dieter::PipelineError) { verify.call }
    end
  end

  def test_portable_manifests_reject_products_outside_the_package
    Dir.mktmpdir do |root|
      artifact = File.join(root, "artifact")
      File.write(artifact, "payload")
      directory = File.join(root, "package")
      Dir.mkdir(directory)
      path = File.join(directory, "manifest.json")
      set =
        Dieter::ArtifactSet.new(
          component: "compose-android",
          source: "source",
          configuration: "debug",
          products: {
            "apk" => artifact
          }
        )
      assert_raises(Dieter::PipelineError) { set.write(path, portable: true) }
      value = Marshal.load(Marshal.dump(set.manifest))
      value.fetch("products").first["path"] = "../artifact"
      Dieter::Atomic.json(path, value)
      assert_raises(Dieter::PipelineError) { Dieter::ArtifactSet.load(path) }
    end
  end

  def test_compose_ios_reuse_keeps_its_bundle_identity_and_invalidates_changed_host_inputs
    Dir.mktmpdir do |root|
      app = File.join(root, "products/app")
      FileUtils.mkdir_p(File.dirname(app))
      File.write(app, "compiled app")
      input = "apps/mobile/ios/App/Host.swift"
      FileUtils.mkdir_p(File.join(root, File.dirname(input)))
      File.write(File.join(root, input), "original host")
      context =
        Struct.new(:root, :output, :private_dir, :environment).new(
          root,
          root,
          root,
          { "DIETER_RELEASE_VERSION" => "0.4.414" }
        )
      context.define_singleton_method(:command) do |argv, **|
        case argv[0..1]
        when %w[git rev-parse]
          "a" * 40
        when %w[xcodebuild -version]
          "Xcode 26.5"
        when %w[git ls-files]
          raise "Compose host omitted from build identity" unless argv.include?("apps/mobile/ios")
          input + "\0"
        else
          raise "Unexpected command"
        end
      end
      adapter = Dieter::ComposeSpikeIOS.new(context)
      manifest = File.join(root, "artifacts.json")
      Dieter::ArtifactSet.new(
        component: "compose-ios",
        source: "a" * 40,
        configuration: "debug",
        toolchain: {
          "sdk" => "iphonesimulator",
          "xcode" => "Xcode 26.5",
          "input_sha256" => Dieter::BuildInputs.digest(context, paths: adapter.build_input_paths)
        },
        products: {
          "test-products" => File.dirname(app)
        }
      ).write(manifest)
      adapter.prepared_products(manifest)
      target = { "kind" => "simulator", "name" => "ios-ipad" }
      adapter.send(:reuse_products, target)
      assert_equal "com.dbpprt.dieter.compose.spike.ios", adapter.instance_variable_get(:@bundle_id)
      assert_equal "compose-spike", context.environment.fetch("DIETER_SWIFT_TEST_SCOPE")
      assert_raises(Dieter::PipelineError) do
        Dieter::IOS
          .new(context)
          .tap { |shipping| shipping.prepared_products(manifest) }
          .send(:reuse_products, target)
      end
      File.write(File.join(root, input), "edited host")
      assert_raises(Dieter::PipelineError) { adapter.send(:reuse_products, target) }
    end
  end

  def test_preview_workflows_require_qualification_and_have_no_distribution_credentials
    root = Dieter::Runtime::ROOT
    ci = YAML.safe_load(File.read(File.join(root, ".github/workflows/ci.yml")))
    delivery = ci.fetch("jobs").fetch("compose-previews")
    assert_equal "qualification", delivery.fetch("needs")
    assert_includes delivery.fetch("if"), "refs/heads/main"
    refute delivery.key?("secrets")
    qualification =
      YAML.safe_load(File.read(File.join(root, ".github/workflows/qualification.yml")))
    %w[compose-core compose-android compose-ios].each do |name|
      assert_includes qualification.fetch("jobs").fetch("required").fetch("needs"), name
    end
    %w[compose-mobile-check compose-mobile-deliver].each do |name|
      text = File.read(File.join(root, ".github/workflows/#{name}.yml"))
      workflow = YAML.safe_load(text)
      assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
      refute_match(
        /TestFlight|app_store_connect|secrets:|release-distribute|candidate|action:distribute/i,
        text
      )
    end
    steps =
      YAML
        .safe_load(File.read(File.join(root, ".github/workflows/compose-mobile-deliver.yml")))
        .fetch("jobs")
        .fetch("deliver")
        .fetch("steps")
    verification = steps.select { |step| step.fetch("run", "").include?("action:verify") }
    assert_equal 2, verification.length
    refute steps.any? { |step| step.fetch("run", "").include?("action:check") }
  end
end
