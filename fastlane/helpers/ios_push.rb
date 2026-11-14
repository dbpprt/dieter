# frozen_string_literal: true

require "plist"
require "time"
require_relative "dieter"

module Dieter
  # Release gates for background alerts: a successful simulator build cannot
  # prove that a phone build has the required APNs signing entitlement.
  module IOSPush
    module_function

    def entitlements!(value, bundle:, team:, group:, environment:, source:)
      unless value.is_a?(Hash) && value["application-identifier"] == "#{team}.#{bundle}" &&
               value["com.apple.developer.team-identifier"] == team &&
               Array(value["com.apple.security.application-groups"]).include?(group)
        raise Unavailable, "#{source}: expected app identity and App Group entitlements"
      end
      if environment && value["aps-environment"] != environment
        raise Unavailable,
              "#{source}: requires aps-environment=#{environment}. Enable Push Notifications for #{bundle} in Apple Developer, regenerate its App Store profile preserving the App Group, and replace IOS_PROVISIONING_PROFILE_BASE64 in apple-signing."
      end
    end

    def profile!(profile, bundle:, team:, group:, environment:, source:, now: Time.now)
      entitlements!(
        profile["Entitlements"],
        bundle: bundle,
        team: team,
        group: group,
        environment: environment,
        source: source
      )
      expires = Time.parse(profile.fetch("ExpirationDate").to_s)
      if expires <= now || profile.dig("Entitlements", "get-task-allow") != false ||
           profile.key?("ProvisionedDevices") || profile["ProvisionsAllDevices"] == true
        raise Unavailable, "#{source}: requires an unexpired App Store distribution profile"
      end
      profile.fetch("UUID")
    end

    def app!(info, entitlements, bundle:, team:, group:, version:, build:)
      unless info.values_at(
               "CFBundleIdentifier",
               "CFBundleShortVersionString",
               "CFBundleVersion"
             ) == [bundle, version, build] && info["DieterAPNSEnvironment"] == "production"
        raise Unavailable, "Exported IPA has incorrect release identity or APNs environment"
      end
      entitlements!(
        entitlements,
        bundle: bundle,
        team: team,
        group: group,
        environment: "production",
        source: "Exported IPA"
      )
    end

    def verify_ipa!(ipa, **expected)
      Dir.mktmpdir("dieter-push-check-") do |directory|
        Dieter.capture("unzip", "-q", ipa, "-d", directory)
        apps = Dir.glob(File.join(directory, "Payload", "*.app"))
        raise Unavailable, "Exported IPA must contain one main app" unless apps.length == 1
        app = apps.first
        Dieter.capture("/usr/bin/codesign", "--verify", "--strict", app)
        info =
          Plist.parse_xml(
            Dieter.capture("plutil", "-convert", "xml1", "-o", "-", File.join(app, "Info.plist"))
          )
        entitlements =
          Plist.parse_xml(
            Dieter.capture("/usr/bin/codesign", "--display", "--entitlements", ":-", app)
          )
        app!(info, entitlements, **expected)
      end
    end
  end
end
