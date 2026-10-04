# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/dieter/pipeline/context"
require_relative "../lib/dieter/platforms/emulator"

class AndroidEmulatorTest < Minitest::Test
  class Child
    attr_reader :pid, :stops
    attr_accessor :alive
    def initialize(context)
      @context, @pid, @stops, @alive = context, 12345, 0, true
    end
    def running? = @alive
    def output = "emulator output"
    def stop
      @stops += 1
      @alive = false
      @context.state = ""
    end
  end

  class Context
    attr_reader :root, :output, :commands, :leases, :callbacks, :child, :launch
    attr_accessor :state, :actual_avd, :actual_path, :boot, :focus, :fail_signature, :dead_on_launch, :signatures, :processes, :free_kib
    def initialize(root)
      @root, @output = root, File.join(root, "evidence")
      FileUtils.mkdir_p(output)
      @commands, @leases, @callbacks = [], [], []
      @state, @actual_avd, @boot, @processes = "", "test-avd", "1", ""
      @signatures = Hash.new("owner signature")
      @actual_path = File.join(root, "avds/test-avd.avd")
      @free_kib = 18000000
      @focus = "mCurrentFocus=Window{home u0 launcher}"
    end
    def lease(name, identity:)
      @leases << [name, identity]
    end
    def cleanup(&callback) = @callbacks << callback
    def start(argv, **options)
      @launch = [argv, options]
      @child = Child.new(self)
      @child.alive = false if dead_on_launch
      @state = "device" unless dead_on_launch
      @child
    end
    def command(argv, **options)
      @commands << [argv, options]
      if File.basename(argv.first) == "adb"
        raise "Missing exact device" unless argv[1, 2] == ["-s", "emulator-5554"]
        case argv[3..]
        when ["get-state"] then state
        when %w[emu avd name] then "#{actual_avd}\nOK\n"
        when %w[emu avd path] then "#{actual_path}\nOK\n"
        when ["shell", "getprop sys.boot_completed"] then boot
        when ["shell", "getprop init.svc.bootanim"] then "stopped"
        when ["shell", "pm path android"] then "package:/system/framework/framework-res.apk"
        when ["shell", "dumpsys window displays"] then focus
        else ""
        end
      elsif argv.first == "ps"
        raise Dieter::PipelineError, "signature read failed" if fail_signature && argv.include?("-p")
        argv.include?("-p") ? signatures[argv[2].to_i] : processes
      elsif argv.first == "df"
        "Filesystem 1024-blocks Used Available Capacity Mounted\nvolume 20000000 1000 #{free_kib} 1% /\n"
      elsif argv.first == "/bin/cp"
        FileUtils.cp_r(argv[2], argv[3])
        ""
      elsif argv.first == "/bin/kill"
        child.stop
        Dir.glob(File.join(root, "tmp/e2e-cache/*.json")).each { |file| File.unlink(file) }
        ""
      else
        raise "Unexpected command #{argv.inspect}"
      end
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir("emulator-spec-"))
    @old_registry, ENV["ANDROID_AVD_HOME"] = ENV["ANDROID_AVD_HOME"], File.join(@root, "avds")
    FileUtils.mkdir_p(File.join(ENV.fetch("ANDROID_AVD_HOME"), "test-avd.avd"))
    File.write(File.join(ENV.fetch("ANDROID_AVD_HOME"), "test-avd.ini"), "path=#{ENV.fetch('ANDROID_AVD_HOME')}/test-avd.avd\n")
    File.write(File.join(ENV.fetch("ANDROID_AVD_HOME"), "test-avd.avd/config.ini"), "test\n")
    @context = Context.new(@root)
    @target = {"serial" => "emulator-5554", "avd" => "test-avd", "lifecycle" => "manage-if-started", "visible" => false, "renderer" => "software", "boot_timeout" => 10}
  end

  def teardown
    ENV["ANDROID_AVD_HOME"] = @old_registry
    FileUtils.remove_entry_secure(@root)
  end

  def emulator(target = @target)
    Dieter::AndroidEmulator.new(@context, "/sdk", target)
  end

  def test_owned_headless_boot_and_shutdown_reuse_userdata_without_snapshots
    runner = emulator.start
    argv = @context.launch.first
    assert_includes argv, "-no-window"
    assert_includes argv, "-no-snapshot"
    assert_includes argv, "software"
    refute_includes argv, "-wipe-data"
    assert_equal "android-avd", @context.leases.first.first
    runner.close
    assert_equal 1, @context.child.stops
    assert_empty Dir.glob(File.join(@root, "tmp/e2e-cache/*.json"))
    runner.close
    assert_equal 1, @context.child.stops
  end

  def test_visible_host_profile_uses_same_lifecycle
    emulator(@target.merge("visible" => true, "renderer" => "host")).start.close
    refute_includes @context.launch.first, "-no-window"
    assert_includes @context.launch.first, "host"
  end

  def test_invalid_serial_and_unsafe_avd_are_rejected_before_commands
    [nil, "emulator-5555", "emulator-5700", "phone"].each do |serial|
      assert_raises(Dieter::PipelineError) { emulator(@target.merge("serial" => serial)) }
    end
    assert_raises(Dieter::PipelineError) { emulator(@target.merge("avd" => "../operator")) }
    assert_empty @context.commands
  end

  def test_borrowed_emulator_needs_no_legacy_log_and_remains_running
    @context.state = "device"
    emulator.start.close
    assert_nil @context.launch
    assert_empty @context.callbacks
    assert_equal "device", @context.state
  end

  def test_wrong_avd_and_offline_devices_are_preserved
    @context.state, @context.actual_avd = "device", "operator-avd"
    assert_raises(Dieter::Unavailable) { emulator.start }
    @context.state = "offline"
    assert_raises(Dieter::Unavailable) { emulator.start }
    assert_nil @context.launch
  end

  def test_borrow_profile_does_not_launch_missing_emulator
    assert_raises(Dieter::Unavailable) { emulator(@target.merge("lifecycle" => "borrow")).start }
    assert_nil @context.launch
  end

  def test_boot_timeout_still_registers_and_cleans_owned_child
    @context.boot = "0"
    runner = emulator
    runner.define_singleton_method(:clock) { @tick = (@tick || 0) + 20 }
    assert_raises(Dieter::Unavailable) { runner.start }
    @context.callbacks.each(&:call)
    assert_equal 1, @context.child.stops
  end

  def test_failure_immediately_after_launch_still_cleans_child
    @context.fail_signature = true
    assert_raises(Dieter::PipelineError) { emulator.start }
    @context.callbacks.each(&:call)
    assert_equal 1, @context.child.stops
  end

  def test_early_exit_fails_admission_without_leaking_journal
    @context.dead_on_launch = true
    assert_raises(Dieter::Unavailable) { emulator.start }
    @context.callbacks.each(&:call)
    assert_empty Dir.glob(File.join(@root, "tmp/e2e-cache/*.json"))
  end

  def test_live_managed_owner_can_be_borrowed_but_orphan_cannot
    owner = emulator.start
    # exec replaces the launcher command with QEMU, without changing PID/birth.
    journal = Dir.glob(File.join(@root, "tmp/e2e-cache/*.json")).fetch(0)
    data = JSON.parse(File.read(journal))
    data["signature"] = "Sun Oct 4 12:00:00 2026 /sdk/emulator @test-avd"
    File.write(journal, JSON.generate(data))
    @context.signatures[12345] = "Sun Oct 4 12:00:00 2026 /sdk/qemu-system-aarch64 @test-avd"
    borrower = emulator.start
    borrower.close
    assert_equal 0, @context.child.stops
    @context.signatures[data.fetch("controller_pid")] = ""
    assert_raises(Dieter::Unavailable) { emulator.start }
    assert File.file?(journal)
    owner.close
  end

  def test_dead_journal_is_removed_only_when_serial_and_pid_are_absent
    runner = emulator.start
    @context.child.alive = false
    @context.state = ""
    @context.signatures[12345] = ""
    emulator.start.close
    assert_empty Dir.glob(File.join(@root, "tmp/e2e-cache/*.json"))
    # The old object must not be used again; recovery never signals its PID.
    assert_equal 1, @context.child.stops
  end

  def test_missing_avd_without_image_and_duplicate_avd_process_refuse_launch
    File.unlink(File.join(ENV.fetch("ANDROID_AVD_HOME"), "test-avd.ini"))
    assert_raises(Dieter::Unavailable) { emulator.start }
    @context.processes = "987 /sdk/emulator/qemu-system-aarch64 @test-avd -port 5556\n"
    assert_raises(Dieter::Unavailable) { emulator.start }
    assert_nil @context.launch
  end

  def test_unexpected_exit_after_admission_fails_cleanup
    runner = emulator.start
    @context.child.alive = false
    @context.state = ""
    assert_raises(Dieter::CleanupError) { runner.close }
    assert_empty Dir.glob(File.join(@root, "tmp/e2e-cache/*.json"))
  end

  def test_stop_requests_cleanup_only_from_verified_warm_owner
    emulator.start(warm: true)
    emulator.stop
    assert_equal 1, @context.child.stops
    assert @context.commands.any? { |argv, _| argv == ["/bin/kill", "-TERM", Process.pid.to_s] }
    assert_empty Dir.glob(File.join(@root, "tmp/e2e-cache/*.json"))
  end

  def test_stop_refuses_borrowed_nonwarm_and_changed_controller
    assert_raises(Dieter::Unavailable) { emulator.stop }
    owner = emulator.start
    assert_raises(Dieter::Unavailable) { emulator.stop }
    owner.close
    owner = emulator.start(warm: true)
    @context.signatures[Process.pid] = "different controller"
    assert_raises(Dieter::Unavailable) { emulator.stop }
    refute @context.commands.any? { |argv, _| argv.first == "/bin/kill" }
    owner.close
  end

  def test_avd_lease_is_shared_between_checkouts
    first = Dieter::Lease.new("android-avd", root: @root, identity: "spec-#{@root}")
    assert_raises(Dieter::Unavailable) { Dieter::Lease.new("android-avd", root: Dir.tmpdir, identity: "spec-#{@root}") }
  ensure
    first&.close
  end

  def test_project_runtime_is_copied_once_and_launch_environment_is_scoped
    sdk = File.join(@root, "host-sdk")
    %w[cmdline-tools/latest platform-tools emulator system-images/android-35/default/arm64-v8a].each do |package|
      FileUtils.mkdir_p(File.join(sdk, package))
      File.write(File.join(sdk, package, "package.xml"), "installed")
    end
    target = @target.merge("storage_dir" => ".android", "system_image" => "system-images;android-35;default;arm64-v8a")
    runner = Dieter::AndroidEmulator.new(@context, sdk, target)
    runner.setup
    runner.setup
    assert_equal 4, @context.commands.count { |argv, _| argv.first == "/bin/cp" }
    image = File.join(@root, ".android/sdk/system-images/android-35/default/arm64-v8a/package.xml")
    assert File.file?(image)
    refute File.symlink?(File.dirname(image))
    registry = File.join(@root, ".android/avd")
    @context.actual_path = File.join(registry, "test-avd.avd")
    FileUtils.mkdir_p(@context.actual_path)
    File.write(File.join(registry, "test-avd.ini"), "path = #{@context.actual_path}\n")
    File.write(File.join(@context.actual_path, "config.ini"), "disk.dataPartition.size = 6442450944\n")
    runner.start.close
    argv, options = @context.launch
    assert_equal File.join(@root, ".android/sdk/emulator/emulator"), argv.first
    assert_equal registry, options[:environment].fetch("ANDROID_AVD_HOME")
    assert_equal File.join(@root, ".android/sdk"), options[:environment].fetch("ANDROID_HOME")
    assert_equal File.join(@root, ".android/user"), options[:environment].fetch("ANDROID_USER_HOME")
    assert_equal File.join(@root, "avds"), ENV.fetch("ANDROID_AVD_HOME")
  end

  def test_same_name_in_another_project_is_not_borrowed_or_stopped
    @context.state = "device"
    @context.actual_path = @root
    assert_raises(Dieter::Unavailable) { emulator.start }
    assert_nil @context.launch
    refute @context.commands.any? { |argv, _| argv.first == "/bin/kill" }
  end

  def test_project_storage_cannot_escape_and_setup_requires_managed_storage
    %w[../android /android .git .android/../outside].each do |storage|
      assert_raises(Dieter::PipelineError) { emulator(@target.merge("storage_dir" => storage)) }
    end
    File.symlink(Dir.tmpdir, File.join(@root, ".android"))
    assert_raises(Dieter::PipelineError) { emulator(@target.merge("storage_dir" => ".android")) }
    assert_raises(Dieter::PipelineError) { emulator.setup }
    assert_raises(Dieter::PipelineError) { emulator(@target.merge("storage_dir" => ".android-borrow", "lifecycle" => "borrow")).setup }
  end

  def test_disk_check_parses_emulator_rewritten_ini_and_preserves_userdata
    data = File.join(ENV.fetch("ANDROID_AVD_HOME"), "test-avd.avd")
    File.write(File.join(data, "config.ini"), "disk.dataPartition.size = 6442450944\n")
    @context.free_kib = 9 * 1024**2
    emulator.start.close
    @context.free_kib = 7 * 1024**2
    assert_raises(Dieter::Unavailable) { emulator.start }
    File.write(File.join(data, "userdata-qemu.img"), "operator-data")
    @context.free_kib = 5 * 1024**2
    emulator.start.close
    assert_equal "operator-data", File.read(File.join(data, "userdata-qemu.img"))
  end

  def test_system_error_dialog_fails_admission_and_preserves_borrowed_owner
    @context.focus = "mCurrentFocus=Window{error u0 Application Not Responding: com.android.systemui}"
    assert_raises(Dieter::Unavailable) { emulator.start }
    @context.callbacks.each(&:call)
    assert_equal 1, @context.child.stops
    @context.state = "device"
    assert_raises(Dieter::Unavailable) { emulator.start }
    assert_equal "device", @context.state
    assert_equal 1, @context.child.stops
  end
end
