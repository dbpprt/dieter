# frozen_string_literal: true

# Local affected-check planning. CI selects jobs from the same
# .github/filters.yml with dorny/paths-filter; this matches those globs
# against `git diff` and runs the plain commands of each selected component.
#
#   ruby fastlane/helpers/changes.rb [--base REF] [--dry-run] [--native]
require "optparse"
require "yaml"

module Dieter
  module Changes
    ROOT = File.expand_path("../..", __dir__)
    FILTERS = File.join(ROOT, ".github/filters.yml")
    # Fast checks per component; native device/desktop checks run with --native.
    CHECKS = {
      "go" => ["just lint-go", "just test"],
      "go-e2e" => ["just test-e2e"],
      "harness-runtime" => ["npm --prefix internal/harness/runtime test"],
      "kotlin" => ["just kotlin test"],
      "apple" => ["just pipeline mac test_unit"],
      "ios" => ["just pipeline ios build"],
      "android" => ["just pipeline android test_unit"],
      "site" => ["just site-check"],
      "deploy-gateway" => ["python3 -m unittest discover -s deploy/gateway/tests"],
      "workflows" => ["just lint-workflows"],
      "maestro" => ["just pipeline maestro_lint"],
      "fastlane" => ["just pipeline-test"]
    }.freeze
    NATIVE = {
      "apple" => ["just pipeline mac e2e"],
      "ios" => ["just pipeline ios e2e"],
      "android" => ["just pipeline android e2e"],
      "deploy-gateway" => ["python3 deploy/gateway/tests/integration.py"]
    }.freeze

    module_function

    def filters(file = FILTERS) =
      YAML
        .safe_load(File.read(file), aliases: true)
        .transform_values { |globs| Array(globs).flatten }

    # picomatch semantics for the patterns we use: `dir/**` covers everything
    # below dir, `**/` crosses directories, dotfiles match.
    def match?(pattern, path)
      pattern = "#{pattern}/*" if pattern.end_with?("/**")
      File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB)
    end

    # Component => matching paths, in filter order.
    def select(paths, filters = self.filters)
      filters.each_with_object({}) do |(name, globs), selected|
        hits = paths.select { |path| globs.any? { |glob| match?(glob, path) } }
        selected[name] = hits unless hits.empty?
      end
    end

    # Tracked changes against HEAD (or the merge base with base) plus untracked files.
    def changed_paths(base = nil)
      ref = base ? git("merge-base", base, "HEAD").strip : "HEAD"
      (
        git("diff", "--name-only", "--no-renames", "-z", ref, "--").split("\0") +
          git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
      ).uniq.sort
    end

    def git(*args)
      out = IO.popen(["git", "-C", ROOT, *args], &:read)
      raise "git #{args.first} failed" unless $?.success?
      out
    end

    def main(argv)
      options = {}
      OptionParser
        .new do |flags|
          flags.banner = "just check-changed [--base REF] [--dry-run] [--native]"
          flags.on("--base REF", "Include branch changes since the merge base with REF") do |value|
            options[:base] = value
          end
          flags.on("--dry-run", "Print the selection without running checks") do
            options[:dry_run] = true
          end
          flags.on("--native", "Also run related device/desktop checks") { options[:native] = true }
        end
        .parse!(argv)
      paths = changed_paths(options[:base])
      selected = select(paths)
      puts "#{paths.length} changed paths"
      selected.each do |name, hits|
        commands = CHECKS.fetch(name, []) + (options[:native] ? NATIVE.fetch(name, []) : [])
        puts "#{name}: #{hits.first(3).join(", ")}#{hits.length > 3 ? ", … (#{hits.length})" : ""}"
        commands.each { |command| puts "  $ #{command}" }
        (NATIVE.fetch(name, []) - commands).each do |command|
          puts "  (native, --native) $ #{command}"
        end
      end
      puts "No component selected" if selected.empty?
      return 0 if options[:dry_run]
      selected
        .keys
        .flat_map do |name|
          CHECKS.fetch(name, []) + (options[:native] ? NATIVE.fetch(name, []) : [])
        end
        .uniq
        .each do |command|
          puts "==> #{command}"
          return 1 unless system(command, chdir: ROOT)
        end
      0
    end
  end
end

exit Dieter::Changes.main(ARGV) if $PROGRAM_NAME == __FILE__
