# frozen_string_literal: true

require "json"
require "base64"
require "faraday"

require_relative "oauth"
require_relative "authcode"

module DatagroutConduit
  # RFC 8693 **delegation** — an agent acting *for* a user.
  #
  # The two grants this gem already speaks each answer one question. {OAuth}
  # (+client_credentials+) says *which machine* is calling; {AuthCode} says
  # *which person* consented. Neither says both, and an agent working on a
  # user's behalf needs to: the resource server has to know whose data it is
  # (+sub+) and who is actually holding the connection (+act+). An RFC 8693
  # exchange produces exactly that token, from two the caller already has.
  #
  # == Delegation, not impersonation
  #
  # RFC 8693 distinguishes the two. In **delegation** the issued token names the
  # user as +sub+ and the agent in an +act+ claim, so the resource server can
  # see — and audit, and rate-limit, and revoke — the agent separately from the
  # user. In **impersonation** the agent simply *becomes* the user, and the
  # resource server cannot tell the difference. DataGrout's authorization server
  # issues delegation tokens and requires an +actor_token+; this module
  # therefore **requires an actor by default** and refuses to build a request
  # without one. Impersonation is an explicit opt-in via
  # +impersonation: true+ on {Request}, for RFC 8693 servers that support it.
  #
  # == Wire contract
  #
  # +POST {token_endpoint}+, form-encoded, in this field order:
  #
  # * +grant_type+ — {GRANT_TYPE}
  # * +subject_token+, +subject_token_type+ — the user's token and its
  #   {TokenType} URN
  # * +actor_token+, +actor_token_type+ — the agent's token and URN, omitted
  #   only under +impersonation: true+
  # * +client_id+, +client_secret+ — client authentication, in the body by
  #   default (see {Request#client_auth})
  # * +audience+, +resource+, +scope+, +requested_token_type+ — as set
  #
  # +resource+ is RFC 8707 and, when set, is always sent — the same invariant
  # {AuthCode} keeps, so a delegated token cannot be replayed against a
  # different resource.
  #
  # **The client must be the actor.** The +client_id+ authenticating the request
  # and the principal behind +actor_token+ are expected to be the same agent.
  # This SDK does not verify that — it cannot, without decoding the actor token
  # — and the server enforces it (+unauthorized_client+ when they differ).
  #
  # The response is <tt>{access_token, issued_token_type, token_type,
  # expires_in?, scope?}</tt>; errors are RFC 6749 bodies
  # <tt>{error, error_description?}</tt>, with the codes listed in {Codes}.
  #
  # == Usage
  #
  #   # The agent's own credential — the actor.
  #   agent = DatagroutConduit::OAuth::TokenProvider.new(
  #     client_id: "agent_client_id",
  #     client_secret: "agent_client_secret",
  #     token_endpoint: "https://gateway.datagrout.ai/oauth/token"
  #   )
  #
  #   # The user's token — the subject. Here a token handed to the agent; a
  #   # long-lived app would use TokenSource.authorization_code(provider).
  #   user = DatagroutConduit::Delegation::TokenSource.static_token(user_token)
  #
  #   request = DatagroutConduit::Delegation::Request.new(
  #     token_endpoint: "https://gateway.datagrout.ai/oauth/token",
  #     client_id: "agent_client_id",
  #     client_secret: "agent_client_secret",
  #     resource: "https://gateway.datagrout.ai/connect"
  #   )
  #
  #   provider = DatagroutConduit::Delegation::Provider.new(
  #     request, subject: user, actor: DatagroutConduit::Delegation::TokenSource.client_credentials(agent)
  #   )
  #
  #   client = DatagroutConduit::Client.new(
  #     url: "https://gateway.datagrout.ai/connect", auth: { delegation: provider }
  #   )
  #
  # == Naming
  #
  # Elsewhere in this gem "token exchange" already means redeeming a
  # +client_credentials+ grant ({AuthCode::TokenExchangeError}, whose kind is
  # +:token_exchange+, and the onramp's +token_exchange+ stage). This module
  # says *delegation* and *exchange* — {Request#exchange}, {Token} — and never
  # reuses that label, so a log line cannot be read two ways. Ports of this
  # feature must keep the same discipline.
  module Delegation
    # The RFC 8693 grant type.
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"

    # Re-exchange this many seconds before the delegated token actually
    # expires. The same buffer {OAuth} and {AuthCode} use, so all three
    # providers behave alike under a clock skew.
    REFRESH_SKEW_SECONDS = 60

    # RFC 6749 error codes a token endpoint returns for an exchange, as
    # {ServerError#error}.
    #
    # Listed so callers and ports compare against a name rather than a string
    # they typed. +invalid_target+ is the one specific to RFC 8693: the
    # +audience+ or +resource+ is not one this server issues tokens for.
    module Codes
      # Malformed request, or a required parameter missing.
      INVALID_REQUEST = "invalid_request"
      # Client authentication failed.
      INVALID_CLIENT = "invalid_client"
      # The subject or actor token is invalid, expired, or revoked.
      INVALID_GRANT = "invalid_grant"
      # This client may not use this grant — including a client that is not
      # the actor.
      UNAUTHORIZED_CLIENT = "unauthorized_client"
      # The requested +audience+ or +resource+ is not served here
      # (RFC 8693 §2.2.2).
      INVALID_TARGET = "invalid_target"
      # A requested scope is unknown or exceeds what the subject token allows.
      INVALID_SCOPE = "invalid_scope"
      # The server does not support token exchange.
      UNSUPPORTED_GRANT_TYPE = "unsupported_grant_type"

      # Every code, for the contract test.
      ALL = [
        INVALID_REQUEST,
        INVALID_CLIENT,
        INVALID_GRANT,
        UNAUTHORIZED_CLIENT,
        INVALID_TARGET,
        INVALID_SCOPE,
        UNSUPPORTED_GRANT_TYPE
      ].freeze
    end

    # How the client authenticates to the token endpoint.
    #
    # +:body+ sends +client_id+ and +client_secret+ as form fields (RFC 6749
    # §2.3.1 +client_secret_post+) and is the default, and what DataGrout
    # expects. +:basic+ sends <tt>Authorization: Basic
    # base64(client_id:client_secret)</tt> (+client_secret_basic+);
    # +client_id+ still travels in the body, as RFC 6749 permits and some
    # servers require.
    CLIENT_AUTH_MODES = %i[body basic].freeze

    # ── Errors ───────────────────────────────────────────────────────────────
    #
    # The taxonomy is part of the cross-language contract: every conduit SDK
    # distinguishes these same cases under the same {Error#kind} names. Ruby
    # callers branch by rescuing a subclass; +kind+ gives the same distinction
    # as a symbol, and its name is the one the other SDKs use.

    # Base class for every delegation failure.
    class Error < DatagroutConduit::AuthError
      # @return [Symbol] the cross-language error kind
      attr_reader :kind
      # @return [Integer, nil] HTTP status, when the failure came from a response
      attr_reader :status
      # @return [String, nil] RFC 6749 error code; see {Codes}
      attr_reader :error
      # @return [String, nil] human-readable description, when the server gave one
      attr_reader :error_description

      def initialize(message, kind: :http, status: nil, error: nil, error_description: nil)
        @kind = kind
        @status = status
        @error = error
        @error_description = error_description
        super(message)
      end
    end

    # No subject token was set — there is nobody to act for.
    class MissingSubjectError < Error
      def initialize(_message = nil)
        super(
          "no subject_token — set subject_token: on the request first",
          kind: :missing_subject
        )
      end
    end

    # No actor token was set and the request is not an impersonation.
    #
    # Delegation is the default because it is what DataGrout requires and what
    # leaves an audit trail. If the server really is meant to issue a token
    # with no +act+ claim, say so with +impersonation: true+.
    class MissingActorError < Error
      def initialize(_message = nil)
        super(
          "no actor_token — delegation requires one; pass impersonation: true " \
          "to opt out explicitly",
          kind: :missing_actor
        )
      end
    end

    # Transport failure talking to the token endpoint.
    class HttpError < Error
      def initialize(message)
        super(message, kind: :http)
      end
    end

    # The token endpoint refused, with an RFC 6749 error body.
    class ServerError < Error
      def initialize(status:, error:, error_description: nil)
        message = "delegation exchange refused (HTTP #{status}): #{error}"
        message += " — #{error_description}" if error_description
        super(message, kind: :server, status: status, error: error,
                       error_description: error_description)
      end
    end

    # The endpoint answered with something that is not an exchange response — a
    # success body missing required fields, or a failure whose body is not an
    # RFC 6749 error.
    class InvalidResponseError < Error
      def initialize(message)
        super("invalid delegation response: #{message}", kind: :invalid_response)
      end
    end

    # ── Token types ──────────────────────────────────────────────────────────

    # An RFC 8693 §3 token type identifier.
    #
    # Immutable, and compares and serializes as its URN, so the wire shape is
    # the same string in every language. A URN this gem does not name is
    # carried through unchanged rather than rejected — {#name} answers
    # +:other+ for it.
    class TokenType
      ACCESS_TOKEN_URN  = "urn:ietf:params:oauth:token-type:access_token"
      JWT_URN           = "urn:ietf:params:oauth:token-type:jwt"
      ID_TOKEN_URN      = "urn:ietf:params:oauth:token-type:id_token"
      REFRESH_TOKEN_URN = "urn:ietf:params:oauth:token-type:refresh_token"
      SAML2_URN         = "urn:ietf:params:oauth:token-type:saml2"

      # The types this gem names, by short name.
      NAMED = {
        access_token: ACCESS_TOKEN_URN,
        jwt: JWT_URN,
        id_token: ID_TOKEN_URN,
        refresh_token: REFRESH_TOKEN_URN,
        saml2: SAML2_URN
      }.freeze

      # @return [String] the URN sent on the wire
      attr_reader :urn

      def initialize(urn)
        @urn = urn.to_s
        raise ArgumentError, "a token type URN cannot be empty" if @urn.empty?

        freeze
      end

      # Parse a URN. An unnamed value is kept as-is.
      def self.from_urn(urn)
        new(urn)
      end

      # Accept a {TokenType}, a URN string, or a short name symbol.
      #
      # Lets a caller write +subject_token_type: :jwt+ without reaching for a
      # constant, which is what Ruby callers expect.
      def self.coerce(value)
        case value
        when TokenType then value
        when Symbol then new(NAMED.fetch(value) { raise ArgumentError, "unknown token type #{value.inspect}" })
        when String then new(value)
        else
          raise ArgumentError,
                "token type must be a TokenType, a URN String, or a Symbol (got #{value.class})"
        end
      end

      # @return [Symbol] the short name, or +:other+ for a URN this gem does
      #   not name
      def name
        NAMED.key(@urn) || :other
      end

      def to_s
        @urn
      end

      def inspect
        "#<DatagroutConduit::Delegation::TokenType #{@urn}>"
      end

      def ==(other)
        other.is_a?(TokenType) && other.urn == @urn
      end
      alias eql? ==

      def hash
        @urn.hash
      end

      ACCESS_TOKEN  = new(ACCESS_TOKEN_URN)
      JWT           = new(JWT_URN)
      ID_TOKEN      = new(ID_TOKEN_URN)
      REFRESH_TOKEN = new(REFRESH_TOKEN_URN)
      SAML2         = new(SAML2_URN)
    end

    # ── Token ────────────────────────────────────────────────────────────────

    # A token issued by an exchange.
    #
    # The serialized shape is part of the cross-language contract, and is what
    # +testdata/contract.json+ pins: +access_token+, +issued_token_type+ (a URN
    # string), +token_type+, +expires_at?+, +scope?+. As with {AuthCode::Grant},
    # +expires_at+ is **Unix seconds** — computed from the server's relative
    # +expires_in+ at receipt — never a monotonic reading, so the token means
    # the same thing once written down.
    class Token
      # @return [String] the bearer token to present
      attr_reader :access_token
      # @return [TokenType] what kind of token was issued
      attr_reader :issued_token_type
      # @return [String] how to present it — +Bearer+, in practice
      attr_reader :token_type
      # @return [Integer, nil] absolute expiry, Unix seconds; nil means the
      #   server did not say
      attr_reader :expires_at
      # @return [String, nil] granted scopes, when the server reported them
      attr_reader :scope

      def initialize(access_token:, issued_token_type:, token_type:,
                     expires_at: nil, scope: nil)
        @access_token = access_token
        @issued_token_type = TokenType.coerce(issued_token_type)
        @token_type = token_type
        @expires_at = expires_at && expires_at.to_i
        @scope = scope
      end

      # The cross-language wire shape. Absent optionals are omitted rather than
      # written as nulls, so a token round-trips through any of the SDKs.
      def to_h
        h = {
          "access_token" => @access_token,
          "issued_token_type" => @issued_token_type.urn,
          "token_type" => @token_type
        }
        h["expires_at"] = @expires_at if @expires_at
        h["scope"] = @scope if @scope
        h
      end

      # Load a persisted token (absolute +expires_at+).
      def self.from_h(data)
        data = Delegation.stringify_keys(data)
        new(
          access_token: required(data, "access_token"),
          issued_token_type: required(data, "issued_token_type"),
          token_type: required(data, "token_type"),
          expires_at: data["expires_at"],
          scope: data["scope"]
        )
      end

      # Load an RFC 8693 §2.2.1 success response (relative +expires_in+),
      # converting it to an absolute expiry at receipt.
      #
      # +issued_token_type+ and +token_type+ are REQUIRED by the RFC; a server
      # that drops either is out of contract, and guessing would hide that.
      def self.from_wire(data)
        data = Delegation.stringify_keys(data)
        expires_in = data["expires_in"]
        new(
          access_token: required(data, "access_token"),
          issued_token_type: required(data, "issued_token_type"),
          token_type: required(data, "token_type"),
          expires_at: expires_in && Delegation.now_secs + expires_in.to_i,
          scope: data["scope"]
        )
      end

      # True when the token is expired, or within {REFRESH_SKEW_SECONDS} of it.
      #
      # A token with no stated expiry is treated as live: the server chose not
      # to say, and guessing would throw away working tokens.
      def expired?
        return false if @expires_at.nil?

        Delegation.now_secs + REFRESH_SKEW_SECONDS >= @expires_at
      end

      def ==(other)
        other.is_a?(Token) && to_h == other.to_h
      end

      # Never print the token itself.
      def inspect
        "#<DatagroutConduit::Delegation::Token issued_token_type=#{@issued_token_type.urn} " \
          "token_type=#{@token_type.inspect} expires_at=#{@expires_at.inspect} " \
          "scope=#{@scope.inspect}>"
      end

      # @api private
      def self.required(data, key)
        value = data[key]
        raise InvalidResponseError, "missing #{key}" if value.nil? || value.to_s.empty?

        value
      end
      private_class_method :required
    end

    # ── Request ──────────────────────────────────────────────────────────────

    # An exchange request, built and then {#exchange}d.
    #
    # Immutable: {#with} returns a copy, which is how a {Provider} holds one as
    # a template and fills in fresh subject and actor tokens on each
    # re-exchange.
    class Request
      # @return [String] the token endpoint this request posts to
      attr_reader :token_endpoint
      # @return [String] the client id this request authenticates as
      attr_reader :client_id
      # @return [Symbol] +:body+ or +:basic+; see {CLIENT_AUTH_MODES}
      attr_reader :client_auth
      # @return [TokenType]
      attr_reader :subject_token_type, :actor_token_type
      # @return [String, nil]
      attr_reader :audience, :resource, :scope
      # @return [TokenType, nil]
      attr_reader :requested_token_type

      # +token_endpoint+ and +client_id+ are required; everything else is
      # optional. The client should be the actor — see the module docs.
      #
      # Pass +impersonation: true+ to opt out of delegation: send no
      # +actor_token+, so the issued token has no +act+ claim and the agent is
      # indistinguishable from the user. DataGrout does not issue these. It is
      # an explicit flag rather than a default precisely so that forgetting to
      # set an actor is an error instead of a silent downgrade.
      def initialize(token_endpoint:, client_id:,
                     client_secret: nil, client_auth: :body,
                     subject_token: nil, subject_token_type: TokenType::ACCESS_TOKEN,
                     actor_token: nil, actor_token_type: TokenType::ACCESS_TOKEN,
                     audience: nil, resource: nil, scope: nil,
                     requested_token_type: nil, impersonation: false)
        raise ArgumentError, "token_endpoint is required" if token_endpoint.to_s.empty?
        raise ArgumentError, "client_id is required" if client_id.to_s.empty?

        client_auth = client_auth.to_sym
        unless CLIENT_AUTH_MODES.include?(client_auth)
          raise ArgumentError,
                "client_auth must be one of #{CLIENT_AUTH_MODES.inspect} (got #{client_auth.inspect})"
        end

        @token_endpoint = token_endpoint
        @client_id = client_id
        @client_secret = client_secret
        @client_auth = client_auth
        @subject_token = subject_token
        @subject_token_type = TokenType.coerce(subject_token_type)
        @actor_token = actor_token
        @actor_token_type = TokenType.coerce(actor_token_type)
        @audience = audience
        @resource = resource
        @scope = scope
        @requested_token_type = requested_token_type && TokenType.coerce(requested_token_type)
        @impersonation = !impersonation.nil? && impersonation != false
      end

      # Whether this request opted out of delegation.
      def impersonation?
        @impersonation
      end

      # A copy with some fields replaced.
      #
      #   request.with(subject_token: fresh, subject_token_type: :jwt)
      def with(overrides = {})
        Request.new(**to_options.merge(overrides))
      end

      # The form body this request will post, in wire order.
      #
      # Raises before any network activity when the request is incomplete:
      # {MissingSubjectError}, or {MissingActorError} unless
      # +impersonation: true+. Public so a caller — or another SDK's test
      # suite — can check the body against the contract fixture without a
      # server.
      #
      # @return [Array<Array(String, String)>] key/value pairs, ordered
      def form_params
        raise MissingSubjectError if @subject_token.to_s.empty?

        form = [
          ["grant_type", GRANT_TYPE],
          ["subject_token", @subject_token],
          ["subject_token_type", @subject_token_type.urn]
        ]

        if @actor_token.to_s.empty?
          raise MissingActorError unless @impersonation
        else
          form << ["actor_token", @actor_token]
          form << ["actor_token_type", @actor_token_type.urn]
        end

        form << ["client_id", @client_id]
        form << ["client_secret", @client_secret] if @client_secret && @client_auth == :body

        form << ["audience", @audience] if @audience
        form << ["resource", @resource] if @resource
        form << ["scope", @scope] if @scope
        form << ["requested_token_type", @requested_token_type.urn] if @requested_token_type

        form
      end

      # Perform the exchange.
      #
      # @return [Token]
      def exchange
        body = Delegation.encode_form(form_params)

        begin
          response = Delegation.connection(@token_endpoint).post do |req|
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.headers["Accept"] = "application/json"
            req.headers["Authorization"] = basic_authorization if basic_auth?
            req.body = body
          end
        rescue Faraday::Error => e
          raise HttpError, "HTTP error: #{e.message}"
        end

        unless response.success?
          raise Delegation.error_for(response.status, response.body.to_s)
        end

        Delegation.parse_wire_response(response.status, response.body)
      end

      # Never print the secret or either token.
      def inspect
        "#<DatagroutConduit::Delegation::Request token_endpoint=#{@token_endpoint.inspect} " \
          "client_id=#{@client_id.inspect} client_auth=#{@client_auth.inspect} " \
          "audience=#{@audience.inspect} resource=#{@resource.inspect} " \
          "scope=#{@scope.inspect} impersonation=#{@impersonation}>"
      end

      private

      def basic_auth?
        @client_auth == :basic && !@client_secret.nil?
      end

      def basic_authorization
        "Basic #{Base64.strict_encode64("#{@client_id}:#{@client_secret}")}"
      end

      def to_options
        {
          token_endpoint: @token_endpoint,
          client_id: @client_id,
          client_secret: @client_secret,
          client_auth: @client_auth,
          subject_token: @subject_token,
          subject_token_type: @subject_token_type,
          actor_token: @actor_token,
          actor_token_type: @actor_token_type,
          audience: @audience,
          resource: @resource,
          scope: @scope,
          requested_token_type: @requested_token_type,
          impersonation: @impersonation
        }
      end
    end

    # ── Token sources ────────────────────────────────────────────────────────

    # Where a {Provider} gets a subject or actor token from, and what
    # {TokenType} to declare it as.
    #
    # A source is consulted on **every** exchange, so a provider-backed source
    # hands over a *fresh* token each time — the whole point of wrapping a
    # provider rather than copying its current token out.
    class TokenSource
      # @return [Symbol] +:static+, +:client_credentials+,
      #   +:authorization_code+ or +:callable+
      attr_reader :kind
      # @return [TokenType] the declared token type
      attr_reader :token_type

      # Prefer the factory methods; this is the shared shape behind them.
      def initialize(kind:, token_type: TokenType::ACCESS_TOKEN,
                     token: nil, provider: nil, resolver: nil)
        @kind = kind
        @token_type = TokenType.coerce(token_type)
        @token = token
        @provider = provider
        @resolver = resolver
      end

      # A fixed token, e.g. one handed to the agent for this run.
      def self.static_token(token, token_type: TokenType::ACCESS_TOKEN)
        new(kind: :static, token: token, token_type: token_type)
      end

      # The agent's own +client_credentials+ provider — the usual **actor**.
      def self.client_credentials(provider, token_type: TokenType::ACCESS_TOKEN)
        new(kind: :client_credentials, provider: provider, token_type: token_type)
      end

      # A user's authorization-code provider — the usual **subject** in an app
      # that signed the user in itself. Refreshes its grant as needed, so the
      # exchange always sees a live subject token.
      #
      # Accepts an {AuthCode::Provider}, an {AuthCode::Grant}, or a grant hash
      # straight from JSON.
      def self.authorization_code(provider, token_type: TokenType::ACCESS_TOKEN)
        new(kind: :authorization_code,
            provider: AuthCode::Provider.from_auth(provider),
            token_type: token_type)
      end

      # Any callable that yields a token — a vault lookup, a header from an
      # inbound request, another SDK's provider.
      #
      #   TokenSource.callable(token_type: :jwt) { vault.read("user/token") }
      def self.callable(token_type: TokenType::ACCESS_TOKEN, &block)
        raise ArgumentError, "a callable token source needs a block" unless block

        new(kind: :callable, resolver: block, token_type: token_type)
      end

      class << self
        alias dynamic callable
      end

      # A copy declaring a different {TokenType}.
      def with_token_type(token_type)
        TokenSource.new(kind: @kind, token_type: token_type, token: @token,
                        provider: @provider, resolver: @resolver)
      end

      # Resolve a token. Called on every exchange.
      #
      # @return [String]
      def resolve
        token =
          case @kind
          when :static then @token
          when :client_credentials, :authorization_code then @provider.get_token
          when :callable then @resolver.call
          else raise ArgumentError, "unknown token source #{@kind.inspect}"
          end

        # A nil or empty upstream token would otherwise be posted as an empty
        # form field and come back as an opaque invalid_grant.
        raise HttpError, "the #{@kind} token source produced no token" if token.to_s.empty?

        token.to_s
      end

      # Never print the token.
      def inspect
        "#<DatagroutConduit::Delegation::TokenSource kind=#{@kind.inspect} " \
          "token_type=#{@token_type.urn}>"
      end
    end

    # ── Provider ─────────────────────────────────────────────────────────────

    # Keeps a delegated token fresh, re-exchanging when it nears expiry.
    #
    # The third token provider in this gem, shaped like the other two —
    # {OAuth::TokenProvider} and {AuthCode::Provider} — so every transport
    # reaches it through the same path: +get_token+ on the way out,
    # +invalidate!+ on a 401. Each exchange pulls a fresh subject and actor
    # token from its {TokenSource}s, so an expiring upstream credential is
    # handled by the provider that owns it.
    class Provider
      # @return [Request] the request template, without tokens
      attr_reader :request

      # Wrap a request template with the sources of its two tokens.
      #
      # Any +subject_token+ or +actor_token+ already on +request+ is ignored;
      # the sources supply them. Pass +actor: nil+ only with a request built
      # with +impersonation: true+ — otherwise every {#get_token} raises
      # {MissingActorError}, which is the intended loud failure rather than a
      # silent downgrade.
      def initialize(request, subject:, actor: nil)
        @request = request
        @subject = subject
        @actor = actor
        # Two locks with distinct jobs, as in AuthCode::Provider. @mutex guards
        # the cache and is held only long enough to read or swap it — never
        # across the network. @exchange_mutex serializes the exchange itself,
        # so concurrent callers make one request rather than a stampede.
        @mutex = Mutex.new
        @exchange_mutex = Mutex.new
        @cached = nil
      end

      # The current delegated bearer, exchanging first if there is none or it
      # is at or near expiry.
      def get_token
        live = live_access_token
        return live if live

        # One exchange at a time. Waiters re-check on entry, so a leader that
        # succeeded spares them the request entirely.
        @exchange_mutex.synchronize do
          live = live_access_token
          return live if live

          token = perform_exchange
          @mutex.synchronize { @cached = token }
          token.access_token
        end
      end

      # Force the next {#get_token} to exchange again. Call on a 401.
      #
      # Only the delegated token is dropped. The subject and actor sources are
      # left alone: a provider-backed source tracks its own expiry, and a 401
      # from the resource server says nothing about them.
      def invalidate!
        @mutex.synchronize { @cached = nil }
      end

      # A snapshot of the cached token, if any — for inspection or logging.
      #
      # @return [Token, nil]
      def token
        @mutex.synchronize { @cached }
      end

      # Build a provider from whatever an +auth:+ hash carried under
      # +:delegation+, or nil when it carried nothing.
      #
      # Only a {Provider} is accepted: a delegation needs live token sources,
      # which a serialized blob cannot carry.
      def self.from_auth(value)
        case value
        when nil then nil
        when Provider then value
        else
          raise ArgumentError,
                "delegation must be a Delegation::Provider (got #{value.class})"
        end
      end

      # Never print tokens — the request template carries the client secret.
      def inspect
        "#<DatagroutConduit::Delegation::Provider " \
          "token_endpoint=#{@request.token_endpoint.inspect} " \
          "client_id=#{@request.client_id.inspect} " \
          "subject=#{@subject.kind.inspect} actor=#{@actor && @actor.kind.inspect}>"
      end

      private

      def live_access_token
        cached = @mutex.synchronize { @cached }
        return nil if cached.nil? || cached.expired?

        cached.access_token
      end

      # Runs with @exchange_mutex held and @mutex free, so {#token} and
      # {#invalidate!} keep answering while a request is in flight.
      def perform_exchange
        # Refuse before resolving anything: a missing actor is a configuration
        # mistake, and fetching a subject token first would only hide it.
        raise MissingActorError if @actor.nil? && !@request.impersonation?

        request = @request.with(
          subject_token: @subject.resolve,
          subject_token_type: @subject.token_type
        )

        if @actor
          request = request.with(
            actor_token: @actor.resolve,
            actor_token_type: @actor.token_type
          )
        end

        request.exchange
      end
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def self.now_secs
      Time.now.to_i
    end

    # Encode ordered key/value pairs as an +application/x-www-form-urlencoded+
    # body.
    #
    # Built here rather than handed to Faraday's +url_encoded+ middleware
    # because that takes a Hash and this body's **field order** is part of the
    # contract.
    def self.encode_form(pairs)
      pairs.map { |key, value| "#{AuthCode.urlencode(key)}=#{AuthCode.urlencode(value)}" }
           .join("&")
    end

    # A non-2xx body is an RFC 6749 error when it carries a string +error+;
    # anything else — a proxy's HTML, an empty body — is reported as an invalid
    # response with the status, since it did not come from the token endpoint's
    # contract.
    def self.error_for(status, body)
      data = begin
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end

      if data.is_a?(Hash) && data["error"].is_a?(String)
        ServerError.new(status: status, error: data["error"],
                        error_description: data["error_description"])
      else
        InvalidResponseError.new(
          "HTTP #{status} with a non-OAuth body: #{body.to_s[0, 200]}"
        )
      end
    end

    # Parse a 2xx body into a {Token}. Faraday may already have decoded it.
    def self.parse_wire_response(status, body)
      data =
        if body.is_a?(Hash)
          body
        else
          begin
            JSON.parse(body.to_s)
          rescue JSON::ParserError => e
            raise InvalidResponseError, "HTTP #{status}: #{e.message}"
          end
        end

      unless data.is_a?(Hash)
        raise InvalidResponseError, "HTTP #{status}: expected a JSON object, got #{data.class}"
      end

      Token.from_wire(data)
    end

    # A Hash with symbol keys turned into strings, so a token hash written in
    # either style loads.
    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

    # A Faraday connection for one request. Overridden in tests.
    def self.connection(url)
      Faraday.new(url: url) do |f|
        f.adapter Faraday.default_adapter
      end
    end
  end
end
