# frozen_string_literal: true

require_relative "test_helper"

class OnrampTest < Minitest::Test
  GATEWAY = "https://app.datagrout.ai"
  ONRAMP_URL = "#{GATEWAY}/onramp"
  COMPLETE_URL = "#{GATEWAY}/onramp/complete"
  TOKEN_URL = "#{GATEWAY}/servers/abc/oauth/token"

  INIT_RESPONSE = { "session_token" => "sess_abc123" }.freeze

  COMPLETE_RESPONSE = {
    "client_id" => "agt_abc123",
    "client_secret" => "sk_xyz789",
    "token_url" => TOKEN_URL,
    "mcp_url" => "#{GATEWAY}/servers/abc/mcp",
    "rpc_url" => "#{GATEWAY}/servers/abc/rpc",
    "scopes" => ["mcp:read", "tools:call"],
    "expires_in" => 2_592_000
  }.freeze

  TOKEN_RESPONSE = { "access_token" => "tok_live123" }.freeze

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def default_opts
    DatagroutConduit::Onramp::OnrampOptions.new(
      gateway: GATEWAY,
      agent_name: "test-agent",
      agent_type: "claude-sonnet-4-6",
      intended_use: "Testing."
    )
  end

  # ─── OnrampOptions ──────────────────────────────────────────────────────────

  def test_onramp_options_required_fields
    opts = DatagroutConduit::Onramp::OnrampOptions.new(
      gateway: GATEWAY,
      agent_name: "my-agent"
    )
    assert_equal GATEWAY, opts.gateway
    assert_equal "my-agent", opts.agent_name
    assert_nil opts.agent_type
    assert_nil opts.intended_use
    assert_nil opts.access_code
  end

  def test_onramp_options_all_fields
    opts = DatagroutConduit::Onramp::OnrampOptions.new(
      gateway: GATEWAY,
      agent_name: "my-agent",
      agent_type: "gpt-4o",
      intended_use: "extraction",
      access_code: "code123"
    )
    assert_equal "gpt-4o", opts.agent_type
    assert_equal "extraction", opts.intended_use
    assert_equal "code123", opts.access_code
  end

  # ─── OnrampCredentials ──────────────────────────────────────────────────────

  def test_onramp_credentials_fields
    creds = DatagroutConduit::Onramp::OnrampCredentials.new(
      client_id: "agt_abc",
      client_secret: "sk_xyz",
      token_url: TOKEN_URL,
      scopes: ["mcp:read"],
      expires_in: 2_592_000,
      mcp_url: "#{GATEWAY}/servers/abc/mcp",
      rpc_url: "#{GATEWAY}/servers/abc/rpc"
    )
    assert_equal "agt_abc", creds.client_id
    assert_equal ["mcp:read"], creds.scopes
    assert_equal 2_592_000, creds.expires_in
  end

  def test_onramp_credentials_nil_urls
    creds = DatagroutConduit::Onramp::OnrampCredentials.new(
      client_id: "x", client_secret: "y", token_url: TOKEN_URL,
      scopes: [], expires_in: 0
    )
    assert_nil creds.mcp_url
    assert_nil creds.rpc_url
  end

  # ─── register_only ──────────────────────────────────────────────────────────

  def test_register_only_sends_init_then_complete
    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )

    stub_request(:post, COMPLETE_URL)
      .with(headers: { "Authorization" => "Bearer sess_abc123" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(COMPLETE_RESPONSE)
      )

    creds = DatagroutConduit::Onramp.register_only(default_opts)

    assert_equal "agt_abc123", creds.client_id
    assert_equal "sk_xyz789", creds.client_secret
    assert_equal TOKEN_URL, creds.token_url
    assert_equal ["mcp:read", "tools:call"], creds.scopes
    assert_equal "#{GATEWAY}/servers/abc/mcp", creds.mcp_url
    assert_equal 2_592_000, creds.expires_in
  end

  def test_register_only_includes_optional_fields
    stub_request(:post, ONRAMP_URL)
      .with(body: hash_including(
        "agent_name" => "test-agent",
        "agent_type" => "claude-sonnet-4-6",
        "intended_use" => "Testing."
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )

    stub_request(:post, COMPLETE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(COMPLETE_RESPONSE)
      )

    DatagroutConduit::Onramp.register_only(default_opts)
    assert_requested :post, ONRAMP_URL
  end

  def test_register_only_omits_nil_optional_fields
    bare_opts = DatagroutConduit::Onramp::OnrampOptions.new(
      gateway: GATEWAY,
      agent_name: "bare"
    )

    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )

    stub_request(:post, COMPLETE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(COMPLETE_RESPONSE)
      )

    DatagroutConduit::Onramp.register_only(bare_opts)

    assert_not_requested :post, ONRAMP_URL,
      body: hash_including("agent_type" => /\S+/)
  end

  def test_register_only_raises_on_init_rejected
    stub_request(:post, ONRAMP_URL).to_return(status: 429, body: "rate_limited")

    assert_raises DatagroutConduit::Onramp::OnrampError do
      DatagroutConduit::Onramp.register_only(default_opts)
    end
  end

  def test_register_only_raises_on_complete_rejected
    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )
    stub_request(:post, COMPLETE_URL).to_return(status: 410, body: "expired")

    assert_raises DatagroutConduit::Onramp::OnrampError do
      DatagroutConduit::Onramp.register_only(default_opts)
    end
  end

  def test_register_only_handles_absent_mcp_url
    partial = COMPLETE_RESPONSE.reject { |k, _| k == "mcp_url" || k == "rpc_url" }

    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )
    stub_request(:post, COMPLETE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(partial)
      )

    creds = DatagroutConduit::Onramp.register_only(default_opts)
    assert_nil creds.mcp_url
    assert_nil creds.rpc_url
  end

  # ─── register_and_exchange ──────────────────────────────────────────────────

  def test_register_and_exchange_returns_creds_and_token
    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )
    stub_request(:post, COMPLETE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(COMPLETE_RESPONSE)
      )
    stub_request(:post, TOKEN_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(TOKEN_RESPONSE)
      )

    creds, token = DatagroutConduit::Onramp.register_and_exchange(default_opts)

    assert_equal "agt_abc123", creds.client_id
    assert_equal "tok_live123", token
  end

  def test_register_and_exchange_raises_on_token_exchange_failure
    stub_request(:post, ONRAMP_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(INIT_RESPONSE)
      )
    stub_request(:post, COMPLETE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(COMPLETE_RESPONSE)
      )
    stub_request(:post, TOKEN_URL).to_return(status: 401, body: "invalid_client")

    assert_raises DatagroutConduit::Onramp::OnrampError do
      DatagroutConduit::Onramp.register_and_exchange(default_opts)
    end
  end
end
