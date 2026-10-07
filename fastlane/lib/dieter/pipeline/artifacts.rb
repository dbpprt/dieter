# frozen_string_literal: true

require "digest"
require "find"
require "pathname"
require_relative "../errors"
require_relative "../atomic"

module Dieter
  class ArtifactSet
    attr_reader :manifest

    def self.sha256(path)
      return Digest::SHA256.file(path).hexdigest if File.file?(path) && !File.symlink?(path)
      unless File.directory?(path) && !File.symlink?(path)
        raise PipelineError, "Missing artifact #{path}"
      end
      digest = Digest::SHA256.new
      Find
        .find(path)
        .sort
        .each do |entry|
          relative = entry == path ? "." : entry.delete_prefix(path + "/")
          stat = File.lstat(entry)
          digest.update(relative + "\0" + (stat.mode & 0o777).to_s + "\0")
          if stat.symlink?
            target = File.readlink(entry)
            resolved = File.expand_path(target, File.dirname(entry))
            unless resolved.start_with?(path + "/")
              raise PipelineError, "Artifact link escapes product: #{relative}"
            end
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
        "schema_version" => 1,
        "component" => component,
        "source_revision" => source,
        "configuration" => configuration,
        "release_identity" => identity,
        "toolchain" => toolchain,
        "products" =>
          products.map do |kind, path|
            {
              "kind" => kind,
              "path" => File.expand_path(path),
              "sha256" => self.class.sha256(File.expand_path(path))
            }
          end
      }
    end

    def write(path, portable: false)
      value = Marshal.load(Marshal.dump(manifest))
      if portable
        directory = File.expand_path(File.dirname(path))
        value
          .fetch("products")
          .each do |product|
            unless product.fetch("path").start_with?(directory + "/")
              raise PipelineError, "Portable artifact must be inside its manifest directory"
            end
            product["path"] = Pathname
              .new(product.fetch("path"))
              .relative_path_from(Pathname.new(directory))
              .to_s
          end
      end
      Atomic.json(path, value)
    end

    def self.load(path, source: nil, component: nil)
      raise PipelineError, "Artifact manifest exceeds 1 MiB" if File.size(path) > 1024 * 1024
      value = JSON.parse(File.read(path))
      unless value["schema_version"] == 1 && value["products"].is_a?(Array) &&
               !value["products"].empty?
        raise PipelineError, "Unsupported artifact manifest"
      end
      if source && value["source_revision"] != source
        raise PipelineError, "Artifact source mismatch"
      end
      if component && value["component"] != component
        raise PipelineError, "Artifact component mismatch"
      end
      value["products"].each do |product|
        unless Pathname.new(product.fetch("path")).absolute?
          directory = File.expand_path(File.dirname(path))
          resolved = File.expand_path(product.fetch("path"), directory)
          unless resolved.start_with?(directory + "/")
            raise PipelineError, "Portable artifact escapes manifest directory"
          end
          product["path"] = resolved
        end
        unless sha256(product.fetch("path")) == product.fetch("sha256")
          raise PipelineError, "Artifact hash mismatch: #{product["kind"]}"
        end
      end
      object = allocate
      object.instance_variable_set(:@manifest, value)
      object
    end
  end
end
