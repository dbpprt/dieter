# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "openssl"
require "securerandom"

module Dieter
  class DeviceFixtureRoute
    attr_reader :url, :control_token

    def certificate_pem = File.binread(@certificate)

    def initialize(context, target, state)
      @context, @state = context, state
      @configuration = context.config.data.fetch("fixture_routes").fetch(target.fetch("fixture_route"))
      raise Unavailable, "Physical iOS fixture route is disabled" unless @configuration.fetch("enabled")
      @host = @configuration.fetch("host_address")
      address = @host && IPAddr.new(@host)
      raise Unavailable, "Configure a device-reachable LAN address for the fixture TLS route" unless address && !address.loopback? && address.to_i != 0
      @certificate = context.config.path(@configuration.fetch("certificate_file"))
      @key = context.config.path(@configuration.fetch("private_key_file"))
      raise Unavailable, "Configure an existing TLS certificate/key trusted by the selected device" unless @certificate && @key && File.readable?(@certificate) && File.readable?(@key)
      @control_token = SecureRandom.hex(32)
      context.secrets << @control_token
    rescue IPAddr::InvalidAddressError
      raise PipelineError, "Fixture host_address must be an explicit LAN IP address"
    end

    def start(upstream:, token:, offline_file:)
      uri = URI.parse(upstream)
      raise PipelineError, "Device route must use its freshly owned loopback fixture" unless uri.scheme == "http" && uri.host == "127.0.0.1" && ["", "/"].include?(uri.path) && uri.query.nil? && uri.user.nil? && uri.fragment.nil?
      binary = File.join(@context.private_dir, "device-route")
      @context.command(["go", "build", "-o", binary, "./tools/fixtures/device-route"], timeout: 300) unless File.executable?(binary)
      host = @host.include?(":") ? "[#{@host}]" : @host
      @process = @context.start([binary], input: JSON.generate({address: "#{host}:0", upstream: upstream, certificate: @certificate, key: @key, token: token, control_token: @control_token, offline_file: offline_file}))
      deadline = monotonic + @context.remaining(30)
      loop do
        line = @process.stdout.lines.first
        if line&.end_with?("\n")
          value = JSON.parse(line)
          address = value.fetch("address")
          raise PipelineError, "Unexpected physical route address" unless address.start_with?(host + ":")
          @url = "https://#{address}"
          uri = URI.parse(@url)
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, ca_file: @certificate, open_timeout: 5, read_timeout: 5) do |http|
            response = http.get("/", {"Authorization" => "Bearer #{token}"})
            raise PipelineError, "Fixture route did not preserve the gateway root contract" unless response.code == "404"
          end
          return @url
        end
        raise PipelineError, "Device route exited before readiness" unless @process.running?
        raise Interrupted, "Device fixture TLS route readiness expired" if monotonic >= deadline
        sleep 0.1
      end
    end

    def close
      @process&.stop
    end

    private
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
