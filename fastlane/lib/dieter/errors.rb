# frozen_string_literal: true

module Dieter
  class PipelineError < StandardError; end
  class Unavailable < PipelineError; end
  class Interrupted < PipelineError; end
  class CleanupError < PipelineError; end
end
