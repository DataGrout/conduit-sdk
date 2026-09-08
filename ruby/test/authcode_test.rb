# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

# Ports the Rust reference suite for the authorization-code flow.
class AuthCodeTest < Minitest::Test
  AC = DatagroutConduit::AuthCode

  RESOURCE = "https://gateway.datagrout.ai/connect"
  AUTHORIZE = "https://gateway.datagrout.ai/oauth/authorize"
  TOKEN = "https://gateway.datagrout.ai/oauth/token"
  REGISTER = "https://gateway.datagrout.ai/register"

  METADATA = {
    "issuer" => "https://gateway.datagrout.ai",
    "authorization_endpoint" => AUTHORIZE,
    "token_endpoint" => TOKEN,
    "registration_endpoint" => REGISTER,
    "code_challenge_methods_supported" => ["S256"],
    "grant_types_supported" => %w[authorization_code refresh_token]
  }.freeze

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # A server that serves AS metadata and 404s the protected-resource probe.
  def stub_metadata(metadata = METADATA)
    stub_request(:get, %r{/\.well-known/oauth-protected-resource})
      .to_return(status: 404, body: "not found")
    stub_request(:get, %r{/\.well-known/(oauth-authorization-server|openid-configuration)})
      .to_return(status: 200, headers: json_headers, body: JSON.generate(metadata))
  end

  def json_headers
    { "Content-Type" => "application/json" }
  end

  # A flow standing where discover leaves it, with a client id set.
  def a_flow(metadata = METADATA)
    stub_metadata(metadata)
    AC::Flow.discover(RESOURCE).with_client_id("client_abc", "http://127.0.0.1:8765/callback")
  end

  def a_grant(expires_at: nil, refresh: nil)
    AC::Grant.new(
      access_token: "at", client_id: "client_abc", token_endpoint: TOKEN,
      refresh_token: refresh, expires_at: expires_at
    )
  end

  def now
    Time.now.to_i
  end

  # ── PKCE ─────────────────────────────────────────────────────────────────

  def test_verifier_meets_rfc7636_length_and_alphabet
    verifier = AC.generate_verifier
    assert_equal 43, verifier.length
    assert_match(/\A[A-Za-z0-9\-_]+\z/, verifier)
  end

  def test_verifiers_are_unique
    assert_equal 50, Array.new(50) { AC.generate_verifier }.uniq.length
  end

  def test_challenge_matches_the_rfc7636_test_vector
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 AC.challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  end

  def test_challenge_is_unpadded_base64url
    challenge = AC.challenge_s256("anything")
    refute_includes challenge, "="
    assert_match(/\A[A-Za-z0-9\-_]+\z/, challenge)
  end

  # ── authorize URL ────────────────────────────────────────────────────────

  def test_authorize_url_carries_every_required_parameter
    url, pending = a_flow.authorize_url

    assert url.start_with?("#{AUTHORIZE}?")
    %w[response_type=code client_id=client_abc code_challenge_method=S256].each do |param|
      assert_includes url, param
    end
    assert_includes url, "state=#{pending.state}"
    assert_includes url, "code_challenge=#{AC.challenge_s256(pending.code_verifier)}"
  end

  def test_authorize_url_percent_encodes_redirect_and_resource
    url, = a_flow.authorize_url
    # The unreserved set only: a raw : or / would be read as structure.
    assert_includes url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback"
  end

  def test_authorize_url_binds_the_token_to_the_resource
    url, = a_flow.authorize_url
    # RFC 8707, so the token cannot be replayed against a different resource.
    assert_includes url, "resource=#{AC.urlencode(RESOURCE)}"
  end

  def test_authorize_url_requires_a_client_id
    stub_metadata
    flow = AC::Flow.discover(RESOURCE)
    assert_raises(AC::NoClientIdError) { flow.authorize_url }
  end

  def test_authorize_url_appends_when_the_endpoint_already_has_a_query
    metadata = METADATA.merge("authorization_endpoint" => "#{AUTHORIZE}?tenant=acme")
    url, = a_flow(metadata).authorize_url
    assert_includes url, "?tenant=acme&response_type=code"
  end

  def test_authorize_url_requests_the_default_scope
    url, = a_flow.authorize_url
    assert_includes url, "scope=mcp%20tools"
  end

  def test_authorize_url_honours_a_custom_scope
    url, = a_flow.with_scope("mcp").authorize_url
    assert_includes url, "scope=mcp"
  end

  # ── state / CSRF ─────────────────────────────────────────────────────────

  def test_exchange_refuses_a_mismatched_state
    flow = a_flow
    _, pending = flow.authorize_url
    # Refused before anything is sent: WebMock would raise on an unstubbed POST.
    assert_raises(AC::StateMismatchError) { flow.exchange(pending, "code", "wrong") }
  end

  def test_exchange_refuses_an_empty_state
    flow = a_flow
    _, pending = flow.authorize_url
    assert_raises(AC::StateMismatchError) { flow.exchange(pending, "code", "") }
  end

  def test_exchange_sends_the_verifier_and_resource_and_returns_a_grant
    flow = a_flow
    _, pending = flow.authorize_url

    stub_request(:post, TOKEN)
      .with(body: hash_including(
        "grant_type" => "authorization_code",
        "code" => "the_code",
        "client_id" => "client_abc",
        "code_verifier" => pending.code_verifier,
        "redirect_uri" => "http://127.0.0.1:8765/callback",
        "resource" => RESOURCE
      ))
      .to_return(status: 200, headers: json_headers, body: JSON.generate(
        "access_token" => "at_1", "refresh_token" => "rt_1",
        "expires_in" => 3600, "scope" => "mcp tools"
      ))

    grant = flow.exchange(pending, "the_code", pending.state)

    assert_equal "at_1", grant.access_token
    assert_equal "rt_1", grant.refresh_token
    assert_equal "client_abc", grant.client_id
    assert_equal TOKEN, grant.token_endpoint
    assert_equal RESOURCE, grant.resource
    assert_in_delta now + 3600, grant.expires_at, 5
  end

  def test_exchange_reports_a_rejection_with_its_status_and_body
    flow = a_flow
    _, pending = flow.authorize_url

    stub_request(:post, TOKEN)
      .to_return(status: 400, body: '{"error":"invalid_grant"}')

    error = assert_raises(AC::TokenExchangeError) do
      flow.exchange(pending, "code", pending.state)
    end
    assert_equal :token_exchange, error.kind
    assert_equal 400, error.status
    assert_includes error.body, "invalid_grant"
  end

  def test_exchange_refuses_a_token_response_that_is_not_an_object
    flow = a_flow
    _, pending = flow.authorize_url

    # A 200 carrying a JSON array is not a token response. Reporting it beats
    # a NoMethodError deep in the parse.
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers, body: '["not","an","object"]')

    error = assert_raises(AC::HttpError) { flow.exchange(pending, "code", pending.state) }
    assert_includes error.message, "expected a JSON object"
  end

  # ── Grant ────────────────────────────────────────────────────────────────

  def test_a_grant_with_no_stated_expiry_is_not_expired
    refute_predicate a_grant, :expired?
  end

  def test_a_grant_expires_early_by_the_refresh_skew
    # Expires in 30s, skew is 60s → already due for refresh.
    assert_predicate a_grant(expires_at: now + 30, refresh: "rt"), :expired?
    refute_predicate a_grant(expires_at: now + 600, refresh: "rt"), :expired?
  end

  def test_refreshing_without_a_refresh_token_is_a_typed_error
    error = assert_raises(AC::NotRefreshableError) { a_grant(expires_at: 0).refresh }
    assert_equal :not_refreshable, error.kind
  end

  def test_refresh_keeps_the_old_token_when_the_server_does_not_rotate
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers,
                 body: JSON.generate("access_token" => "at_2", "expires_in" => 3600))

    refreshed = a_grant(expires_at: 0, refresh: "rt_1").refresh

    assert_equal "at_2", refreshed.access_token
    # Not nil: silently dropping it would make the grant unrefreshable.
    assert_equal "rt_1", refreshed.refresh_token
  end

  def test_refresh_rotates_the_token_when_the_server_issues_a_new_one
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers, body: JSON.generate(
        "access_token" => "at_2", "refresh_token" => "rt_2", "expires_in" => 3600
      ))

    refreshed = a_grant(expires_at: 0, refresh: "rt_1").refresh
    assert_equal "rt_2", refreshed.refresh_token
  end

  def test_refresh_sends_the_resource_when_the_grant_is_bound
    grant = AC::Grant.new(
      access_token: "at", client_id: "client_abc", token_endpoint: TOKEN,
      refresh_token: "rt", expires_at: 0, resource: RESOURCE
    )

    stub = stub_request(:post, TOKEN)
           .with(body: hash_including("grant_type" => "refresh_token", "resource" => RESOURCE))
           .to_return(status: 200, headers: json_headers,
                      body: JSON.generate("access_token" => "at_2"))

    refreshed = grant.refresh
    assert_requested stub
    # The binding survives the refresh, or the next one would drop it.
    assert_equal RESOURCE, refreshed.resource
  end

  def test_grant_round_trips_with_the_cross_language_field_names
    grant = AC::Grant.new(
      access_token: "at", refresh_token: "rt", expires_at: 1_700_000_000,
      client_id: "cid", token_endpoint: TOKEN, scope: "mcp tools", resource: RESOURCE
    )

    hash = grant.to_h
    assert_equal %w[access_token client_id token_endpoint refresh_token expires_at scope resource].sort,
                 hash.keys.sort

    back = AC::Grant.from_h(JSON.parse(JSON.generate(hash)))
    assert_equal hash, back.to_h
  end

  def test_grant_omits_absent_optionals
    hash = AC::Grant.new(access_token: "at", client_id: "cid", token_endpoint: TOKEN).to_h
    # Not written as nulls: another SDK reading this must see absence.
    assert_equal %w[access_token client_id token_endpoint].sort, hash.keys.sort
  end

  def test_grant_reads_a_minimal_payload
    grant = AC::Grant.from_h(
      "access_token" => "at", "client_id" => "cid", "token_endpoint" => TOKEN
    )
    assert_nil grant.refresh_token
    assert_nil grant.expires_at
    refute_predicate grant, :refreshable?
  end

  def test_expires_at_is_unix_seconds_not_a_monotonic_reading
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers,
                 body: JSON.generate("access_token" => "at", "expires_in" => 3600))

    refreshed = a_grant(expires_at: 0, refresh: "rt").refresh
    # A monotonic reading is meaningless once written down; this must be a
    # wall-clock instant.
    assert_in_delta now + 3600, refreshed.expires_at, 5
  end

  # ── provider ─────────────────────────────────────────────────────────────

  def test_provider_returns_a_live_token_without_refreshing
    provider = AC::Provider.new(a_grant(expires_at: now + 3600, refresh: "rt"))
    assert_equal "at", provider.get_token
    # No stub registered, so any request would have failed the test.
  end

  def test_provider_refreshes_and_reports_a_rotated_grant
    stub_request(:post, TOKEN)
      .to_return(status: 200, headers: json_headers, body: JSON.generate(
        "access_token" => "at_2", "refresh_token" => "rt_2", "expires_in" => 3600
      ))

    provider = AC::Provider.new(a_grant(expires_at: 0, refresh: "rt_1"))
    assert_equal "at_2", provider.get_token
    assert_predicate provider, :dirty?

    rotated = provider.take_if_dirty
    assert_equal "rt_2", rotated.refresh_token
    # Cleared, so a persistence loop writes once per rotation.
    refute_predicate provider, :dirty?
    assert_nil provider.take_if_dirty
  end

  def test_provider_invalidate_forces_the_next_fetch_to_refresh
    stub = stub_request(:post, TOKEN)
           .to_return(status: 200, headers: json_headers,
                      body: JSON.generate("access_token" => "at_2", "expires_in" => 3600))

    provider = AC::Provider.new(a_grant(expires_at: now + 3600, refresh: "rt"))
    assert_equal "at", provider.get_token

    provider.invalidate!
    assert_equal "at_2", provider.get_token
    assert_requested stub
  end

  def test_provider_invalidate_keeps_the_refresh_token
    provider = AC::Provider.new(a_grant(expires_at: now + 3600, refresh: "rt"))
    provider.invalidate!
    # Dropping the grant would make recovery impossible.
    assert_equal "rt", provider.grant.refresh_token
  end

  def test_take_if_dirty_is_empty_until_something_changes
    assert_nil AC::Provider.new(a_grant).take_if_dirty
  end

  def test_provider_from_auth_accepts_every_shape
    grant = a_grant
    provider = AC::Provider.new(grant)

    assert_nil AC::Provider.from_auth(nil)
    assert_same provider, AC::Provider.from_auth(provider)
    assert_equal "at", AC::Provider.from_auth(grant).get_token
    assert_equal "at", AC::Provider.from_auth(grant.to_h).get_token
    # A hash written with symbol keys loads too.
    symbolized = grant.to_h.transform_keys(&:to_sym)
    assert_equal "at", AC::Provider.from_auth(symbolized).get_token
  end

  def test_provider_from_auth_rejects_nonsense
    assert_raises(ArgumentError) { AC::Provider.from_auth("a token string") }
  end

  def test_state_stays_answerable_while_a_refresh_is_in_flight
    started = Queue.new
    release = Queue.new

    stub_request(:post, TOKEN).to_return do
      started << :in_flight
      release.pop
      { status: 200, headers: json_headers,
        body: JSON.generate("access_token" => "at_2", "expires_in" => 3600) }
    end

    provider = AC::Provider.new(a_grant(expires_at: 0, refresh: "rt"))
    worker = Thread.new { provider.get_token }
    started.pop

    # The state lock is not held across the request, so a persistence loop
    # keeps working while a slow token endpoint is being waited on. This
    # blocked for the whole round trip before.
    Timeout.timeout(5) do
      assert_equal "at", provider.grant.access_token
      assert_nil provider.take_if_dirty
    end

    release << :go
    assert_equal "at_2", worker.value
  ensure
    release << :go
    worker&.join(1)
  end

  def test_concurrent_callers_share_one_refresh
    calls = Mutex.new
    count = 0
    gate = Queue.new

    stub_request(:post, TOKEN).to_return do
      calls.synchronize { count += 1 }
      # Hold the leader here so the others pile up behind it.
      gate.pop
      { status: 200, headers: json_headers,
        body: JSON.generate("access_token" => "at_2", "expires_in" => 3600) }
    end

    provider = AC::Provider.new(a_grant(expires_at: 0, refresh: "rt"))
    workers = Array.new(4) { Thread.new { provider.get_token } }

    # Let the single leader through once everyone is queued.
    sleep 0.1
    gate << :go

    assert_equal ["at_2"] * 4, workers.map(&:value)
    # One request, not four: serializing the refresh is what the second lock
    # is for.
    assert_equal 1, calls.synchronize { count }
  end

  def test_a_failing_refresh_is_shared_by_every_waiter
    count = 0
    counter = Mutex.new
    gate = Queue.new

    stub_request(:post, TOKEN).to_return do
      counter.synchronize { count += 1 }
      # Hold the leader until everyone else has queued behind it.
      gate.pop
      { status: 400, body: '{"error":"invalid_grant"}' }
    end

    provider = AC::Provider.new(a_grant(expires_at: 0, refresh: "rt"))

    workers = Array.new(4) do
      Thread.new do
        provider.get_token
      rescue AC::Error => e
        e
      end
    end

    sleep 0.1
    gate << :go

    results = workers.map(&:value)
    assert(results.all? { |r| r.is_a?(AC::TokenExchangeError) },
           "every waiter should get the leader's failure, got #{results.inspect}")
    # A dead token endpoint costs one request, not one per waiter.
    assert_equal 1, counter.synchronize { count }
  end

  def test_a_later_call_retries_after_a_failure_rather_than_replaying_it
    # The shared failure is only for callers that queued behind that attempt.
    # Once it has settled, the next call must try again.
    stub_request(:post, TOKEN)
      .to_return({ status: 400, body: '{"error":"temporarily_unavailable"}' },
                 { status: 200, headers: json_headers,
                   body: JSON.generate("access_token" => "at_2", "expires_in" => 3600) })

    provider = AC::Provider.new(a_grant(expires_at: 0, refresh: "rt"))

    assert_raises(AC::TokenExchangeError) { provider.get_token }
    assert_equal "at_2", provider.get_token
  end

  # ── metadata / discovery ─────────────────────────────────────────────────

  def test_s256_support_is_assumed_when_unadvertised
    # RFC 8414 makes the field optional and DataGrout omits it on some paths.
    metadata = AC::ServerMetadata.new(
      METADATA.reject { |k, _| k == "code_challenge_methods_supported" }
    )
    assert_predicate metadata, :supports_s256?
  end

  def test_a_server_advertising_only_plain_is_refused
    metadata = AC::ServerMetadata.new(
      METADATA.merge("code_challenge_methods_supported" => ["plain"])
    )
    refute_predicate metadata, :supports_s256?
  end

  def test_metadata_tolerates_a_missing_registration_endpoint
    metadata = AC::ServerMetadata.new(METADATA.reject { |k, _| k == "registration_endpoint" })
    assert_nil metadata.registration_endpoint
  end

  def test_metadata_without_the_required_endpoints_is_a_discovery_error
    assert_raises(AC::DiscoveryError) do
      AC::ServerMetadata.new("issuer" => "https://gateway.datagrout.ai")
    end
  end

  def test_discover_refuses_to_downgrade_pkce
    stub_metadata(METADATA.merge("code_challenge_methods_supported" => ["plain"]))
    error = assert_raises(AC::PkceUnsupportedError) { AC::Flow.discover(RESOURCE) }
    assert_equal :pkce_unsupported, error.kind
  end

  def test_discover_follows_protected_resource_metadata
    stub_request(:get, "#{RESOURCE}/.well-known/oauth-protected-resource")
      .to_return(status: 200, headers: json_headers,
                 body: JSON.generate("authorization_servers" => ["https://as.example.com"]))
    named = stub_request(:get, "https://as.example.com/.well-known/oauth-authorization-server")
            .to_return(status: 200, headers: json_headers, body: JSON.generate(METADATA))

    AC::Flow.discover(RESOURCE)
    assert_requested named
  end

  def test_discover_falls_back_to_the_resource_origin
    stub_request(:get, %r{/\.well-known/oauth-protected-resource}).to_return(status: 404)
    origin = stub_request(:get, "https://gateway.datagrout.ai/.well-known/oauth-authorization-server")
             .to_return(status: 200, headers: json_headers, body: JSON.generate(METADATA))

    AC::Flow.discover(RESOURCE)
    # DataGrout serves AS metadata at the origin, not under /connect.
    assert_requested origin
  end

  def test_discover_ignores_resource_metadata_that_is_not_an_object
    # A proxy answering 200 with a string body is not metadata; discovery
    # should carry on to the resource origin.
    stub_request(:get, %r{/\.well-known/oauth-protected-resource})
      .to_return(status: 200, headers: json_headers, body: '"not an object"')
    origin = stub_request(:get, "https://gateway.datagrout.ai/.well-known/oauth-authorization-server")
             .to_return(status: 200, headers: json_headers, body: JSON.generate(METADATA))

    AC::Flow.discover(RESOURCE)
    assert_requested origin
  end

  def test_discover_reports_failure_when_no_metadata_is_found
    stub_request(:get, %r{/\.well-known/}).to_return(status: 404, body: "nope")
    error = assert_raises(AC::DiscoveryError) { AC::Flow.discover(RESOURCE) }
    assert_equal :discovery, error.kind
  end

  def test_discover_falls_back_to_openid_configuration
    stub_request(:get, %r{/\.well-known/oauth-protected-resource}).to_return(status: 404)
    stub_request(:get, %r{/\.well-known/oauth-authorization-server}).to_return(status: 404)
    oidc = stub_request(:get, "https://gateway.datagrout.ai/.well-known/openid-configuration")
           .to_return(status: 200, headers: json_headers, body: JSON.generate(METADATA))

    AC::Flow.discover(RESOURCE)
    assert_requested oidc
  end

  # ── registration ─────────────────────────────────────────────────────────

  def test_register_sends_a_public_client_and_returns_the_pair
    stub_metadata
    flow = AC::Flow.discover(RESOURCE)

    stub = stub_request(:post, REGISTER)
           .with(body: hash_including(
             "client_name" => "My App",
             "redirect_uris" => ["http://127.0.0.1:8765/callback"],
             # No secret: a desktop app cannot keep one, and PKCE stands in.
             "token_endpoint_auth_method" => "none",
             "application_type" => "native"
           ))
           .to_return(status: 201, headers: json_headers,
                      body: JSON.generate("client_id" => "issued_id"))

    registered = flow.register("My App", "http://127.0.0.1:8765/callback")

    assert_requested stub
    assert_equal "issued_id", registered.client_id
    # The URI travels with the id, because redirect matching is exact.
    assert_equal "http://127.0.0.1:8765/callback", registered.redirect_uri
    assert_equal "issued_id", flow.client_id
  end

  def test_register_without_an_endpoint_is_a_distinct_error
    stub_metadata(METADATA.reject { |k, _| k == "registration_endpoint" })
    flow = AC::Flow.discover(RESOURCE)

    error = assert_raises(AC::NoRegistrationEndpointError) { flow.register("App", "http://x/cb") }
    assert_equal :no_registration_endpoint, error.kind
  end

  def test_register_rejection_carries_the_status_and_body
    stub_metadata
    flow = AC::Flow.discover(RESOURCE)
    stub_request(:post, REGISTER).to_return(status: 403, body: "forbidden")

    error = assert_raises(AC::RegistrationRejectedError) { flow.register("App", "http://x/cb") }
    assert_equal 403, error.status
    assert_equal "forbidden", error.body
  end

  def test_restoring_a_registered_client_restores_both_halves
    stub_metadata
    registered = AC::RegisteredClient.new(client_id: "saved_id", redirect_uri: "http://127.0.0.1:9/cb")

    flow = AC::Flow.discover(RESOURCE).with_registered_client(registered)

    assert_equal "saved_id", flow.client_id
    assert_equal "http://127.0.0.1:9/cb", flow.redirect_uri
  end

  def test_registered_client_round_trips
    registered = AC::RegisteredClient.new(client_id: "cid", redirect_uri: "http://127.0.0.1:9/cb")
    assert_equal registered, AC::RegisteredClient.from_h(JSON.parse(JSON.generate(registered.to_h)))
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  def test_origin_strips_paths_and_keeps_ports
    assert_equal "https://example.com", AC.origin_of("https://example.com/a/b?c=d")
    assert_equal "http://127.0.0.1:8765", AC.origin_of("http://127.0.0.1:8765/callback")
    # A default port is not part of the origin.
    assert_equal "https://example.com", AC.origin_of("https://example.com:443/x")
    assert_nil AC.origin_of("not a url")
  end

  def test_urlencode_escapes_everything_outside_the_unreserved_set
    assert_equal "a%20b", AC.urlencode("a b")
    assert_equal "-._~", AC.urlencode("-._~")
    assert_equal "%2F%3A", AC.urlencode("/:")
  end

  def test_secure_compare_is_length_independent
    assert AC.secure_compare("abc", "abc")
    refute AC.secure_compare("abc", "abcd")
    refute AC.secure_compare("abc", "abd")
    refute AC.secure_compare("", "a")
    assert AC.secure_compare("", "")
  end

  def test_default_scope_matches_the_servers_own_vocabulary
    # The authorization server's registration default. DataGrout stores what it
    # is given, so an invented scope is accepted silently and means nothing.
    assert_equal "mcp tools", AC::DEFAULT_SCOPE
  end

  def test_error_kinds_use_the_shared_wire_names
    # The taxonomy is part of the cross-language contract.
    assert_equal :discovery, AC::DiscoveryError.new("x").kind
    assert_equal :no_registration_endpoint, AC::NoRegistrationEndpointError.new.kind
    assert_equal :registration_rejected, AC::RegistrationRejectedError.new(status: 1, body: "").kind
    assert_equal :no_client_id, AC::NoClientIdError.new.kind
    assert_equal :pkce_unsupported, AC::PkceUnsupportedError.new.kind
    assert_equal :state_mismatch, AC::StateMismatchError.new.kind
    assert_equal :token_exchange, AC::TokenExchangeError.new(status: 1, body: "").kind
    assert_equal :not_refreshable, AC::NotRefreshableError.new.kind
    assert_equal :denied, AC::DeniedError.new(error: "access_denied").kind
    assert_equal :http, AC::HttpError.new("x").kind
  end

  def test_every_error_is_rescuable_as_an_auth_error
    # So a caller that only cares that authentication failed can say so.
    assert_kind_of DatagroutConduit::AuthError, AC::StateMismatchError.new
    assert_kind_of DatagroutConduit::Error, AC::StateMismatchError.new
  end
end
