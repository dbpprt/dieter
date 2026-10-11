# frozen_string_literal: true

require "digest"
require "tmpdir"
require_relative "atomic"
require_relative "errors"

module Dieter
  # The pinned Maestro CLI. Local runs and CI install the same verified release
  # bytes into the ignored tmp/tools; Java comes from the pipeline toolchain.
  module Maestro
    VERSION = "cli-2.11.0"
    URL = "https://github.com/mobile-dev-inc/maestro/releases/download/#{VERSION}/maestro.zip"
    SHA256 = "5384593cb4e7a106489e75a821d157dd43f4e438df6bc308b72e82c685e1283a"
    ENVIRONMENT = {
      "MAESTRO_CLI_NO_ANALYTICS" => "1",
      "MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED" => "true",
      "MAESTRO_DISABLE_UPDATE_CHECK" => "true"
    }.freeze

    def self.executable(context)
      home = File.join(context.root, "tmp/tools/maestro", VERSION)
      binary = File.join(home, "maestro/bin/maestro")
      verified = -> { File.executable?(binary) && File.file?(File.join(home, ".verified")) }
      return binary if verified.call
      context.with_lease("maestro-install") do
        next if verified.call
        archive = File.join(context.private_dir, "maestro.zip")
        context.command(
          ["curl", "-fsSL", "--retry", "3", "--max-filesize", "400000000", "-o", archive, URL],
          timeout: 600,
          label: "Download Maestro #{VERSION}"
        )
        unless Digest::SHA256.file(archive).hexdigest == SHA256
          raise PipelineError, "Maestro #{VERSION} checksum mismatch"
        end
        FileUtils.mkdir_p(File.dirname(home), mode: 0o700)
        staging = Dir.mktmpdir(".maestro-", File.dirname(home))
        begin
          context.command(["unzip", "-q", archive, "-d", staging], timeout: 300)
          unless File.executable?(File.join(staging, "maestro/bin/maestro"))
            raise PipelineError, "Maestro archive has no CLI"
          end
          Atomic.write(File.join(staging, ".verified"), SHA256)
          FileUtils.rm_rf(home)
          File.rename(staging, home)
        ensure
          FileUtils.rm_rf(staging) if File.exist?(staging)
        end
      end
      binary
    end
  end
end
