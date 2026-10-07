# frozen_string_literal: true

require_relative "artifacts"

module Dieter
  # Downloadable development previews, independent of immutable release candidates.
  module PreviewArtifact
    def self.stage(context, manifest:, component:, product:, archive: false, metadata: {})
      source = context.command(%w[git rev-parse HEAD], timeout: 30).strip
      built = ArtifactSet.load(manifest, source: source, component: component).manifest
      unless built["configuration"] == "debug"
        raise PipelineError, "Previews require a Debug product"
      end
      matches = built.fetch("products").select { |entry| entry["kind"] == product }
      raise PipelineError, "Expected one preview product" unless matches.length == 1
      input = matches.first.fetch("path")
      directory = File.join(context.output, "preview")
      Dir.mkdir(directory, 0o700)
      filename = archive ? "#{component}-simulator.zip" : "#{component}.apk"
      destination = File.join(directory, filename)
      if archive
        # Only the app enters the archive; credentials, test runners and DerivedData stay private.
        context.command(["ditto", "-c", "-k", "--keepParent", input, destination], timeout: 300)
      else
        FileUtils.cp(input, destination)
      end
      ArtifactSet.new(
        component: component,
        source: source,
        configuration: "debug",
        toolchain:
          metadata.merge(
            "version" => context.environment.fetch("DIETER_RELEASE_VERSION"),
            "delivery" => "preview"
          ),
        products: {
          (archive ? "simulator-app" : "apk") => destination
        }
      ).write(File.join(directory, "manifest.json"), portable: true)
      directory
    end

    def self.verify(path, source:, component:, kind:)
      manifest = ArtifactSet.load(path, source: source, component: component).manifest
      unless manifest["configuration"] == "debug" && manifest["release_identity"].nil? &&
               manifest.dig("toolchain", "delivery") == "preview" &&
               manifest.fetch("products").map { |entry| entry.fetch("kind") } == [kind]
        raise PipelineError, "Invalid development preview"
      end
      manifest
    end
  end
end
