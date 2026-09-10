# frozen_string_literal: true

require_relative "test_helper"
require "cgi"

# RFC 8693 delegation — the exchange, the issued token, and the provider.
#
# Mirrors the Rust reference test set (rust/src/delegation.rs), which is the
# spec for this feature. The cross-language fixtures live in
# testdata/contract.json and are checked in DelegationContractTest below.
class DelegationTest < Minitest::Test
  D = DatagroutConduit::Delegation

  TOKEN_ENDPOINT = "https://as.example.com/oauth/token"

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def a_request(overrides = {})
    D::Request.new(**{
      token_endpoint: TOKEN_ENDPOINT,
      client_id: "agent_client",
      client_secret: "agent_secret",
      subject_token: "user_at",
      actor_token: "agent_at"
    }.merge(overrides))
  end

  def success_body(overrides = {})
    JSON.generate({
      "access_token" => "delegated_at",
      "issued_token_type" => D::TokenType::ACCESS_TOKEN_URN,
      "token_type" => "Bearer",
      "expires_in" => 900,
      "scope" => "mcp tools"
    }.merge(overrides))
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end

  # Parse a captured form body back into ordered pairs, so a test can assert
  # field order and not just presence.
  def pairs_of(body)
    body.split("&").map { |field| field.split("=", 2).map { |part| CGI.unescape(part) } }
  end

  # ── token types ──────────────────────────────────────────────────────────

  def test_token_types_round_trip_through_their_urns
    [D::TokenType::ACCESS_TOKEN, D::TokenType::JWT, D::TokenType::ID_TOKEN,
     D::TokenType::REFRESH_TOKEN, D::TokenType::SAML2].each do |type|
      assert type.urn.start_with?("urn:ietf:params:oauth:token-type:"), type.urn
      assert_equal type, D::TokenType.from_urn(type.urn)
    end
  end

  def test_an_unnamed_urn_is_carried_through_as_other
    custom = D::TokenType.from_urn("urn:example:custom")
    assert_equal :other, custom.name
    assert_equal "urn:example:custom", custom.urn
    assert_equal custom, D::TokenType.from_urn("urn:example:custom")
  end

  def test_a_token_type_renders_as_a_bare_urn
    assert_equal "urn:ietf:params:oauth:token-type:jwt", D::TokenType::JWT.to_s
    assert_equal :jwt, D::TokenType::JWT.name
  end

  def test_a_token_type_is_coerced_from_a_symbol_or_a_urn
    assert_equal D::TokenType::JWT, D::TokenType.coerce(:jwt)
    assert_equal D::TokenType::JWT, D::TokenType.coerce(D::TokenType::JWT_URN)
    assert_raises(ArgumentError) { D::TokenType.coerce(:nope) }
  end

  # ── form body ────────────────────────────────────────────────────────────

  def test_form_carries_exactly_the_expected_fields_in_wire_order
    form = a_request(
      audience: "https://gateway.example.com",
      resource: "https://gateway.example.com/connect",
      scope: "mcp tools",
      requested_token_type: D::TokenType::ACCESS_TOKEN
    ).form_params

    assert_equal [
      ["grant_type", D::GRANT_TYPE],
      ["subject_token", "user_at"],
      ["subject_token_type", D::TokenType::ACCESS_TOKEN_URN],
      ["actor_token", "agent_at"],
      ["actor_token_type", D::TokenType::ACCESS_TOKEN_URN],
      ["client_id", "agent_client"],
      ["client_secret", "agent_secret"],
      ["audience", "https://gateway.example.com"],
      ["resource", "https://gateway.example.com/connect"],
      ["scope", "mcp tools"],
      ["requested_token_type", D::TokenType::ACCESS_TOKEN_URN]
    ], form
  end

  def test_form_omits_optionals_that_were_not_set
    keys = a_request.form_params.map(&:first)
    %w[audience resource scope requested_token_type].each do |absent|
      refute_includes keys, absent, "#{absent} should not be sent"
    end
  end

  def test_form_sends_resource_whenever_it_is_set
    # RFC 8707 — the same invariant the authorization-code module keeps.
    form = a_request(resource: "https://gateway.example.com/connect").form_params
    assert_includes form, ["resource", "https://gateway.example.com/connect"]
  end

  def test_form_keeps_the_secret_out_of_the_body_under_basic_auth
    form = a_request(client_auth: :basic).form_params
    refute_includes form.map(&:first), "client_secret"
    # client_id still travels in the body.
    assert_includes form, ["client_id", "agent_client"]
  end

  def test_form_accepts_a_jwt_subject
    form = D::Request.new(
      token_endpoint: TOKEN_ENDPOINT, client_id: "c",
      subject_token: "eyJ", subject_token_type: :jwt,
      actor_token: "agent_at"
    ).form_params

    assert_includes form, ["subject_token_type", D::TokenType::JWT_URN]
  end

  def test_an_unknown_client_auth_mode_is_refused
    assert_raises(ArgumentError) { a_request(client_auth: :header) }
  end

  # ── refusals before any HTTP ─────────────────────────────────────────────

  def test_a_missing_actor_is_refused_before_any_request_is_sent
    stub = stub_request(:post, TOKEN_ENDPOINT)

    error = assert_raises(D::MissingActorError) do
      a_request(actor_token: nil).exchange
    end

    assert_equal :missing_actor, error.kind
    assert_includes error.message, "actor_token"
    assert_not_requested stub
  end

  def test_a_missing_subject_is_refused_before_any_request_is_sent
    stub = stub_request(:post, TOKEN_ENDPOINT)

    error = assert_raises(D::MissingSubjectError) do
      a_request(subject_token: nil).exchange
    end

    assert_equal :missing_subject, error.kind
    assert_not_requested stub
  end

  def test_impersonation_is_the_only_way_to_omit_the_actor
    form = a_request(actor_token: nil, impersonation: true).form_params
    assert_empty form.map(&:first).grep(/\Aactor_token/)
  end

  def test_every_delegation_error_is_an_sdk_auth_error
    [D::MissingSubjectError.new, D::MissingActorError.new, D::HttpError.new("x"),
     D::ServerError.new(status: 400, error: "invalid_grant"),
     D::InvalidResponseError.new("x")].each do |error|
      assert_kind_of DatagroutConduit::AuthError, error
    end
  end

  # ── the wire ─────────────────────────────────────────────────────────────

  def test_exchange_posts_a_form_encoded_body_with_the_actor_fields
    captured = nil
    stub_request(:post, TOKEN_ENDPOINT).to_return do |request|
      captured = request
      { status: 200, headers: json_headers, body: success_body }
    end

    issued = a_request(resource: "https://gateway.example.com/connect").exchange

    assert_equal "delegated_at", issued.access_token
    assert_equal "application/x-www-form-urlencoded", captured.headers["Content-Type"]
    assert_equal [
      ["grant_type", D::GRANT_TYPE],
      ["subject_token", "user_at"],
      ["subject_token_type", D::TokenType::ACCESS_TOKEN_URN],
      ["actor_token", "agent_at"],
      ["actor_token_type", D::TokenType::ACCESS_TOKEN_URN],
      ["client_id", "agent_client"],
      ["client_secret", "agent_secret"],
      ["resource", "https://gateway.example.com/connect"]
    ], pairs_of(captured.body)
  end

  def test_exchange_sends_basic_client_auth_when_asked
    expected = Base64.strict_encode64("agent_client:agent_secret")
    stub = stub_request(:post, TOKEN_ENDPOINT)
           .with(headers: { "Authorization" => "Basic #{expected}" })
           .to_return(status: 200, headers: json_headers, body: success_body)

    a_request(client_auth: :basic).exchange
    assert_requested stub
  end

  def test_exchange_sends_no_authorization_header_under_body_client_auth
    stub = stub_request(:post, TOKEN_ENDPOINT)
           .with { |request| !request.headers.key?("Authorization") }
           .to_return(status: 200, headers: json_headers, body: success_body)

    a_request.exchange
    assert_requested stub
  end

  def test_a_success_response_becomes_a_token_with_an_absolute_expiry
    stub_request(:post, TOKEN_ENDPOINT)
      .to_return(status: 200, headers: json_headers, body: success_body)

    before = Time.now.to_i
    issued = a_request.exchange
    after = Time.now.to_i

    assert_equal "delegated_at", issued.access_token
    assert_equal D::TokenType::ACCESS_TOKEN, issued.issued_token_type
    assert_equal "Bearer", issued.token_type
    assert_equal "mcp tools", issued.scope

    # expires_at = now + expires_in, in Unix seconds, allowing for the clock
    # ticking during the request.
    assert_operator issued.expires_at, :>=, before + 900
    assert_operator issued.expires_at, :<=, after + 900
    refute_predicate issued, :expired?
  end

  def test_an_rfc6749_error_body_is_a_server_error_with_code_and_status
    stub_request(:post, TOKEN_ENDPOINT).to_return(
      status: 400, headers: json_headers,
      body: JSON.generate("error" => "invalid_target", "error_description" => "unknown resource")
    )

    error = assert_raises(D::ServerError) { a_request.exchange }

    assert_equal :server, error.kind
    assert_equal 400, error.status
    assert_equal D::Codes::INVALID_TARGET, error.error
    assert_equal "unknown resource", error.error_description
  end

  def test_a_failure_without_an_oauth_body_is_an_invalid_response
    stub_request(:post, TOKEN_ENDPOINT)
      .to_return(status: 502, body: "<html>bad gateway</html>")

    error = assert_raises(D::InvalidResponseError) { a_request.exchange }

    assert_equal :invalid_response, error.kind
    assert_includes error.message, "502"
  end

  def test_a_success_missing_issued_token_type_is_an_invalid_response
    # RFC 8693 §2.2.1 makes the field REQUIRED; a server that drops it is out
    # of contract, and guessing would hide that.
    stub_request(:post, TOKEN_ENDPOINT).to_return(
      status: 200, headers: json_headers,
      body: JSON.generate("access_token" => "x", "token_type" => "Bearer")
    )

    error = assert_raises(D::InvalidResponseError) { a_request.exchange }
    assert_includes error.message, "issued_token_type"
  end

  def test_a_success_missing_token_type_is_an_invalid_response
    stub_request(:post, TOKEN_ENDPOINT).to_return(
      status: 200, headers: json_headers,
      body: JSON.generate("access_token" => "x",
                          "issued_token_type" => D::TokenType::ACCESS_TOKEN_URN)
    )

    error = assert_raises(D::InvalidResponseError) { a_request.exchange }
    assert_includes error.message, "token_type"
  end

  def test_a_success_that_is_not_json_is_an_invalid_response
    stub_request(:post, TOKEN_ENDPOINT).to_return(status: 200, body: "not json")
    assert_raises(D::InvalidResponseError) { a_request.exchange }
  end

  def test_an_unreachable_endpoint_is_an_http_error
    stub_request(:post, TOKEN_ENDPOINT).to_raise(Faraday::ConnectionFailed.new("refused"))

    error = assert_raises(D::HttpError) { a_request.exchange }
    assert_equal :http, error.kind
  end

  # ── token ────────────────────────────────────────────────────────────────

  def a_token(expires_at: nil, scope: nil)
    D::Token.new(
      access_token: "delegated_at",
      issued_token_type: D::TokenType::ACCESS_TOKEN,
      token_type: "Bearer",
      expires_at: expires_at,
      scope: scope
    )
  end

  def test_a_token_with_no_stated_expiry_is_not_expired
    refute_predicate a_token, :expired?
  end

  def test_a_token_expires_early_by_the_refresh_skew
    assert_predicate a_token(expires_at: Time.now.to_i + 30), :expired?
    refute_predicate a_token(expires_at: Time.now.to_i + 600), :expired?
  end

  def test_a_token_omits_absent_optionals_when_serialized
    hash = a_token.to_h
    refute_includes hash.keys, "expires_at"
    refute_includes hash.keys, "scope"
    assert_equal D::TokenType::ACCESS_TOKEN_URN, hash["issued_token_type"]
  end

  def test_a_token_round_trips_through_its_hash
    token = a_token(expires_at: 1_700_000_000, scope: "mcp tools")
    assert_equal token, D::Token.from_h(token.to_h)
  end

  def test_a_token_hash_missing_a_required_field_is_an_invalid_response
    assert_raises(D::InvalidResponseError) do
      D::Token.from_h("access_token" => "x", "token_type" => "Bearer")
    end
  end

  def test_a_token_never_prints_itself
    refute_includes a_token.inspect, "delegated_at"
  end

  # ── token sources ────────────────────────────────────────────────────────

  def test_a_static_source_resolves_its_token
    source = D::TokenSource.static_token("user_at")
    assert_equal "user_at", source.resolve
    assert_equal D::TokenType::ACCESS_TOKEN, source.token_type
    assert_equal :static, source.kind
  end

  def test_a_callable_source_is_consulted_every_time
    calls = 0
    source = D::TokenSource.callable(token_type: :jwt) { calls += 1; "user_#{calls}" }

    assert_equal "user_1", source.resolve
    assert_equal "user_2", source.resolve
    assert_equal D::TokenType::JWT, source.token_type
  end

  def test_a_client_credentials_source_pulls_from_its_provider
    machine = Minitest::Mock.new
    machine.expect(:get_token, "agent_live")

    assert_equal "agent_live", D::TokenSource.client_credentials(machine).resolve
    machine.verify
  end

  def test_an_authorization_code_source_accepts_a_grant_hash
    grant = DatagroutConduit::AuthCode::Grant.new(
      access_token: "user_live", client_id: "c",
      token_endpoint: TOKEN_ENDPOINT, expires_at: Time.now.to_i + 3600
    )

    assert_equal "user_live", D::TokenSource.authorization_code(grant.to_h).resolve
  end

  def test_a_source_declares_a_different_token_type_without_mutating
    source = D::TokenSource.static_token("user_at")
    jwt = source.with_token_type(:jwt)

    assert_equal D::TokenType::JWT, jwt.token_type
    assert_equal D::TokenType::ACCESS_TOKEN, source.token_type
  end

  def test_a_source_never_prints_its_token
    refute_includes D::TokenSource.static_token("user_at").inspect, "user_at"
  end

  # ── provider ─────────────────────────────────────────────────────────────

  def a_provider(subject: D::TokenSource.static_token("user_at"),
                 actor: D::TokenSource.static_token("agent_at"),
                 request: nil)
    D::Provider.new(
      request || D::Request.new(token_endpoint: TOKEN_ENDPOINT, client_id: "agent_client",
                                client_secret: "agent_secret"),
      subject: subject, actor: actor
    )
  end

  def test_provider_exchanges_once_and_serves_from_cache_until_expiry
    stub = stub_request(:post, TOKEN_ENDPOINT)
           .to_return(status: 200, headers: json_headers, body: success_body)

    provider = a_provider
    3.times { assert_equal "delegated_at", provider.get_token }

    assert_requested stub, times: 1
    refute_nil provider.token
  end

  def test_provider_re_exchanges_after_invalidate
    stub = stub_request(:post, TOKEN_ENDPOINT)
           .to_return(status: 200, headers: json_headers, body: success_body)

    provider = a_provider
    provider.get_token
    provider.invalidate!
    assert_nil provider.token
    provider.get_token

    assert_requested stub, times: 2
  end

  def test_provider_re_exchanges_a_token_that_is_inside_the_skew
    # Expires in 30s: already inside the 60s buffer, so the second call must
    # exchange again rather than serve it.
    stub = stub_request(:post, TOKEN_ENDPOINT).to_return(
      status: 200, headers: json_headers,
      body: success_body("expires_in" => 30)
    )

    provider = a_provider
    provider.get_token
    provider.get_token

    assert_requested stub, times: 2
  end

  def test_provider_pulls_fresh_upstream_tokens_on_every_exchange
    subjects = []
    stub_request(:post, TOKEN_ENDPOINT).to_return do |request|
      subjects << pairs_of(request.body).to_h["subject_token"]
      { status: 200, headers: json_headers, body: success_body }
    end

    calls = 0
    provider = a_provider(subject: D::TokenSource.callable { calls += 1; "user_#{calls}" })

    provider.get_token
    provider.invalidate!
    provider.get_token

    assert_equal %w[user_1 user_2], subjects
  end

  def test_provider_uses_a_client_credentials_actor
    machine = Minitest::Mock.new
    machine.expect(:get_token, "agent_live")

    actors = []
    stub_request(:post, TOKEN_ENDPOINT).to_return do |request|
      actors << pairs_of(request.body).to_h["actor_token"]
      { status: 200, headers: json_headers, body: success_body }
    end

    provider = a_provider(actor: D::TokenSource.client_credentials(machine))

    assert_equal "delegated_at", provider.get_token
    assert_equal ["agent_live"], actors
    machine.verify
  end

  def test_provider_without_an_actor_fails_loudly_unless_impersonating
    stub = stub_request(:post, TOKEN_ENDPOINT)

    error = assert_raises(D::MissingActorError) { a_provider(actor: nil).get_token }

    assert_includes error.message, "actor_token"
    assert_not_requested stub
  end

  def test_provider_without_an_actor_exchanges_when_impersonating
    stub = stub_request(:post, TOKEN_ENDPOINT)
           .to_return(status: 200, headers: json_headers, body: success_body)

    provider = a_provider(
      actor: nil,
      request: D::Request.new(token_endpoint: TOKEN_ENDPOINT, client_id: "c",
                              impersonation: true)
    )

    assert_equal "delegated_at", provider.get_token
    assert_requested stub, times: 1
  end

  def test_provider_single_flights_concurrent_callers
    hits = 0
    counter = Mutex.new

    # A slow endpoint, so the other callers are reliably queued behind the
    # leader rather than racing it.
    stub_request(:post, TOKEN_ENDPOINT).to_return do
      counter.synchronize { hits += 1 }
      sleep 0.3
      { status: 200, headers: json_headers, body: success_body }
    end

    provider = a_provider
    threads = 5.times.map { Thread.new { provider.get_token } }

    assert_equal ["delegated_at"] * 5, threads.map(&:value)
    assert_equal 1, hits, "each caller exchanged for its own token"
  end

  def test_provider_never_prints_tokens_or_secrets
    rendered = a_provider.inspect

    refute_includes rendered, "agent_secret"
    refute_includes rendered, "user_at"
    refute_includes rendered, "agent_at"
    assert_includes rendered, "agent_client"
  end

  def test_provider_from_auth_rejects_anything_but_a_provider
    provider = a_provider
    assert_same provider, D::Provider.from_auth(provider)
    assert_nil D::Provider.from_auth(nil)
    assert_raises(ArgumentError) { D::Provider.from_auth("token") }
  end

  def test_a_request_never_prints_its_secret_or_tokens
    rendered = a_request.inspect

    refute_includes rendered, "agent_secret"
    refute_includes rendered, "user_at"
    refute_includes rendered, "agent_at"
  end
end
