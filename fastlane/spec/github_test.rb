# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require_relative "../lib/dieter/distribution/github"

class GitHubDraftLookupTest < Minitest::Test
  class Destination < Dieter::GitHubDestination
    attr_reader :requests
    def initialize(responses)
      @responses, @requests = responses, []
    end

    def api(path, **)
      requests << path
      result = @responses.fetch(path)
      raise result if result.is_a?(Exception)
      result
    end
  end

  def test_published_release_uses_direct_tag_lookup
    release = {"tag_name" => "v0.4.360", "draft" => false}
    destination = Destination.new("releases/tags/v0.4.360" => release)
    assert_equal release, destination.release("v0.4.360")
    assert_equal ["releases/tags/v0.4.360"], destination.requests
  end

  def test_authenticated_draft_lookup_follows_release_pages
    release = {"tag_name" => "v0.4.360", "draft" => true, "assets" => []}
    destination = Destination.new(
      "releases/tags/v0.4.360" => Dieter::PipelineError.new("gh: HTTP 404"),
      "releases?per_page=100&page=1" => 100.times.map { |index| {"tag_name" => "v0.4.#{index}"} },
      "releases?per_page=100&page=2" => [release]
    )
    assert_equal release, destination.release("v0.4.360")
    assert_equal 3, destination.requests.length
  end

  def test_missing_release_and_authorization_failures_are_preserved
    [404, 403].each do |status|
      error = Dieter::PipelineError.new("gh: HTTP #{status}")
      destination = Destination.new("releases/tags/v0.4.360" => error, "releases?per_page=100&page=1" => [])
      assert_same error, assert_raises(Dieter::PipelineError) { destination.release("v0.4.360") }
      assert_equal(status == 404 ? 2 : 1, destination.requests.length)
    end
  end
end
