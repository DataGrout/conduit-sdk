# frozen_string_literal: true

require "faraday"
require "json"

module DatagroutConduit
  # Autonomous agent self-registration (onramp) for DataGrout.
  #
  # The onramp flow lets a machine intelligence register itself with DG
  # without a human in the loop, using only plain HTTP JSON — no MCP client
  # required.
  #
  # == Flow
  #
  # 1. POST to +/onramp+ with agent identity metadata (no auth).
  # 2. DG returns a short-lived +session_token+ (5 minutes).
  # 3. POST to +/onramp/complete+ with +Authorization: Bearer <session_token>+.
  # 4. DG issues provisional +client_id+ + +client_secret+ (restricted scopes).
  #
  # == Example
  #
  #   opts = DatagroutConduit::Onramp::OnrampOptions.new(
  #     gateway: "https://app.datagrout.ai",
  #     agent_name: "my-research-agent",
  #     agent_type: "claude-sonnet-4-6"
  #   )
  #   client = DatagroutConduit::Client.bootstrap_onramp(opts: opts, url: nil)
  module Onramp
    # Options for the autonomous agent onramp flow.
    OnrampOptions = Struct.new(
      :gateway,
      :agent_name,
      :agent_type,
      :intended_use,
      :access_code,
      keyword_init: true
    )

    # Provisional credentials returned by the DG onramp complete endpoint.
    #
    # Store +client_id+ and +client_secret+ securely — the secret is shown
    # exactly once and cannot be recovered after this point.
    OnrampCredentials = Struct.new(
      :client_id,
      :client_secret,
      :token_url,
      :scopes,
      :expires_in,
      :rpc_url,
      :mcp_url,
      keyword_init: true
    )

    class OnrampError < StandardError; end

    # Perform the onramp handshake and return provisional OAuth credentials.
    #
    # Low-level entry point. Most callers should use
    # {DatagroutConduit::Client.bootstrap_onramp} instead.
    #
    # @param opts [OnrampOptions]
    # @return [OnrampCredentials]
    def self.register_only(opts)
      register(opts)
    end

    # Perform the full onramp handshake and OAuth token exchange.
    #
    # @param opts [OnrampOptions]
    # @return [Array(OnrampCredentials, String)] credentials and access token
    def self.register_and_exchange(opts)
      creds = register(opts)
      token = exchange_token(creds)
      [creds, token]
    end

    # @api private
    def self.register(opts)
      base = opts.gateway.chomp("/")

      body = { agent_name: opts.agent_name }
      body[:agent_type] = opts.agent_type if opts.agent_type
      body[:intended_use] = opts.intended_use if opts.intended_use
      body[:access_code] = opts.access_code if opts.access_code

      conn = build_conn

      init_resp = conn.post("#{base}/onramp") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      raise OnrampError, "onramp init rejected (HTTP #{init_resp.status}): #{init_resp.body}" \
        unless init_resp.success?

      init_data = parse_body(init_resp.body)
      session_token = init_data["session_token"]

      complete_resp = conn.post("#{base}/onramp/complete") do |req|
        req.headers["Authorization"] = "Bearer #{session_token}"
      end

      raise OnrampError, "onramp complete rejected (HTTP #{complete_resp.status}): #{complete_resp.body}" \
        unless complete_resp.success?

      data = parse_body(complete_resp.body)

      OnrampCredentials.new(
        client_id: data["client_id"],
        client_secret: data["client_secret"],
        token_url: data["token_url"],
        scopes: data["scopes"] || [],
        expires_in: data["expires_in"] || 0,
        rpc_url: data["rpc_url"],
        mcp_url: data["mcp_url"]
      )
    end
    private_class_method :register

    # @api private
    def self.exchange_token(creds)
      conn = Faraday.new do |f|
        f.request :url_encoded
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end

      resp = conn.post(creds.token_url, {
        grant_type: "client_credentials",
        client_id: creds.client_id,
        client_secret: creds.client_secret
      })

      raise OnrampError, "token exchange failed (HTTP #{resp.status}): #{resp.body}" \
        unless resp.success?

      data = parse_body(resp.body)
      data["access_token"]
    end
    private_class_method :exchange_token

    def self.build_conn
      Faraday.new do |f|
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end
    private_class_method :build_conn

    def self.parse_body(body)
      body.is_a?(String) ? JSON.parse(body) : body
    end
    private_class_method :parse_body
  end
end
