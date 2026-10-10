# frozen_string_literal: true

require "securerandom"
require "digest"
require_relative "../config"

module Dieter
  # A file in the owned E2E application container, never in the Photos library.
  class IOSMediaFixture
    def initialize(
      context,
      target,
      app:,
      bundle_id:,
      journal:,
      simulator: nil,
      evidence: context.output
    )
      @context, @target, @app, @id, @journal, @simulator =
        context,
        target,
        app,
        bundle_id,
        journal,
        simulator
      @evidence = evidence
    end

    def stage
      unless @id.end_with?(".e2e")
        raise PipelineError, "Share media requires an isolated E2E bundle"
      end
      owner =
        JSON.parse(File.read(@journal), object_class: UniqueObject, allow_duplicate_key: false)
      physical = @target.fetch("kind") == "device"
      owned =
        (
          if physical
            owner["udid"] == @target.fetch("udid") && owner["owner_pid"] == Process.pid &&
              owner.fetch("packages").include?(@id)
          else
            owner["ID"] == @simulator && owner.fetch("Name").start_with?("Dieter Pipeline ")
          end
        )
      raise PipelineError, "Share media ownership changed; preserve the device" unless owned
      info =
        JSON.parse(
          @context.command(
            ["plutil", "-convert", "json", "-o", "-", File.join(@app, "Info.plist")],
            timeout: 30
          )
        )
      unless info["CFBundleIdentifier"] == @id && info["CFBundleDisplayName"] == "Dieter E2E" &&
               info["UIFileSharingEnabled"] == true &&
               info["LSSupportsOpeningDocumentsInPlace"] == true
        raise PipelineError, "Owned media requires the E2E Files declarations"
      end
      name = "dieter-media-#{SecureRandom.uuid}.png"
      image = File.join(@context.root, "assets/brand/assets/png/app-icon-light-1024.png")
      if physical
        device = @target.fetch("udid")
        @context.command(
          [
            "xcrun",
            "devicectl",
            "--timeout",
            "120",
            "device",
            "install",
            "app",
            "--device",
            device,
            @app
          ],
          timeout: 135
        )
        @context.command(
          [
            "xcrun",
            "devicectl",
            "--timeout",
            "60",
            "device",
            "copy",
            "to",
            "--device",
            device,
            "--source",
            image,
            "--destination",
            "Documents/#{name}",
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            @id
          ],
          timeout: 75
        )
      else
        @context.command(["xcrun", "simctl", "install", @simulator, @app], timeout: 120)
        container =
          @context.command(
            ["xcrun", "simctl", "get_app_container", @simulator, @id, "data"],
            timeout: 120
          ).strip
        expected =
          File.join(
            Dir.home,
            "Library/Developer/CoreSimulator/Devices",
            @simulator,
            "data/Containers/Data/Application"
          )
        unless File.realpath(container).start_with?(expected + "/")
          raise PipelineError, "Unexpected owned simulator data container"
        end
        documents = File.join(container, "Documents")
        FileUtils.mkdir_p(documents, mode: 0o700)
        FileUtils.cp(image, File.join(documents, name))
      end
      Atomic.json(
        File.join(@evidence, "owned-share-media.json"),
        {
          bundle_id: @id,
          filename: name,
          sha256: Digest::SHA256.file(image).hexdigest,
          location: "owned-app-documents"
        }
      )
      name
    end
  end
end
