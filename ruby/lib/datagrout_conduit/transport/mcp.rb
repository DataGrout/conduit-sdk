# frozen_string_literal: true

module DatagroutConduit
  module Transport
    # MCP Streamable HTTP transport.
    # Sends JSON-RPC requests via HTTP POST to the MCP endpoint.
    class Mcp < Base
      def initialize(url:, auth: {}, identity: nil)
        super
        @session_id = nil
      end

      def send_request(method, params = nil, id: nil)
        ensure_connected!

        request_id = id || next_id
        body = build_jsonrpc_body(method, params, request_id)
        headers = build_headers

        response = @connection.post do |req|
          req.headers = headers
          req.body = JSON.generate(body)
        end

        track_session_id(response)
        result = handle_response(response)

        if result == :retry_oauth
          headers = build_headers
          response = @connection.post do |req|
            req.headers = headers
            req.body = JSON.generate(body)
          end
          track_session_id(response)
          result = handle_response(response)
          raise AuthError, "OAuth token rejected after refresh" if result == :retry_oauth
        end

        result
      end

      private

      def build_headers
        headers = super
        headers["Accept"] = "application/json, text/event-stream"
        headers["Mcp-Session-Id"] = @session_id if @session_id
        headers
      end

      def track_session_id(response)
        sid = response.headers["mcp-session-id"]
        @session_id = sid if sid
      end

      def handle_response(response)
        check_rate_limit!(response)

        if response.status == 401 && @auth[:type] == :oauth
          @auth[:provider].invalidate!
          return :retry_oauth
        end

        return { "accepted" => true } if response.status == 202

        unless response.success?
          raise ConnectionError, "HTTP #{response.status} error"
        end

        content_type = response.headers["content-type"].to_s

        if content_type.include?("text/event-stream")
          messages = parse_sse(response.body.to_s)
          body = messages.last || {}
        else
          body = response.body
          body = JSON.parse(body) if body.is_a?(String)
        end

        if body.is_a?(Hash) && body["error"]
          err = body["error"]
          raise McpError.new(
            code: err["code"] || -1,
            message: err["message"] || "Unknown error",
            data: err["data"]
          )
        end

        body
      end

      def parse_sse(body)
        messages = []
        body.split("\n\n").each do |chunk|
          chunk.each_line do |line|
            if line.start_with?("data:")
              data = line.sub(/^data:\s*/, "").strip
              next if data.empty?
              messages << JSON.parse(data)
            end
          end
        end
        messages
      end
    end
  end
end
