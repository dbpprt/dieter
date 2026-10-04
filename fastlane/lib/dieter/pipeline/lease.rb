# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../errors"

module Dieter
  class Lease
    attr_reader :path

    def self.path(resource, root: nil, identity: nil)
      case resource
      when "android-device", "android-avd", "android-runtime"
        File.join(Dir.tmpdir, "#{resource}-leases-#{Process.uid}", "#{Digest::SHA256.hexdigest(identity)}.lock")
      when "ios-device"
        File.join(Dir.tmpdir, "ios-device-leases-#{Process.uid}", "#{Digest::SHA256.hexdigest(identity)}.lock")
      when "mac-desktop"
        File.join(Dir.tmpdir, "dieter-mac-e2e-#{Process.uid}.lock")
      when "apple-signing"
        File.join(Dir.tmpdir, "dieter-apple-signing-#{Process.uid}.lock")
      when "ios-simulator"
        File.join(Dir.tmpdir, "dieter-ios-simulator-#{Process.uid}.lock")
      when "android-build"
        File.join(Dir.tmpdir, "dieter-e2e-build-#{Digest::SHA256.hexdigest(File.realpath(root))}.lock")
      else
        File.join(Dir.tmpdir, "dieter-#{resource}-#{Digest::SHA256.hexdigest(File.realpath(root))}.lock")
      end
    end

    def initialize(resource, **options)
      @path = self.class.path(resource, **options)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      @file = File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      unless @file.flock(File::LOCK_EX | File::LOCK_NB)
        owner = @file.read(512)
        @file.close
        raise Unavailable, "Resource #{resource} is busy; owner #{owner.to_s.strip}. Inspect the PID; preserve its lock."
      end
      @file.truncate(0)
      @file.write(JSON.generate({pid: Process.pid, resource: resource, owner: "dieter-pipeline"}))
      @file.flush
    end

    def close
      return if @file.closed?
      @file.flock(File::LOCK_UN)
      @file.close
    end
  end
end
