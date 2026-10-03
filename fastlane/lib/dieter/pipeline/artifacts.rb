# frozen_string_literal: true

require "digest"
require "find"
require_relative "../errors"
require_relative "../atomic"

module Dieter
  class ArtifactSet
    attr_reader :manifest

    def self.sha256(path)
      return Digest::SHA256.file(path).hexdigest if File.file?(path) && !File.symlink?(path)
      raise PipelineError, "Missing artifact #{path}" unless File.directory?(path) && !File.symlink?(path)
      digest = Digest::SHA256.new
      Find.find(path).sort.each do |entry|
        relative = entry == path ? "." : entry.delete_prefix(path + "/")
        stat = File.lstat(entry)
        digest.update(relative + "\0" + (stat.mode & 0o777).to_s + "\0")
        if stat.symlink?
          target = File.readlink(entry)
          resolved = File.expand_path(target, File.dirname(entry))
          raise PipelineError, "Artifact link escapes product: #{relative}" unless resolved.start_with?(path + "/")
          digest.update("link\0" + target + "\0")
        elsif stat.file?
          File.open(entry, "rb") do |file|
            while (chunk = file.read(1024 * 1024))
              digest.update(chunk)
            end
          end
        elsif !stat.directory?
          raise PipelineError, "Unsupported artifact entry #{relative}"
        end
      end
      digest.hexdigest
    end

    def initialize(component:, source:, configuration:, products:, identity: nil, toolchain: {})
      @manifest = {
        "schema_version" => 1, "component" => component, "source_revision" => source,
        "configuration" => configuration, "release_identity" => identity,
        "toolchain" => toolchain,
        "products" => products.map do |kind, path|
          {"kind" => kind, "path" => File.expand_path(path), "sha256" => self.class.sha256(File.expand_path(path))}
        end
      }
    end

    def write(path)
      Atomic.json(path, manifest)
    end

    def self.load(path, source: nil, component: nil)
      raise PipelineError, "Artifact manifest exceeds 1 MiB" if File.size(path) > 1024 * 1024
      value = JSON.parse(File.read(path))
      raise PipelineError, "Unsupported artifact manifest" unless value["schema_version"] == 1 && value["products"].is_a?(Array) && !value["products"].empty?
      raise PipelineError, "Artifact source mismatch" if source && value["source_revision"] != source
      raise PipelineError, "Artifact component mismatch" if component && value["component"] != component
      value["products"].each do |product|
        raise PipelineError, "Artifact hash mismatch: #{product['kind']}" unless sha256(product.fetch("path")) == product.fetch("sha256")
      end
      object = allocate
      object.instance_variable_set(:@manifest, value)
      object
    end
  end
end
