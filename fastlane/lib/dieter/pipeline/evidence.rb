# frozen_string_literal: true

require "find"
require "cgi"
require_relative "../atomic"
require_relative "../errors"

module Dieter
  # Product bytes belong to producer checkpoints, never diagnostic uploads.
  class Evidence
    MAX_BYTES = 64 * 1024 * 1024
    LIMITS = {".json" => 1024 * 1024, ".xml" => 1024 * 1024, ".log" => 4 * 1024 * 1024,
              ".png" => 8 * 1024 * 1024, ".jpg" => 8 * 1024 * 1024, ".mp4" => 16 * 1024 * 1024}.freeze
    PRIVATE_DIRS = %w[producer Products DerivedData Build .private].freeze

    def self.collect(root, output:, sources: %w[tmp/app-pipelines tmp/candidate])
      target = File.expand_path(output, root)
      raise PipelineError, "Evidence destination must be a fresh directory inside tmp" unless target.start_with?(File.join(root, "tmp") + "/") && !File.exist?(target)
      reject_link_ancestors(root, target)
      FileUtils.mkdir_p(target, mode: 0o700)
      included, omitted, bytes = [], [], 0
      candidates = []
      sources.each do |source|
        base = File.expand_path(source, root)
        raise PipelineError, "Evidence source must be inside tmp" unless base.start_with?(File.join(root, "tmp") + "/")
        reject_link_ancestors(root, base)
        next unless File.directory?(base)
        Find.find(base) do |path|
          stat = File.lstat(path)
          if stat.symlink?
            omitted << {path: path.delete_prefix(root + "/"), reason: "symlink"}
            next
          end
          if stat.directory?
            Find.prune if path == target || PRIVATE_DIRS.include?(File.basename(path)) || path.end_with?(".xcarchive", ".xcresult", ".app", ".framework", ".xcframework")
            next
          end
          relative = path.delete_prefix(root + "/")
          limit = LIMITS[File.extname(path)]
          reason = if !stat.file? || !limit then "not diagnostic evidence"
                   elsif stat.size > limit then "file exceeds #{limit} bytes"
                   end
          if reason
            omitted << {path: relative, bytes: stat.size, reason: reason}
            next
          end
          candidates << [path, relative, stat.size]
        end
      end
      # Keep qualification and timing reports even when bulk failure media fills
      # the remaining budget. Stable ordering makes omissions reproducible.
      candidates.uniq.sort_by { |path, relative, _| [%w[.json .xml].include?(File.extname(path)) ? 0 : 1, relative] }.each do |path, relative, size|
        if bytes + size > MAX_BYTES
          omitted << {path: relative, bytes: size, reason: "upload exceeds #{MAX_BYTES} bytes"}
          next
        end
        destination = File.join(target, relative)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        FileUtils.cp(path, destination)
        bytes += size
        included << {path: relative, bytes: size}
      end
      manifest = {version: 1, bytes: bytes, maxBytes: MAX_BYTES, files: included, omitted: omitted}
      Atomic.json(File.join(target, "evidence.json"), manifest)
      summary(root, manifest)
      puts "Evidence: #{included.length} files, #{(bytes / 1024.0 / 1024).round(1)} MiB; #{omitted.length} omitted; #{output}"
      manifest
    end

    def self.reject_link_ancestors(root, path)
      current = path
      while current != root
        raise PipelineError, "Evidence path contains a symlink" if File.symlink?(current)
        current = File.dirname(current)
      end
    end

    def self.summary(root, manifest)
      return unless ENV["GITHUB_STEP_SUMMARY"]
      rows, preparation, operations = [], [], []
      escape = ->(value) { CGI.escapeHTML(value.to_s).gsub("|", "&#124;").gsub(/[\r\n]/, " ") }
      manifest.fetch(:files).select { |entry| File.basename(entry[:path]) == "timings.json" }.each do |entry|
        report = JSON.parse(File.read(File.join(root, entry.fetch(:path))))
        report.fetch("operations", []).each do |operation|
          operations << operation.merge("context" => File.dirname(entry.fetch(:path)))
        end
      end
      manifest.fetch(:files).select { |entry| entry[:path].start_with?("tmp/app-pipelines/") && File.basename(entry[:path]) == "results.json" }.each do |entry|
        path = File.join(root, entry.fetch(:path))
        report = JSON.parse(File.read(path))
        preparation << "Build/preparation (#{CGI.escapeHTML(report.fetch('serial', 'unknown').to_s)}): #{(report.fetch('buildMs', 0) / 1000.0).round(1)}s."
        report.fetch("results", []).each do |result|
          rows << "| #{escape.call(result['id'])} | #{escape.call(report['serial'])} | #{escape.call(result['status'])} | #{(result.fetch('setupMs', 0) / 1000.0).round(1)} | #{(result.fetch('executionMs', 0) / 1000.0).round(1)} | #{(result.fetch('durationMs', 0) / 1000.0).round(1)} |"
        end
      end
      File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |file|
        file.puts "\n### Pipeline evidence\n\n#{manifest[:files].length} files; #{(manifest[:bytes] / 1024.0 / 1024).round(1)} MiB. #{manifest[:omitted].length} omissions are recorded in `evidence.json`.\n"
        slowest = operations.sort_by { |operation| -operation.fetch("durationMs", 0) }.first(10)
        unless slowest.empty?
          file.puts "\nSlowest operations (including shared builds; full timings are retained):\n"
          file.puts "\n| Operation | Context | Status | Time (s) |\n| --- | --- | --- | ---: |"
          slowest.each do |operation|
            file.puts "| #{escape.call(operation['name'])} | #{escape.call(operation['context'])} | #{escape.call(operation['status'])} | #{(operation.fetch('durationMs', 0) / 1000.0).round(1)} |"
          end
        end
        unless rows.empty?
          file.puts "\n" + preparation.join("\n\n")
          file.puts "\n| Case | Target | Status | Setup (s) | Execution (s) | Total (s) |\n| --- | --- | --- | ---: | ---: | ---: |"
          file.puts rows
        end
      end
    end
  end
end
