# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/fixtures/ios_media"

class IOSMediaOwnershipTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("ios-media-")
    @journal = File.join(@root, "owner.json")
    @id = "com.example.dieter.e2e"
    @owner = {"udid" => "exact-phone", "owner_pid" => Process.pid, "packages" => [@id, @id + ".uitests.xctrunner"]}
    Dieter::Atomic.json(@journal, @owner)
    image = File.join(@root, "apps/android/design/reference/phone-board.png")
    FileUtils.mkdir_p(File.dirname(image))
    File.write(image, "owned PNG fixture")
    @commands = []
    commands = @commands
    info = {"CFBundleIdentifier" => @id, "CFBundleDisplayName" => "Dieter E2E", "UIFileSharingEnabled" => true, "LSSupportsOpeningDocumentsInPlace" => true}
    @info = info
    @context = Object.new
    root = @root
    @context.define_singleton_method(:root) { root }
    @context.define_singleton_method(:output) { root }
    @context.define_singleton_method(:command) { |argv, **| commands << argv; argv.first == "plutil" ? JSON.generate(info) : "" }
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def fixture(id: @id, device: "exact-phone")
    Dieter::IOSMediaFixture.new(@context, {"kind" => "device", "udid" => device}, app: File.join(@root, "Dieter.app"), bundle_id: id, journal: @journal)
  end

  def test_no_device_mutation_without_matching_live_ownership_and_e2e_identity
    assert_raises(Dieter::PipelineError) { fixture(id: "com.example.operator").stage }
    assert_raises(Dieter::PipelineError) { fixture(device: "another-phone").stage }
    Dieter::Atomic.json(@journal, @owner.merge("owner_pid" => Process.pid + 1))
    assert_raises(Dieter::PipelineError) { fixture.stage }
    assert_empty @commands
  end

  def test_media_is_copied_only_to_the_owned_application_container
    name = fixture.stage
    copy = @commands.find { |argv| argv.include?("copy") }
    assert_equal "exact-phone", copy[copy.index("--device") + 1]
    assert_equal "appDataContainer", copy[copy.index("--domain-type") + 1]
    assert_equal @id, copy[copy.index("--domain-identifier") + 1]
    assert_equal "Documents/#{name}", copy[copy.index("--destination") + 1]
    refute copy.include?("--remove-existing-content")
    receipt = JSON.parse(File.read(File.join(@root, "owned-share-media.json")))
    assert_equal @id, receipt.fetch("bundle_id")
    assert_equal "owned-app-documents", receipt.fetch("location")
  end

  def test_a_mismatched_built_application_is_never_installed
    @info["CFBundleIdentifier"] = "com.example.operator"
    assert_raises(Dieter::PipelineError) { fixture.stage }
    assert_equal ["plutil"], @commands.map(&:first)
  end
end
