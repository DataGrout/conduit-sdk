# frozen_string_literal: true

module DatagroutConduit
  module Transport
    # JSON-RPC over HTTP POST transport.
    # Sends standard JSON-RPC 2.0 requests via HTTP POST.
    class JsonRpc < Base
      def send_request(method, params = nil, id: nil)
        ensure_connected!

        request_id = id || next_id
        body = build_jsonrpc_body(method, params, request_id)
        headers = build_headers

        response = @connection.post do |req|
          req.headers = headers
          req.body = JSON.generate(body)
        end

        result = handle_response(response)

        if result == :retry_oauth
          headers = build_headers
          response = @connection.post do |req|
            req.headers = headers
            req.body = JSON.generate(body)
          end
          result = handle_response(response)
          raise AuthError, "OAuth token rejected after refresh" if result == :retry_oauth
        end

        result
      end
    end
  end
end
