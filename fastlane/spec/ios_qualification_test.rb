# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../lib/dieter/runtime"

class IOSQualificationTest < Minitest::Test
  Config =
    Struct.new(:root) do
      def environment = { "DIETER_RELEASE_VERSION" => "0.4.413" }
      def data =
        {
          "defaults" => {
            "suite" => "smoke"
          },
          "profiles" => {
            "ios-iphone" => {
              "layout" => "iphone"
            },
            "ios-ipad" => {
              "layout" => "ipad"
            }
          }
        }
      def profile(name, **) =
        data.fetch("profiles").fetch(name).merge("name" => name, "kind" => "simulator")
    end

  def qualify(empty: false, unavailable: false, compose: false)
    Dir.mktmpdir do |root|
      events = []
      contract = Object.new
      contract.define_singleton_method(:call) do |operation, request, **|
        if operation == "plan"
          events << [:plan, request.fetch(:device)]
          { "cases" => empty ? [] : [{ "id" => "ios.credentials", "timeout" => "10s" }] }
        else
          {}
        end
      end
      factory =
        lambda do |_context, **|
          adapter = Object.new
          adapter.define_singleton_method(:admit) do |target, _|
            events << [:admit, target.fetch("name")]
            raise Dieter::Unavailable, "runtime absent" if unavailable
          end
          adapter.define_singleton_method(:build) { |_| events << [:build] }
          adapter.define_singleton_method(:prepared_products) do |manifest|
            events << [:products, manifest]
          end
          adapter.define_singleton_method(:prepare) { |*, **| events << [:prepare] }
          adapter.define_singleton_method(:execute_case) { |*, **| { "status" => "passed" } }
          adapter
        end
      Dieter::Config.stub(:new, Config.new(root)) do
        Dieter::Contract.stub(:new, ->(*) { contract }) do
          klass = compose ? Class.new : Dieter::IOS
          klass.define_singleton_method(:new, factory) if compose
          Dieter::IOS.stub(:new, factory) do
            output =
              Dieter::Runtime.ios_qualify(
                { profiles: "ios-iphone,ios-ipad", changed: true },
                adapter_class: klass,
                planned_cases: compose ? [{ "id" => "compose.ios", "timeout" => "10s" }] : nil
              )
            selection = JSON.parse(File.read(File.join(output, "selection.json")))
            yield events, selection
          end
        end
      end
    end
  end

  def test_compose_uses_the_shared_layout_loop_and_one_build_without_selecting_shipping_cases
    qualify(compose: true) do |events, selection|
      assert_equal(
        { "ios-iphone" => ["compose.ios"], "ios-ipad" => ["compose.ios"] },
        selection.fetch("profiles")
      )
      assert_equal 0, events.count { |event| event.first == :plan }
      assert_equal 1, events.count { |event| event.first == :build }
      assert_equal 2, events.count { |event| event.first == :prepare }
    end
  end

  def test_empty_changed_selection_does_not_build_or_admit_devices
    qualify(empty: true) do |events, selection|
      assert_equal "not-required", selection.fetch("status")
      assert_equal [[:plan, "iphone"], [:plan, "ipad"]],
                   events.reject { |event| event.first == :products }
    end
  end

  def test_runtime_admission_failure_happens_before_shared_build
    error =
      assert_raises(Dieter::Unavailable) do
        qualify(unavailable: true) { flunk "unavailable runtime admitted" }
      end
    assert_equal "runtime absent", error.message
  end

  def test_plans_both_layouts_and_builds_once_before_case_preparation
    qualify do |events, selection|
      assert_equal "required", selection.fetch("status")
      assert_equal 2, events.count { |event| event.first == :plan }
      assert_equal 1, events.count { |event| event.first == :build }
      assert_equal 2, events.count { |event| event.first == :prepare }
      assert_operator events.index([:build]), :<, events.index([:prepare])
      assert_equal 1, events.select { |event| event.first == :products }.map(&:last).uniq.length
    end
  end
end
