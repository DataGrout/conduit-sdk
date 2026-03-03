# frozen_string_literal: true

require "json"
require "faraday"

module DatagroutConduit
  module OAuth
    # Lazily fetches and caches OAuth 2.1 client_credentials tokens.
    # Thread-safe via Mutex.
    class TokenProvider
      REFRESH_BUFFER_SECONDS = 60

      attr_reader :client_id, :token_endpoint

      def initialize(client_id:, client_secret:, token_endpoint:, scope: nil)
        @client_id = client_id
        @client_secret = client_secret
        @token_endpoint = token_endpoint
        @scope = scope
        @mutex = Mutex.new
        @cached_token = nil
        @expires_at = nil
      end

      # Derive the token endpoint from an MCP URL.
      #
      #   "https://app.datagrout.ai/servers/abc/mcp"
      #   => "https://app.datagrout.ai/servers/abc/oauth/token"
      def self.derive_token_endpoint(mcp_url)
        idx = mcp_url.index("/mcp")
        base = idx ? mcp_url[0...idx] : mcp_url.chomp("/")
        "#{base}/oauth/token"
      end

      # Return a valid bearer token, fetching or refreshing as needed.
      def get_token
        @mutex.synchronize do
          return @cached_token if token_valid?

          fetch_token!
          @cached_token
        end
      end

      # Force-invalidate the cached token (e.g. on receipt of a 401).
      def invalidate!
        @mutex.synchronize do
          @cached_token = nil
          @expires_at = nil
        end
      end

      private

      def token_valid?
        @cached_token && @expires_at && (Time.now < @expires_at - REFRESH_BUFFER_SECONDS)
      end

      def fetch_token!
        conn = Faraday.new(url: @token_endpoint) do |f|
          f.request :url_encoded
          f.adapter Faraday.default_adapter
        end

        params = {
          "grant_type" => "client_credentials",
          "client_id" => @client_id,
          "client_secret" => @client_secret
        }
        params["scope"] = @scope if @scope

        response = conn.post { |req| req.body = params }

        unless response.success?
          raise AuthError, "OAuth token endpoint returned #{response.status}: #{response.body}"
        end

        data = JSON.parse(response.body)
        @cached_token = data["access_token"]
        expires_in = (data["expires_in"] || 3600).to_i
        @expires_at = Time.now + expires_in
      end
    end
  end
end
