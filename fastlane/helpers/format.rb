# frozen_string_literal: true

# Formats or checks authored sources with the pinned formatters from mise.toml.
#
#   ruby fastlane/helpers/format.rb [--write] [--staged | --base REF | --all] [--only LANGS]
#
# Default selection: working-tree changes against HEAD plus untracked files.
# --staged checks the index content, exported to a temporary tree, without
# stashing or touching working files. --base REF adds branch changes since the
# merge base (CI). Formatting is enforced on touched files; --all checks the
# full inventory. --only narrows the selection to some formatters' files, for a
# runner that installs only those (the Mac job checks Swift).
require "fileutils"
require "open3"
require "optparse"
require "tmpdir"

module Dieter
  module Format
    ROOT = File.expand_path("../..", __dir__)
    EXCLUDED =
      %r{\A(?:third_party/|internal/gen/|tmp/|\.mise/|apps/apple/DieterKit/Sources/DieterAPI(?:GRPC)?/|
                    apps/apple/mac/Sources/DieterMacKit/Resources/MarkdownPreview/|apps/kotlin/android/webrtc/src/|
                    site/layouts/)|/testdata/|(?:\A|/)(?:package-lock\.json|gradlew(?:\.bat)?|mise\.lock)\z}x
    CONFIGS = %w[.editorconfig .prettierrc.json ruff.toml .streerc apps/apple/.swift-format].freeze
    LANGUAGES = {
      "go" => %w[.go],
      "kotlin" => %w[.kt .kts],
      "swift" => %w[.swift],
      "python" => %w[.py],
      "ruby" => %w[.rb],
      "shell" => %w[.sh],
      "prettier" => %w[.js .mjs .css .json .yaml .yml .md .html .webmanifest]
    }.freeze
    MAX_BYTES = 5 * 1024 * 1024

    module_function

    def language(path)
      return nil if path.match?(EXCLUDED)
      return "ruby" if %w[Gemfile Fastfile].include?(File.basename(path))
      return "shell" if path == ".githooks/pre-commit"
      LANGUAGES.find { |_name, extensions| extensions.include?(File.extname(path)) }&.first
    end

    def git(*args) = Open3.capture2("git", "-C", ROOT, *args).first

    def selection(mode, base)
      names = ->(*args) { git(*args).split("\0") }
      case mode
      when :staged
        names.call("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
      when :all
        names.call("ls-files", "-z")
      else
        # The merge base when history allows it; a shallow CI clone compares with base directly.
        ref =
          (
            if base
              (git("merge-base", base, "HEAD").strip.then { |sha| sha.empty? ? base : sha })
            else
              "HEAD"
            end
          )
        names.call("diff", "--name-only", "--diff-filter=ACMR", "-z", ref) +
          names.call("ls-files", "--others", "--exclude-standard", "-z")
      end.uniq.sort.select { |path| File.file?(File.join(ROOT, path)) || mode == :staged }
    end

    def generated?(file) = File.foreach(file).first(3).any? { |line| line.include?("DO NOT EDIT") }

    def commands(name, files, write, tree)
      case name
      when "go"
        [["gofmt", write ? "-w" : "-l", *files]]
      when "kotlin"
        jar = Dir.glob(File.join(`mise where http:ktfmt 2>/dev/null`.strip, "*.jar")).first or
          abort("ktfmt is missing: mise install")
        [
          [
            "java",
            "-Xmx1g",
            "-jar",
            jar,
            "--kotlinlang-style",
            "--enable-editorconfig",
            *(write ? [] : %w[--dry-run --set-exit-if-changed]),
            *files
          ]
        ]
      when "swift"
        return [] unless RUBY_PLATFORM.include?("darwin")
        [
          [
            "xcrun",
            "swift-format",
            *(write ? %w[format --in-place] : %w[lint --strict]),
            "--configuration",
            File.join(tree, "apps/apple/.swift-format"),
            *files
          ]
        ]
      when "prettier"
        [
          [
            "prettier",
            write ? "--write" : "--check",
            "--config",
            File.join(tree, ".prettierrc.json"),
            "--ignore-path",
            File::NULL,
            *files
          ]
        ]
      when "python"
        [
          [
            "ruff",
            "format",
            "--config",
            File.join(tree, "ruff.toml"),
            *(write ? [] : ["--check"]),
            *files
          ]
        ]
      when "ruby"
        [["stree", write ? "write" : "check", "--config=#{File.join(tree, ".streerc")}", *files]]
      when "shell"
        [["shfmt", write ? "-w" : "-d", "-i", "4", "-ci", *files]]
      end
    end

    # Conflict markers, trailing whitespace (Markdown hard breaks excepted),
    # missing final newlines and oversized new files.
    def integrity(tree, paths)
      paths.filter_map do |path|
        file = File.join(tree, path)
        next "#{path}: exceeds 5 MiB; keep build output out of Git" if File.size(file) > MAX_BYTES
        # An empty file reads as nil; it has nothing to check.
        next if path.match?(EXCLUDED) || File.binread(file, 8000).to_s.include?("\0")
        text = File.binread(file)
        next "#{path}: merge conflict marker" if text.match?(/^(?:<{7}|>{7}) /)
        next "#{path}: missing final newline" unless text.empty? || text.end_with?("\n")
        line =
          text.lines.index do |entry|
            (trail = entry.chomp[/[ \t]+\z/]) && !(path.end_with?(".md") && trail == "  ")
          end
        "#{path}:#{line + 1}: trailing whitespace" if line
      end
    end

    def main(argv)
      mode, base, write, only = :changed, nil, false, nil
      OptionParser
        .new do |flags|
          flags.banner =
            "ruby fastlane/helpers/format.rb [--write] [--staged | --base REF | --all] [--only LANGS]"
          flags.on("--write", "Rewrite working files instead of checking") { write = true }
          flags.on("--staged", "Check the staged index content") { mode = :staged }
          flags.on("--base REF", "Include changes since the merge base with REF") do |value|
            base = value
          end
          flags.on("--all", "Every tracked file") { mode = :all }
          flags.on("--only LANGS", Array, "Only files of #{LANGUAGES.keys.join(", ")}") do |value|
            only = value
          end
        end
        .parse!(argv)
      unknown = Array(only) - LANGUAGES.keys
      abort "unknown --only language: #{unknown.join(", ")}" unless unknown.empty?
      if write && mode == :staged
        abort "--write cannot format the index; format working files, then stage them"
      end
      paths = selection(mode, base)
      paths = paths.select { |path| only.include?(language(path)) } if only
      tree = ROOT
      if mode == :staged
        tree = Dir.mktmpdir("dieter-staged-")
        configs = CONFIGS.select { |path| !git("ls-files", "--", path).empty? }
        unless (paths + configs).empty?
          git("checkout-index", "--prefix=#{tree}/", "--", *(paths + configs).uniq)
        end
      end
      problems = write ? [] : integrity(tree, paths)
      paths
        .group_by { |path| language(path) }
        .each do |name, group|
          next unless name
          group = group.reject { |path| generated?(File.join(tree, path)) }
          next if group.empty?
          commands(name, group, write, tree).each do |command|
            output, status = Open3.capture2e(*command, chdir: tree)
            failed = !status.success? || (name == "go" && !write && !output.strip.empty?)
            if failed && !write
              problems << "#{name} formatting (run `just fmt`):\n#{output.strip[0, 8000]}"
            end
            abort "#{name} formatter failed:\n#{output}" if failed && write
          end
        end
      puts "#{paths.length} files #{write ? "formatted" : "checked"}"
      return 0 if problems.empty?
      warn problems.join("\n")
      1
    ensure
      FileUtils.rm_rf(tree) if mode == :staged && tree && tree != ROOT
    end
  end
end

exit Dieter::Format.main(ARGV) if $PROGRAM_NAME == __FILE__
