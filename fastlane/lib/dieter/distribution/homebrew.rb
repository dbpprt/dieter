# frozen_string_literal: true

require "base64"

module Dieter
  class HomebrewDestination
    REPOSITORY = "dbpprt/homebrew-tap"

    def initialize(context, identity, sums)
      @context, @identity, @sums = context, identity, sums
      @token = ENV.fetch("HOMEBREW_TAP_TOKEN")
      raise Unavailable, "Stable Homebrew publishing needs HOMEBREW_TAP_TOKEN" if @token.empty?
      context.secrets << @token
    end

    def api(path, method: "GET", body: nil)
      argv = ["gh", "api", "repos/#{REPOSITORY}/#{path}", "--method", method]
      argv += ["--input", "-"] if body
      value = @context.command(argv, environment: {"GH_TOKEN" => @token}, input: body && JSON.generate(body), timeout: 120, binary: true)
      value.empty? ? nil : JSON.parse(value, object_class: UniqueObject, allow_duplicate_key: false)
    end

    def publish
      ref = api("git/ref/heads/main")
      head = ref.fetch("object").fetch("sha")
      commit = api("git/commits/#{head}")
      formula = @context.command(["python3", "-c", "import sys; from fastlane.lib.dieter.native.homebrew_formula import render; print(render(sys.argv[1],sys.argv[2]).replace('dbpprt/homebrew-tap/releases/download','dbpprt/dieter/releases/download'),end='')", @identity.version, @sums.fetch("dieter-darwin-arm64.tar.gz")], timeout: 30, binary: true)
      old_cask = api("contents/Casks/dieter-app.rb?ref=#{head}")
      cask = Base64.decode64(old_cask.fetch("content"))
      raise PipelineError, "Unexpected Dieter cask template" unless cask.scan(/^  version "/).length == 1 && cask.scan(/^  sha256 "/).length == 1 && cask.include?("Dieter-macOS-arm64.zip")
      cask = cask.sub(/^  version "[^"\n]+"/, "  version \"#{@identity.version}\"").sub(/^  sha256 "[^"\n]+"/, "  sha256 \"#{@sums.fetch('Dieter-macOS-arm64.zip')}\"").gsub("dbpprt/homebrew-tap/releases/download", "dbpprt/dieter/releases/download")
      files = {"Formula/dieter.rb" => formula, "Casks/dieter-app.rb" => cask}
      unchanged = files.all? { |path, text| Base64.decode64(api("contents/#{path}?ref=#{head}").fetch("content")) == text }
      return {"state" => "completed", "commit" => head, "tag" => @identity.tag} if unchanged
      entries = files.map do |path, content|
        blob = api("git/blobs", method: "POST", body: {content: Base64.strict_encode64(content), encoding: "base64"})
        {path: path, mode: "100644", type: "blob", sha: blob.fetch("sha")}
      end
      tree = api("git/trees", method: "POST", body: {base_tree: commit.fetch("tree").fetch("sha"), tree: entries})
      updated = api("git/commits", method: "POST", body: {message: "Update Dieter to #{@identity.tag}", tree: tree.fetch("sha"), parents: [head]})
      # A concurrent tap change fails without replacing it; resume regenerates
      # against the new tree and retains both unrelated files and history.
      api("git/refs/heads/main", method: "PATCH", body: {sha: updated.fetch("sha"), force: false})
      {"state" => "completed", "commit" => updated.fetch("sha"), "tag" => @identity.tag}
    end
  end
end
