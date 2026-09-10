# frozen_string_literal: true

require_relative "test_helper"

# The transports must authenticate with a delegated (RFC 8693) token.
#
# Each resolves the provider on the way out and invalidates it on a 401, which
# is why an expired delegated token recovers by re-exchanging instead of
# surfacing to the caller as an auth failure. Covered for all three, because the
# MCP and WebSocket transports carry their own copies of this wiring.
class DelegationTransportTest < Minitest::Test
  D = DatagroutConduit::Delegation

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

  def exchange_body(access_token: "delegated_1", expires_in: 900)
    JSON.generate(
      "access_token" => access_token,
      "issued_token_type" => D::TokenType::ACCESS_TOKEN_URN,
      "token_type" => "Bearer",
      "expires_in" => expires_in
    )
  end

  def a_provider
    D::Provider.new(
      D::Request.new(token_endpoint: TOKEN, client_id: "agent_client",
                     client_secret: "agent_secret"),
      subject: D::TokenSource.static_token("user_at"),
      actor: D::TokenSource.static_token("agent_at")
    )
  end

  def transport(klass, auth)
    klass.new(url: ENDPOINT, auth: auth).tap { |t| t.instance_variable_set(:@connected, true) }
  end

  # ── header building ──────────────────────────────────────────────────────

  def test_a_delegated_token_becomes_a_bearer_header
    stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                         body: exchange_body)

    HTTP_TRANSPORTS.each do |klass|
      headers = transport(klass, delegation: a_provider).send(:build_headers)
      assert_equal "Bearer delegated_1", headers["Authorization"],
                   "#{klass} did not send the exchanged token"
    end
  end

  def test_the_provider_is_used_as_is
    HTTP_TRANSPORTS.each do |klass|
      provider = a_provider
      t = transport(klass, delegation: provider)
      assert_same provider, t.instance_variable_get(:@auth)[:provider]
    end
  end

  def test_a_serialized_credential_is_refused
    # A delegation needs live token sources; there is nothing to load from JSON.
    assert_raises(ArgumentError) do
      transport(DatagroutConduit::Transport::JsonRpc, delegation: { "access_token" => "x" })
    end
  end

  # ── 401 recovery ─────────────────────────────────────────────────────────

  def test_a_401_re_exchanges_the_token_and_retries_once
    HTTP_TRANSPORTS.each do |klass|
      WebMock.reset!
      calls = []
      issued = 0

      stub_request(:post, TOKEN).to_return do
        issued += 1
        calls << "exchange"
        { status: 200, headers: json_headers, body: exchange_body(access_token: "delegated_#{issued}") }
      end

      stub_request(:post, ENDPOINT).to_return do |request|
        auth = request.headers["Authorization"]
        calls << "rpc:#{auth}"
        if auth == "Bearer delegated_1"
          # A stale delegated token — what a revoked one looks like.
          { status: 401, body: "unauthorized" }
        else
          { status: 200, headers: json_headers,
            body: JSON.generate("jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true }) }
        end
      end

      result = transport(klass, delegation: a_provider).send_request("tools/list")

      assert_equal({ "ok" => true }, result["result"], "#{klass} did not recover")
      # One exchange, an attempt with it, a re-exchange, one retry — and no
      # third attempt, so a genuinely bad credential cannot loop.
      assert_equal ["exchange", "rpc:Bearer delegated_1", "exchange", "rpc:Bearer delegated_2"],
                   calls, "#{klass} took the wrong path"
    end
  end

  def test_a_401_that_survives_a_re_exchange_raises
    HTTP_TRANSPORTS.each do |klass|
      WebMock.reset!
      attempts = 0

      stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                           body: exchange_body(access_token: "still_bad"))
      stub_request(:post, ENDPOINT).to_return do
        attempts += 1
        { status: 401, body: "unauthorized" }
      end

      assert_raises(DatagroutConduit::AuthError) do
        transport(klass, delegation: a_provider).send_request("tools/list")
      end
      # Exactly one retry: a revoked delegation fails fast instead of recursing.
      assert_equal 2, attempts, "#{klass} retried the wrong number of times"
    end
  end

  # ── precedence over the grant the exchange itself consumes ───────────────
  #
  # A delegating caller almost always configures a provider grant as well,
  # because the exchange consumes it as the actor or subject source. So the
  # two arriving together is the ordinary case, not a misconfiguration, and
  # delegation has to win. When it lost, the transport sent the agent's own
  # machine token — a perfectly valid token carrying no `act` — and the user
  # disappeared from the audit trail with nothing failing. That makes this
  # ordering a correctness rule rather than a preference.

  # Stands in for the machine grant that feeds the exchange.
  class StubMachineProvider
    def get_token
      "agent_machine_token"
    end

    def invalidate!
      nil
    end
  end

  def test_delegation_outranks_the_machine_grant_on_the_http_transports
    stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                         body: exchange_body)

    HTTP_TRANSPORTS.each do |klass|
      t = transport(klass, delegation: a_provider, oauth: StubMachineProvider.new)

      assert_equal :delegation, t.instance_variable_get(:@auth)[:type],
                   "#{klass} resolved to the machine grant instead of the delegation"
      assert_equal "Bearer delegated_1", t.send(:build_headers)["Authorization"],
                   "#{klass} sent the agent's own token instead of the delegated one"
    end
  end

  def test_delegation_outranks_the_machine_grant_on_the_upgrade
    stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                         body: exchange_body)

    headers = upgrade_headers(delegation: a_provider, oauth: StubMachineProvider.new)

    assert_equal "Bearer delegated_1", headers["Authorization"],
                 "the upgrade sent the agent's own token instead of the delegated one"
  end

  # ── WebSocket upgrade ────────────────────────────────────────────────────
  #
  # The bearer must be resolved *before* the handshake, so the upgrade request
  # itself carries it. Resolving is synchronous in Ruby, so this happens in
  # header construction; the async SDKs had to hoist it out to get the same
  # result.

  def upgrade_headers(auth)
    DatagroutConduit::Transport::Ws
      .new(url: "wss://gateway.datagrout.ai/ws", auth: auth)
      .send(:build_upgrade_headers)
  end

  def test_the_upgrade_carries_the_exchanged_bearer
    stub = stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                                body: exchange_body)

    assert_equal "Bearer delegated_1", upgrade_headers(delegation: a_provider)["Authorization"]
    assert_requested stub, times: 1
  end

  def test_the_upgrade_reuses_a_cached_delegated_token
    stub = stub_request(:post, TOKEN).to_return(status: 200, headers: json_headers,
                                                body: exchange_body)

    provider = a_provider
    2.times { assert_equal "Bearer delegated_1", upgrade_headers(delegation: provider)["Authorization"] }
    assert_requested stub, times: 1
  end

  def test_the_upgrade_fails_loudly_when_the_exchange_is_refused
    stub_request(:post, TOKEN).to_return(
      status: 400, headers: json_headers,
      body: JSON.generate("error" => "invalid_grant")
    )

    error = assert_raises(D::ServerError) { upgrade_headers(delegation: a_provider) }
    assert_equal :server, error.kind
  end
end
