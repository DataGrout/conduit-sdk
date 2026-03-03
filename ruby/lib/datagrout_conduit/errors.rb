# frozen_string_literal: true

module DatagroutConduit
  class Error < StandardError; end

  class AuthError < Error; end

  class ConnectionError < Error; end

  class InitializationError < Error; end

  class TimeoutError < Error; end

  class ConfigError < Error; end

  class NotInitializedError < Error
    def initialize(msg = "Session not initialized. Call connect() first.")
      super
    end
  end

  class ToolNotFoundError < Error; end

  class ResourceNotFoundError < Error; end

  class InvalidArgumentsError < Error; end

  class McpError < Error
    attr_reader :code, :data

    def initialize(code:, message:, data: nil)
      @code = code
      @data = data
      super("MCP error #{code}: #{message}")
    end
  end

  class RateLimitedError < Error
    attr_reader :used, :limit

    def initialize(used:, limit:)
      @used = used
      @limit = limit
      super("Rate limit exceeded (#{used} / #{limit} calls this hour)")
    end
  end

  module McpCodes
    PARSE_ERROR      = -32_700
    INVALID_REQUEST  = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS   = -32_602
    INTERNAL_ERROR   = -32_603
    NOT_INITIALIZED  = -32_002
  end
end
