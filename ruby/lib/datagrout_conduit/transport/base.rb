# frozen_string_literal: true

require "faraday"
require "json"
require "base64"
require "securerandom"

module DatagroutConduit
  module Transport
    # Base transport shared by MCP and JSONRPC transports.
    # Manages a Faraday connection with optional mTLS and auth headers.
    class Base
      attr_reader :url

      def initialize(url:, auth: {}, identity: nil)
        @url = url
        @auth = normalize_auth(auth)
        @identity = identity
        @connected = false
        @connection = build_connection
      end

      def connect
        URI.parse(@url) # validate URL
        @connected = true
      end

      def disconnect
        @connected = false
      end

      def connected?
        @connected
      end

      # Subclasses must implement this.
      def send_request(_method, _params = nil, id: nil)
        raise NotImplementedError, "#{self.class}#send_request must be implemented"
      end

      private

      def ensure_connected!
        raise NotInitializedError unless @connected
      end

      def next_id
        SecureRandom.uuid
      end

      def build_connection
        Faraday.new(url: @url) do |f|
          f.request :json
          f.response :json, content_type: /\bjson$/
          f.adapter Faraday.default_adapter

          configure_ssl(f) if @identity
        end
      end

      def configure_ssl(faraday)
        faraday.ssl.client_cert = @identity.openssl_cert
        faraday.ssl.client_key = @identity.openssl_key
        if @identity.ca_pem
          store = OpenSSL::X509::Store.new
          store.add_cert(@identity.openssl_ca)
          faraday.ssl.cert_store = store
        end
      end

      def build_headers
        headers = { "Content-Type" => "application/json" }

        case @auth[:type]
        when :bearer
          headers["Authorization"] = "Bearer #{@auth[:token]}"
        when :api_key
          headers["X-API-Key"] = @auth[:key]
        when :basic
          encoded = Base64.strict_encode64("#{@auth[:username]}:#{@auth[:password]}")
          headers["Authorization"] = "Basic #{encoded}"
        when :oauth
          token = @auth[:provider].get_token
          headers["Authorization"] = "Bearer #{token}"
        end

        headers
      end

      def build_jsonrpc_body(method, params, id)
        body = {
          "jsonrpc" => "2.0",
          "id" => id || next_id,
          "method" => method
        }
        body["params"] = params if params
        body
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

        body = response.body
        body = JSON.parse(body) if body.is_a?(String)

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

      def check_rate_limit!(response)
        return unless response.status == 429

        used = response.headers["X-RateLimit-Used"]&.to_i || 0
        limit_str = response.headers["X-RateLimit-Limit"] || "50"
        limit = limit_str.casecmp("unlimited").zero? ? "unlimited" : limit_str.to_i

        raise RateLimitedError.new(used: used, limit: limit)
      end

      def normalize_auth(auth)
        return { type: :none } if auth.nil? || auth.empty?

        auth = auth.transform_keys(&:to_sym) if auth.is_a?(Hash)

        if auth[:bearer]
          { type: :bearer, token: auth[:bearer] }
        elsif auth[:api_key]
          { type: :api_key, key: auth[:api_key] }
        elsif auth[:basic]
          { type: :basic, username: auth[:basic][:username], password: auth[:basic][:password] }
        elsif auth[:oauth] || auth[:provider]
          { type: :oauth, provider: auth[:oauth] || auth[:provider] }
        else
          { type: :none }
        end
      end
    end
  end
end
