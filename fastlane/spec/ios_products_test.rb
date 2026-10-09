# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/platforms/ios"

class IOSPreparedProductsTest < Minitest::Test
  def test_reuse_rejects_changed_source_product_bytes_toolchain_and_physical_targets
    Dir.mktmpdir do |root|
      products = File.join(root, "Build/Products")
      FileUtils.mkdir_p(products)
      app = File.join(products, "app")
      File.write(app, "immutable app bytes")
      source = File.join(root, "source.swift")
      File.write(source, "original source")
      context = Struct.new(:root, :output, :private_dir, :environment).new(root, root, root, {"DIETER_RELEASE_VERSION" => "0.4.413"})
      xcode = "Xcode 26.5"
      context.define_singleton_method(:command) do |argv, **|
        case argv[0..1]
        when %w[git rev-parse] then "a" * 40
        when %w[git ls-files] then "source.swift\0"
        when %w[xcodebuild -version] then xcode
        else raise "Unexpected command: #{argv.inspect}"
        end
      end
      manifest = File.join(root, "artifacts.json")
      Dieter::ArtifactSet.new(component: "ios", source: "a" * 40, configuration: "debug",
        toolchain: {"input_sha256" => Dieter::BuildInputs.digest(context), "sdk" => "iphonesimulator", "xcode" => xcode},
        products: {"test-products" => products}).write(manifest)
      adapter = Dieter::IOS.new(context)
      adapter.prepared_products(manifest)
      target = {"kind" => "simulator", "name" => "ios-ipad"}
      adapter.send(:reuse_products, target)
      assert_equal products, adapter.instance_variable_get(:@products)
      File.write(source, "changed source")
      assert_raises(Dieter::PipelineError) { adapter.send(:reuse_products, target) }
      File.write(source, "original source")
      xcode = "Xcode 27.0"
      assert_raises(Dieter::PipelineError) { adapter.send(:reuse_products, target) }
      xcode = "Xcode 26.5"
      File.write(app, "different app bytes")
      assert_raises(Dieter::PipelineError) { adapter.send(:reuse_products, target) }
      assert_raises(Dieter::PipelineError) { adapter.send(:reuse_products, target.merge("kind" => "device")) }
    end
  end
end
