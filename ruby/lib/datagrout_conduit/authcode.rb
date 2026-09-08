# frozen_string_literal: true

require "json"
require "base64"
require "digest"
require "securerandom"
require "uri"
require "faraday"

module DatagroutConduit
  # OAuth 2.1 **authorization code + PKCE** — browser-consent sign-in.
  #
  # The +client_credentials+ grant in {OAuth} authenticates a *machine*: it
  # needs a client secret issued out of band. This module authenticates a
  # *person*: the app opens a browser, the user consents at the gateway, and the
  # app receives a grant bound to that user's account. It is what a desktop or
  # CLI application needs, and the only way to use
  # +https://gateway.datagrout.ai/connect+, where the server binding is chosen
  # at consent time and lives in the token rather than the URL.
  #
  # == Flow
  #
  # 1. {Flow.discover} — fetch protected-resource metadata, then the
  #    authorization server's metadata.
  # 2. {Flow#register} — RFC 7591 dynamic client registration, as a **public
  #    client** (no secret; PKCE takes its place).
  # 3. {Flow#authorize_url} — build the consent URL and hold the PKCE verifier
  #    and CSRF state in a {PendingAuthorization}.
  # 4. The caller opens that URL and captures the redirect.
  #    {AuthCode::LoopbackListener} does the capturing.
  # 5. {Flow#exchange} — trade the code for a {Grant}.
  #
  #   flow = DatagroutConduit::AuthCode::Flow.discover("https://gateway.datagrout.ai/connect")
  #   registered = flow.register("My App", "http://127.0.0.1:8765/callback")
  #
  #   url, pending = flow.authorize_url
  #   puts "Open: #{url}"
  #
  #   grant = flow.exchange(pending, code, state)
  #   client = DatagroutConduit::Client.new(url: GATEWAY, auth: { authorization_code: grant })
  #
  # == Persisting the grant
  #
  # This module owns the {Grant} shape and its refresh logic; it deliberately
  # does *not* choose where a grant is stored. That is the application's
  # decision — a keychain, a config file, a vault — and baking a filesystem
  # opinion into an SDK makes it wrong for half its callers.
  #
  # {Grant#expires_at} is Unix seconds rather than a monotonic reading precisely
  # so a grant survives serialization: it is written by one process and read by
  # another, possibly in a different language.
  module AuthCode
    # Scopes requested when the caller does not specify.
    #
    # Matches the authorization server's own registration default rather than
    # inventing a finer-grained vocabulary: DataGrout splits the scope string on
    # whitespace and stores what it is given, so a made-up scope is accepted
    # silently and then means nothing.
    DEFAULT_SCOPE = "mcp tools"

    # Refresh this many seconds before the token actually expires.
    REFRESH_SKEW_SECONDS = 60

    # ── Errors ───────────────────────────────────────────────────────────────
    #
    # The taxonomy is part of the cross-language contract: every conduit SDK
    # distinguishes these same cases, so callers can branch identically. Ruby
    # callers branch by rescuing a subclass; {Error#kind} gives the same
    # distinction as a symbol, and its name is the one the other SDKs use.

    # Base class for every authorization-code failure.
    class Error < DatagroutConduit::AuthError
      # @return [Symbol] the cross-language error kind
      attr_reader :kind
      # @return [Integer, nil] HTTP status, when the failure came from a response
      attr_reader :status
      # @return [String, nil] response body, when the failure came from a response
      attr_reader :body

      def initialize(message, kind: :http, status: nil, body: nil)
        @kind = kind
        @status = status
        @body = body
        super(message)
      end
    end

    # Metadata discovery failed or returned something unusable.
    class DiscoveryError < Error
      def initialize(message)
        super("OAuth discovery failed: #{message}", kind: :discovery)
      end
    end

    # The authorization server does not advertise dynamic client registration.
    class NoRegistrationEndpointError < Error
      def initialize(_message = nil)
        super(
          "authorization server has no registration endpoint — register a " \
          "client manually and use Flow#with_client_id",
          kind: :no_registration_endpoint
        )
      end
    end

    # Dynamic client registration was rejected.
    class RegistrationRejectedError < Error
      def initialize(status:, body:)
        super(
          "client registration rejected (HTTP #{status}): #{body}",
          kind: :registration_rejected, status: status, body: body
        )
      end
    end

    # +authorize_url+ was called before a client id was known.
    class NoClientIdError < Error
      def initialize(_message = nil)
        super(
          "no client_id — call register or with_client_id first",
          kind: :no_client_id
        )
      end
    end

    # The server does not support PKCE with S256.
    #
    # Downgrading to +plain+, or to no PKCE at all, would defeat the point of
    # the flow for a public client, so this is refused rather than negotiated.
    class PkceUnsupportedError < Error
      def initialize(_message = nil)
        super(
          "authorization server does not support PKCE S256; refusing to downgrade",
          kind: :pkce_unsupported
        )
      end
    end

    # The +state+ returned by the redirect did not match the one sent.
    #
    # A CSRF signal: the response belongs to a different authorization request.
    # Never proceed past this.
    class StateMismatchError < Error
      def initialize(_message = nil)
        super(
          "state mismatch — the authorization response does not match this request",
          kind: :state_mismatch
        )
      end
    end

    # The token endpoint rejected the exchange or refresh.
    class TokenExchangeError < Error
      def initialize(status:, body:)
        super(
          "token exchange failed (HTTP #{status}): #{body}",
          kind: :token_exchange, status: status, body: body
        )
      end
    end

    # The grant has no refresh token, so it cannot be renewed.
    class NotRefreshableError < Error
      def initialize(_message = nil)
        super(
          "grant has expired and carries no refresh_token — re-authorize",
          kind: :not_refreshable
        )
      end
    end

    # The authorization server returned an error at the redirect.
    class DeniedError < Error
      def initialize(error:, description: nil)
        message = "authorization denied: #{error}"
        message += " — #{description}" if description
        super(message, kind: :denied)
      end
    end

    # Transport failure talking to the authorization server.
    class HttpError < Error
      def initialize(message)
        super(message, kind: :http)
      end
    end

    # ── Metadata ─────────────────────────────────────────────────────────────

    # RFC 8414 authorization server metadata (the fields this flow uses).
    class ServerMetadata
      attr_reader :issuer, :authorization_endpoint, :token_endpoint,
                  :registration_endpoint, :code_challenge_methods_supported,
                  :grant_types_supported, :scopes_supported

      def initialize(data)
        @issuer = data["issuer"].to_s
        @authorization_endpoint = data["authorization_endpoint"]
        @token_endpoint = data["token_endpoint"]
        @registration_endpoint = data["registration_endpoint"]
        @code_challenge_methods_supported = Array(data["code_challenge_methods_supported"])
        @grant_types_supported = Array(data["grant_types_supported"])
        @scopes_supported = Array(data["scopes_supported"])

        return if @authorization_endpoint && @token_endpoint

        raise DiscoveryError,
              "metadata is missing authorization_endpoint or token_endpoint"
      end

      # Whether the server can do PKCE with S256.
      #
      # An empty list means the server did not advertise. RFC 8414 makes the
      # field optional and DataGrout omits it on some paths, so absence is
      # treated as "assume S256" rather than as a refusal — a server that truly
      # cannot do S256 will reject the authorize request anyway.
      def supports_s256?
        return true if @code_challenge_methods_supported.empty?

        @code_challenge_methods_supported.any? { |m| m.to_s.casecmp("S256").zero? }
      end
    end

    # ── Registered client ────────────────────────────────────────────────────

    # A dynamically-registered client: the id **and** the redirect URI it is
    # bound to.
    #
    # These travel together because an authorization server matches the redirect
    # URI *exactly* against the value registered — there is no loopback-port
    # exemption to rely on. Persisting the id alone means a later
    # re-authorization on a freshly-chosen port is rejected as
    # +invalid_redirect_uri+, and the failure only shows up once the first grant
    # can no longer be refreshed.
    #
    # Persist this next to the {Grant} and restore it with
    # {Flow#with_registered_client}.
    class RegisteredClient
      attr_reader :client_id, :redirect_uri

      def initialize(client_id:, redirect_uri:)
        @client_id = client_id
        @redirect_uri = redirect_uri
      end

      def to_h
        { "client_id" => @client_id, "redirect_uri" => @redirect_uri }
      end

      def self.from_h(data)
        new(client_id: data["client_id"], redirect_uri: data["redirect_uri"])
      end

      def ==(other)
        other.is_a?(RegisteredClient) && to_h == other.to_h
      end
    end

    # ── Grant ────────────────────────────────────────────────────────────────

    # A user's authorization, ready to persist.
    #
    # The serialized shape is part of the cross-language contract: a grant
    # written by one conduit SDK must be readable by another. Field names and
    # types are therefore fixed, and +expires_at+ is Unix seconds — never a
    # monotonic reading, which is meaningless once written to disk.
    class Grant
      attr_reader :access_token, :refresh_token, :expires_at, :client_id,
                  :token_endpoint, :scope, :resource

      def initialize(access_token:, client_id:, token_endpoint:,
                     refresh_token: nil, expires_at: nil, scope: nil, resource: nil)
        @access_token = access_token
        @refresh_token = refresh_token
        @expires_at = expires_at
        @client_id = client_id
        @token_endpoint = token_endpoint
        @scope = scope
        @resource = resource
      end

      # The cross-language wire shape. Absent optionals are omitted rather than
      # written as nulls, so a grant round-trips through any of the SDKs.
      def to_h
        h = {
          "access_token" => @access_token,
          "client_id" => @client_id,
          "token_endpoint" => @token_endpoint
        }
        h["refresh_token"] = @refresh_token if @refresh_token
        h["expires_at"] = @expires_at if @expires_at
        h["scope"] = @scope if @scope
        h["resource"] = @resource if @resource
        h
      end

      def self.from_h(data)
        new(
          access_token: data["access_token"],
          client_id: data["client_id"],
          token_endpoint: data["token_endpoint"],
          refresh_token: data["refresh_token"],
          expires_at: data["expires_at"]&.to_i,
          scope: data["scope"],
          resource: data["resource"]
        )
      end

      # True when the access token is expired, or within the refresh skew of it.
      #
      # A grant with no stated expiry is treated as live: the server chose not
      # to say, and guessing an expiry would throw away working tokens.
      def expired?
        return false if @expires_at.nil?

        AuthCode.now_secs + REFRESH_SKEW_SECONDS >= @expires_at
      end

      # Whether this grant can renew itself without user interaction.
      def refreshable?
        !@refresh_token.nil?
      end

      # Exchange the refresh token for a fresh grant.
      #
      # Returns a new Grant; the old one should be discarded. DataGrout rotates
      # refresh tokens, so keeping the previous grant around and using it again
      # can invalidate the whole family.
      def refresh
        raise NotRefreshableError unless refreshable?

        form = {
          "grant_type" => "refresh_token",
          "refresh_token" => @refresh_token,
          "client_id" => @client_id
        }
        form["resource"] = @resource if @resource

        token = AuthCode.post_form(@token_endpoint, form)

        Grant.new(
          access_token: token["access_token"],
          # A server that does not rotate returns no new refresh token; keep the
          # existing one rather than silently making the grant unrefreshable
          # from here on.
          refresh_token: token["refresh_token"] || @refresh_token,
          expires_at: token["expires_in"] && AuthCode.now_secs + token["expires_in"].to_i,
          client_id: @client_id,
          token_endpoint: @token_endpoint,
          scope: token["scope"] || @scope,
          resource: @resource
        )
      end
    end

    # ── Pending authorization ────────────────────────────────────────────────

    # The secrets held between building the consent URL and redeeming the code.
    class PendingAuthorization
      attr_reader :code_verifier, :state, :redirect_uri

      def initialize(code_verifier:, state:, redirect_uri:)
        @code_verifier = code_verifier
        @state = state
        @redirect_uri = redirect_uri
        freeze
      end
    end

    # ── The flow ─────────────────────────────────────────────────────────────

    # Drives discovery, registration, consent, and exchange.
    class Flow
      attr_reader :metadata, :resource, :client_id, :redirect_uri, :scope

      def initialize(metadata:, resource:, client_id: nil, redirect_uri: nil,
                     scope: DEFAULT_SCOPE)
        @metadata = metadata
        @resource = resource
        @client_id = client_id
        @redirect_uri = redirect_uri
        @scope = scope
      end

      # Discover the authorization server protecting +resource_url+.
      #
      # +resource_url+ is the MCP endpoint being connected to — for DataGrout,
      # +https://gateway.datagrout.ai/connect+ or a +.../servers/{uuid}/mcp+
      # URL.
      #
      # Tries RFC 9728 protected-resource metadata first, then RFC 8414
      # authorization-server metadata on whatever that names. Falls back to the
      # resource's own origin, which is where DataGrout serves it.
      def self.discover(resource_url)
        resource = resource_url.to_s.sub(%r{/+\z}, "")

        prm = AuthCode.fetch_resource_metadata(resource)
        servers = Array(prm && prm["authorization_servers"])
        issuer = servers.first
        if issuer.nil?
          # No PRM, or it named no servers: DataGrout serves AS metadata at the
          # origin, so try there before giving up.
          issuer = AuthCode.origin_of(resource)
          raise DiscoveryError, "not a URL: #{resource}" if issuer.nil?
        end

        metadata = AuthCode.fetch_server_metadata(issuer)
        raise PkceUnsupportedError unless metadata.supports_s256?

        new(metadata: metadata, resource: resource)
      end

      # Use a client id registered out of band, skipping dynamic registration.
      def with_client_id(client_id, redirect_uri)
        @client_id = client_id
        @redirect_uri = redirect_uri
        self
      end

      # Reuse a client registered on a previous run.
      #
      # Prefer this over {#with_client_id}: it carries the redirect URI with the
      # id, which is not optional bookkeeping — an authorization server matches
      # the redirect URI *exactly* against what was registered, so a client id
      # reused with a different URI is rejected.
      def with_registered_client(registered)
        with_client_id(registered.client_id, registered.redirect_uri)
      end

      # Request scopes other than {DEFAULT_SCOPE}.
      def with_scope(scope)
        @scope = scope
        self
      end

      # Register this application via RFC 7591 dynamic client registration.
      #
      # Registers a **public client** — +token_endpoint_auth_method: "none"+, no
      # secret issued. A desktop or CLI application cannot keep a secret, and
      # PKCE is what stands in for one.
      #
      # Returns a {RegisteredClient}: the id **and** the redirect URI it is
      # bound to. Persist the pair and restore it with
      # {#with_registered_client} — re-registering on every launch creates a new
      # client record each time, and reusing an id against a different redirect
      # URI is rejected.
      def register(client_name, redirect_uri)
        endpoint = @metadata.registration_endpoint
        raise NoRegistrationEndpointError unless endpoint

        body = {
          "client_name" => client_name,
          "redirect_uris" => [redirect_uri],
          "grant_types" => %w[authorization_code refresh_token],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "application_type" => "native"
        }

        response = AuthCode.post_json(endpoint, body)
        unless response.success?
          raise RegistrationRejectedError.new(status: response.status, body: response.body.to_s)
        end

        begin
          data = JSON.parse(response.body.to_s)
        rescue JSON::ParserError => e
          raise HttpError, "bad registration response: #{e.message}"
        end

        with_client_id(data["client_id"], redirect_uri)
        RegisteredClient.new(client_id: data["client_id"], redirect_uri: redirect_uri)
      end

      # Build the consent URL, plus the {PendingAuthorization} needed to redeem
      # the resulting code.
      #
      # The caller opens the URL however suits it — a browser, a printed
      # instruction, a QR code. This gem does not launch browsers.
      #
      # @return [Array(String, PendingAuthorization)]
      def authorize_url
        raise NoClientIdError unless @client_id && @redirect_uri

        code_verifier = AuthCode.generate_verifier
        state = AuthCode.generate_state

        query = {
          "response_type" => "code",
          "client_id" => @client_id,
          "redirect_uri" => @redirect_uri,
          "scope" => @scope,
          "state" => state,
          "code_challenge" => AuthCode.challenge_s256(code_verifier),
          "code_challenge_method" => "S256",
          # RFC 8707: bind the token to this resource so it cannot be replayed
          # against a different one.
          "resource" => @resource
        }.map { |k, v| "#{k}=#{AuthCode.urlencode(v)}" }.join("&")

        separator = @metadata.authorization_endpoint.include?("?") ? "&" : "?"
        url = "#{@metadata.authorization_endpoint}#{separator}#{query}"

        [url, PendingAuthorization.new(code_verifier: code_verifier, state: state,
                                       redirect_uri: @redirect_uri)]
      end

      # Redeem an authorization code for a {Grant}.
      #
      # +returned_state+ is the +state+ parameter from the redirect. It is
      # checked against the pending request before anything is sent: a mismatch
      # means the response belongs to a different authorization request, and the
      # exchange is refused rather than attempted.
      def exchange(pending, code, returned_state)
        raise StateMismatchError unless AuthCode.secure_compare(pending.state, returned_state)
        raise NoClientIdError unless @client_id

        token = AuthCode.post_form(
          @metadata.token_endpoint,
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => pending.redirect_uri,
          "client_id" => @client_id,
          "code_verifier" => pending.code_verifier,
          "resource" => @resource
        )

        Grant.new(
          access_token: token["access_token"],
          refresh_token: token["refresh_token"],
          expires_at: token["expires_in"] && AuthCode.now_secs + token["expires_in"].to_i,
          client_id: @client_id,
          token_endpoint: @metadata.token_endpoint,
          scope: token["scope"],
          resource: @resource
        )
      end
    end

    # ── Provider ─────────────────────────────────────────────────────────────

    # Holds a {Grant} and keeps its access token fresh.
    #
    # Mirrors {OAuth::TokenProvider} so both grant types reach the transports
    # through the same path — +get_token+ on the way out, +invalidate!+ on a
    # 401. Thread-safe via Mutex, as that one is.
    class Provider
      def initialize(grant)
        @grant = grant
        @dirty = false
        @mutex = Mutex.new
      end

      # The current access token, refreshing first if it is at or near expiry.
      def get_token
        @mutex.synchronize do
          unless @grant.expired?
            return @grant.access_token
          end

          @grant = @grant.refresh
          @dirty = true
          @grant.access_token
        end
      end

      # A snapshot of the current grant, for persisting.
      def grant
        @mutex.synchronize { @grant }
      end

      # Whether the grant changed since the last {#take_if_dirty}.
      def dirty?
        @mutex.synchronize { @dirty }
      end

      # Return the grant if it has changed since the last call, clearing the
      # flag.
      #
      # The intended use is a persistence loop: call periodically and write
      # whatever comes back, so a rotated refresh token is never lost.
      def take_if_dirty
        @mutex.synchronize do
          next nil unless @dirty

          @dirty = false
          @grant
        end
      end

      # Force the next {#get_token} to refresh. Call on a 401.
      def invalidate!
        @mutex.synchronize do
          # Expire in the past rather than clearing the token: the refresh token
          # is what matters, and dropping the grant would make recovery
          # impossible.
          @grant = Grant.new(
            access_token: @grant.access_token,
            refresh_token: @grant.refresh_token,
            expires_at: 0,
            client_id: @grant.client_id,
            token_endpoint: @grant.token_endpoint,
            scope: @grant.scope,
            resource: @grant.resource
          )
        end
      end

      # Build a provider from whatever an +auth:+ hash carried under
      # +:authorization_code+, or nil when it carried nothing.
      #
      # Accepts a {Provider} the caller keeps (so a rotated refresh token can be
      # written back), a {Grant}, or a grant hash straight from JSON.
      def self.from_auth(value)
        case value
        when nil then nil
        when Provider then value
        when Grant then new(value)
        when Hash then new(Grant.from_h(AuthCode.stringify_keys(value)))
        else
          raise ArgumentError,
                "authorization_code must be a Grant, a grant Hash, or an " \
                "AuthCode::Provider (got #{value.class})"
        end
      end
    end

    # ── PKCE and helpers ─────────────────────────────────────────────────────

    # Generate an RFC 7636 code verifier: 43 characters of base64url.
    def self.generate_verifier
      SecureRandom.urlsafe_base64(32, false)
    end

    # The S256 challenge for a verifier: +base64url(sha256(verifier))+.
    def self.challenge_s256(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    def self.generate_state
      SecureRandom.urlsafe_base64(16, false)
    end

    def self.now_secs
      Time.now.to_i
    end

    # Length-independent comparison, so a state check cannot be timed.
    def self.secure_compare(a, b)
      a = a.to_s.b
      b = b.to_s.b
      return false unless a.bytesize == b.bytesize

      a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
    end

    # Percent-encode a query parameter value.
    #
    # Unreserved set per RFC 3986. Everything else is escaped — including +/+
    # and +:+, which appear in redirect URIs and resource URLs and must not be
    # taken as structure by the authorization server. CGI.escape is wrong here:
    # it encodes a space as +++.
    def self.urlencode(value)
      value.to_s.b.each_byte.map do |byte|
        if (48..57).cover?(byte) || (65..90).cover?(byte) || (97..122).cover?(byte) ||
           [45, 46, 95, 126].include?(byte)
          byte.chr
        else
          format("%%%02X", byte)
        end
      end.join
    end

    # The scheme, host and port of a URL, with the path dropped.
    def self.origin_of(url)
      parsed = URI.parse(url.to_s)
      return nil unless parsed.scheme && parsed.host

      if parsed.port && parsed.port != parsed.default_port
        "#{parsed.scheme}://#{parsed.host}:#{parsed.port}"
      else
        "#{parsed.scheme}://#{parsed.host}"
      end
    rescue URI::InvalidURIError
      nil
    end

    # A Hash with symbol keys turned into strings, so a grant hash written in
    # either style loads.
    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

    # RFC 9728 protected-resource metadata, or nil if unavailable.
    def self.fetch_resource_metadata(resource)
      # Path-appended form first (what MCP servers with a path segment use),
      # then the origin-level one.
      candidates = ["#{resource}/.well-known/oauth-protected-resource"]
      origin = origin_of(resource)
      candidates << "#{origin}/.well-known/oauth-protected-resource" if origin

      candidates.each do |url|
        begin
          response = connection(url).get
        rescue Faraday::Error
          next
        end
        next unless response.success?

        begin
          body = JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          next
        end
        # A non-object body is not metadata; fall through to the next candidate
        # rather than handing the caller something unusable.
        return body if body.is_a?(Hash)
      end

      nil
    end

    def self.fetch_server_metadata(issuer)
      base = issuer.to_s.sub(%r{/+\z}, "")
      candidates = [
        "#{base}/.well-known/oauth-authorization-server",
        "#{base}/.well-known/openid-configuration"
      ]

      last = ""
      candidates.each do |url|
        begin
          response = connection(url).get
        rescue Faraday::Error => e
          last = "#{url} → #{e.message}"
          next
        end

        unless response.success?
          last = "#{url} → HTTP #{response.status}"
          next
        end

        begin
          return ServerMetadata.new(JSON.parse(response.body.to_s))
        rescue JSON::ParserError => e
          raise DiscoveryError, "bad metadata at #{url}: #{e.message}"
        end
      end

      raise DiscoveryError,
            "no authorization server metadata found (last attempt: #{last})"
    end

    def self.post_json(endpoint, body)
      connection(endpoint).post do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
    rescue Faraday::Error => e
      raise HttpError, "HTTP error: #{e.message}"
    end

    def self.post_form(endpoint, form)
      begin
        response = connection(endpoint) { |f| f.request :url_encoded }
                   .post { |req| req.body = form }
      rescue Faraday::Error => e
        raise HttpError, "HTTP error: #{e.message}"
      end

      unless response.success?
        raise TokenExchangeError.new(status: response.status, body: response.body.to_s)
      end

      begin
        parsed = JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise HttpError, "bad token response: #{e.message}"
      end

      unless parsed.is_a?(Hash)
        raise HttpError, "bad token response: expected a JSON object, got #{parsed.class}"
      end

      parsed
    end

    # A Faraday connection for one request. Overridden in tests.
    def self.connection(url)
      Faraday.new(url: url) do |f|
        yield f if block_given?
        f.adapter Faraday.default_adapter
      end
    end
  end
end
