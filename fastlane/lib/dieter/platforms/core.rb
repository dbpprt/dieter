# frozen_string_literal: true

module Dieter
  class Core
    def initialize(context)
      @context = context
    end

    def unit(_options = {})
      gradle(%w[:shared:jvmTest])
    end

    def apple_test(options = {})
      @context.lease("apple-build")
      gradle(%w[:shared:macosArm64Test :apple:macosArm64Test :apple:assembleDieterSharedDebugXCFramework])
      Mac.new(@context).core_test(options)
    end

    private

    def gradle(tasks)
      @context.command([File.join(@context.root, "apps/core/gradlew"), "--project-dir", "apps/core", "--console=plain", *tasks], timeout: 3600, log: File.join(@context.output, "core.log"))
    end
  end
end
