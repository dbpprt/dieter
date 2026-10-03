# frozen_string_literal: true

require "minitest/autorun"
require "fastlane/command_line_handler"
require_relative "../lib/dieter/ci"

class CIOptionsTest < Minitest::Test
  def test_setup_accepts_values_from_the_pinned_fastlane_cli_parser
    %w[true false].each do |literal|
      parsed = Fastlane::CommandLineHandler.convert_value(literal)
      assert_equal literal, Dieter::CI.boolean_option(parsed, "fixture")
      assert_equal literal, Dieter::CI.boolean_option(parsed, "native")
      assert_equal literal, Dieter::CI.boolean_option(literal, "fixture")
    end
  end

  def test_invalid_setup_flags_do_not_admit_runner_preparation
    [nil, "", "maybe", 0, 1, []].each do |value|
      assert_raises(Dieter::PipelineError) { Dieter::CI.boolean_option(value, "fixture") }
    end
  end
end
