# frozen_string_literal: true

require_relative "test_helper"

# The transports must authenticate with an authorization-code grant.
#
# Each resolves a provider on the way out and invalidates it on a 401, which is
# the whole reason an expired access token recovers by refreshing instead of
# surfacing to the caller as an auth failure. Covered for all three, because the
# MCP and WebSocket transports carry their own copies of this wiring.
class AuthCodeTransportTest < Minitest::Test
  AC = DatagroutConduit::AuthCode

  ENDPOINT = "https://gateway.datagrout.ai/connect"
  TOKEN = "https://gateway.datagrout.ai/oauth/token"

  HTTP_TRANSPORTS = [DatagroutConduit::Transport::Mcp,
                     DatagroutConduit::Transport::JsonRpc].freeze

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end

  def a_grant(expires_in: 3600, refresh: "rt")
    AC::Grant.new(
      access_token: "user_access_token", client_id: "client_abc",
      token_endpoint: TOKEN, refresh_token: refresh,
      expires_at: Time.now.to_i + expires_in
    )
  end

  def transport(klass, auth)
    klass.new(url: ENDPOINT, auth: auth).tap { |t| t.instance_variable_set(:@connected, true) }
  end

  # The private header builder, which is where a grant becomes a bearer.
  def headers_for(klass, auth)
    transport(klass, auth).send(:build_headers)
  end

  # ── header building ──────────────────────────────────────────────────────

  def test_an_authorization_code_grant_becomes_a_bearer_header
    HTTP_TRANSPORTS.each do |klass|
      headers = headers_for(klass, authorization_code: a_grant)
      assert_equal "Bearer user_access_token", headers["Authorization"],
                   "#{klass} did not send the grant's access token"
    end
  end

  def test_a_grant_hash_is_accepted
    # A grant loaded straight from JSON, without constructing the object.
    HTTP_TRANSPORTS.each do |klass|
      headers = headers_for(klass, authorization_code: a_grant.to_h)
      assert_equal "Bearer user_access_token", headers["Authorization"]
    end
  end

  def test_a_caller_owned_provider_is_used_as_is
    HTTP_TRANSPORTS.each do |klass|
      provider = AC::Provider.new(a_grant)
      t = transport(klass, authorization_code: provider)
      # Same object, so a rotated refresh token reaches the caller's copy.
      assert_same provider, t.instance_variable_get(:@auth)[:provider]
    end
  end

  def test_an_oauth_provider_still_wins_when_both_are_given
    # Not a configuration to recommend, but the precedence must be defined
    # rather than depend on hash ordering.
    machine = Minitest::Mock.new
    machine.expect(:get_token, "machine_token")

    headers = headers_for(
      DatagroutConduit::Transport::JsonRpc,
      oauth: machine, authorization_code: a_grant
    )
    assert_equal "Bearer machine_token", headers["Authorization"]
    machine.verify
  end

  def test_an_expired_grant_is_refreshed_before_the_request
    stub_request(:post, TOKEN)
      .with(body: hash_including("grant_type" => "refresh_token"))
      .to_return(status: 200, headers: json_headers,
                 body: JSON.generate("access_token" => "refreshed", "expires_in" => 3600))

    HTTP_TRANSPORTS.each do |klass|
      headers = headers_for(klass, authorization_code: a_grant(expires_in: -10))
      assert_equal "Bearer refreshed", headers["Authorization"]
    end
  end

  def test_no_authorization_header_without_auth
    HTTP_TRANSPORTS.each do |klass|
      assert_nil headers_for(klass, {})["Authorization"]
    end
  end

  # ── 401 recovery ─────────────────────────────────────────────────────────

  def test_a_401_refreshes_the_grant_and_retries_once
    HTTP_TRANSPORTS.each do |klass|
      WebMock.reset!
      calls = []

      stub_request(:post, TOKEN)
        .with(body: hash_including("grant_type" => "refresh_token"))
        .to_return do
          calls << "token"
          { status: 200, headers: json_headers,
            body: JSON.generate("access_token" => "refreshed", "expires_in" => 3600) }
        end

      stub_request(:post, ENDPOINT).to_return do |request|
        auth = request.headers["Authorization"]
        calls << "rpc:#{auth}"
        if auth == "Bearer user_access_token"
          # Stale access token — what a rotated or revoked one looks like.
          { status: 401, body: "unauthorized" }
        else
          { status: 200, headers: json_headers,
            body: JSON.generate("jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true }) }
        end
      end

      result = transport(klass, authorization_code: a_grant).send_request("tools/list")

      assert_equal({ "ok" => true }, result["result"], "#{klass} did not recover")
      # First attempt with the stale token, a refresh, then one retry — and no
      # third attempt, so a genuinely bad credential cannot loop.
      assert_equal ["rpc:Bearer user_access_token", "token", "rpc:Bearer refreshed"], calls,
                   "#{klass} took the wrong path"
    end
  end

  def test_a_401_that_survives_a_refresh_raises
    HTTP_TRANSPORTS.each do |klass|
      WebMock.reset!
      attempts = 0

      stub_request(:post, TOKEN)
        .to_return(status: 200, headers: json_headers,
                   body: JSON.generate("access_token" => "still_bad", "expires_in" => 3600))
      stub_request(:post, ENDPOINT).to_return do
        attempts += 1
        { status: 401, body: "unauthorized" }
      end

      assert_raises(DatagroutConduit::AuthError) do
        transport(klass, authorization_code: a_grant).send_request("tools/list")
      end
      # Exactly one retry: a revoked grant fails fast instead of recursing.
      assert_equal 2, attempts, "#{klass} retried the wrong number of times"
    end
  end

  def test_a_401_without_a_provider_is_not_retried
    HTTP_TRANSPORTS.each do |klass|
      WebMock.reset!
      attempts = 0
      stub_request(:post, ENDPOINT).to_return do
        attempts += 1
        { status: 401, body: "unauthorized" }
      end

      # Nothing to refresh, so there is nothing to retry.
      assert_raises(DatagroutConduit::ConnectionError) do
        transport(klass, bearer: "static").send_request("tools/list")
      end
      assert_equal 1, attempts
    end
  end

  # ── WebSocket upgrade ────────────────────────────────────────────────────
  #
  # Resolving a token is synchronous in Ruby, so the upgrade could always carry
  # a provider-backed bearer — the bug the async SDKs had to fix could not
  # occur here. These pin that down for both grants.

  def upgrade_headers(auth)
    DatagroutConduit::Transport::Ws
      .new(url: "wss://gateway.datagrout.ai/ws", auth: auth)
      .send(:build_upgrade_headers)
  end

  def test_the_upgrade_carries_an_authorization_code_bearer
    assert_equal "Bearer user_access_token",
                 upgrade_headers(authorization_code: a_grant)["Authorization"]
  end

  def test_the_upgrade_accepts_a_grant_hash
    assert_equal "Bearer user_access_token",
                 upgrade_headers(authorization_code: a_grant.to_h)["Authorization"]
  end

  def test_the_upgrade_refreshes_an_expired_grant
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers,
                 body: JSON.generate("access_token" => "refreshed", "expires_in" => 3600))

    assert_equal "Bearer refreshed",
                 upgrade_headers(authorization_code: a_grant(expires_in: -10))["Authorization"]
  end

  def test_the_upgrade_carries_a_client_credentials_bearer
    machine = Minitest::Mock.new
    machine.expect(:get_token, "machine_token")
    assert_equal "Bearer machine_token", upgrade_headers(oauth: machine)["Authorization"]
    machine.verify
  end

  def test_the_upgrade_still_carries_a_static_bearer
    assert_equal "Bearer static", upgrade_headers(bearer: "static")["Authorization"]
  end

  def test_the_upgrade_sends_no_authorization_header_without_auth
    assert_nil upgrade_headers({})["Authorization"]
  end
end
