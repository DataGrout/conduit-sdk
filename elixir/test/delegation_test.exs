defmodule DatagroutConduit.DelegationTest.FakeOAuth do
  @moduledoc """
  A stand-in for `DatagroutConduit.OAuth` that answers the same two messages
  without going near the network — that module fetches over Req with no test
  plug, so a real one would reach out. It hands out a new token each time it is
  invalidated, so a re-exchange can be told apart from the first attempt.
  """

  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, 1}

  @impl true
  def handle_call(:get_token, _from, n), do: {:reply, {:ok, "agent_live_#{n}"}, n}

  @impl true
  def handle_cast(:invalidate, n), do: {:noreply, n + 1}
end

defmodule DatagroutConduit.DelegationTest do
  @moduledoc """
  RFC 8693 delegation: the request it builds, the token it parses, and the
  provider that keeps one fresh.

  Mirrors the Rust reference suite in `rust/src/delegation.rs`, which is the
  spec for this feature.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.Delegation
  alias DatagroutConduit.Delegation.{Error, Provider, Token, TokenSource, TokenType}
  alias DatagroutConduit.DelegationTest.FakeOAuth

  @endpoint "https://as.example.com/oauth/token"

  @access_token_urn "urn:ietf:params:oauth:token-type:access_token"
  @jwt_urn "urn:ietf:params:oauth:token-type:jwt"

  @success_body %{
    "access_token" => "delegated_at",
    "issued_token_type" => @access_token_urn,
    "token_type" => "Bearer",
    "expires_in" => 900,
    "scope" => "mcp tools"
  }

  defp a_request do
    Delegation.new(@endpoint, "agent_client")
    |> Delegation.client_secret("agent_secret")
    |> Delegation.subject_token("user_at", :access_token)
    |> Delegation.actor_token("agent_at", :access_token)
  end

  defp form!(request) do
    {:ok, form} = Delegation.form_params(request)
    form
  end

  # Count what actually reached the endpoint, so "refused before any HTTP" can
  # be asserted rather than assumed.
  defp counting_stub(body \\ @success_body) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Req.Test.stub(Delegation, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      Agent.update(agent, &(&1 ++ [raw]))
      Req.Test.json(conn, body)
    end)

    agent
  end

  describe "token types" do
    test "round-trip through their URNs" do
      for name <- Map.keys(TokenType.urns()) do
        urn = TokenType.to_urn(name)
        assert String.starts_with?(urn, "urn:ietf:params:oauth:token-type:")
        assert TokenType.from_urn(urn) == name
      end
    end

    test "an unknown URN round-trips as :other rather than failing" do
      assert TokenType.from_urn("urn:example:custom") == {:other, "urn:example:custom"}
      assert TokenType.to_urn({:other, "urn:example:custom"}) == "urn:example:custom"
    end

    test "the five the RFC names are the five this SDK names" do
      assert Map.keys(TokenType.urns()) |> Enum.sort() ==
               [:access_token, :id_token, :jwt, :refresh_token, :saml2]
    end
  end

  describe "the grant" do
    test "is the RFC 8693 token-exchange grant type" do
      assert Delegation.grant_type() == "urn:ietf:params:oauth:grant-type:token-exchange"
    end

    test "names the RFC 6749 server error codes, including RFC 8693's invalid_target" do
      assert "invalid_target" in Delegation.server_error_codes()
      assert length(Delegation.server_error_codes()) == 7
    end
  end

  describe "the form body" do
    test "carries exactly the expected fields in wire order" do
      form =
        a_request()
        |> Delegation.audience("https://gateway.example.com")
        |> Delegation.resource("https://gateway.example.com/connect")
        |> Delegation.scope("mcp tools")
        |> Delegation.requested_token_type(:access_token)
        |> form!()

      assert form == [
               {"grant_type", Delegation.grant_type()},
               {"subject_token", "user_at"},
               {"subject_token_type", @access_token_urn},
               {"actor_token", "agent_at"},
               {"actor_token_type", @access_token_urn},
               {"client_id", "agent_client"},
               {"client_secret", "agent_secret"},
               {"audience", "https://gateway.example.com"},
               {"resource", "https://gateway.example.com/connect"},
               {"scope", "mcp tools"},
               {"requested_token_type", @access_token_urn}
             ]
    end

    test "omits optionals that were not set" do
      keys = a_request() |> form!() |> Enum.map(&elem(&1, 0))

      for absent <- ["audience", "resource", "scope", "requested_token_type"] do
        refute absent in keys, "#{absent} should not be sent"
      end
    end

    test "sends resource whenever it is set" do
      # RFC 8707 — the same invariant the authorization-code module keeps.
      form = a_request() |> Delegation.resource("https://gateway.example.com/connect") |> form!()
      assert {"resource", "https://gateway.example.com/connect"} in form
    end

    test "keeps the secret out of the body under basic client auth" do
      form = a_request() |> Delegation.client_auth(:basic) |> form!()
      refute Enum.any?(form, fn {key, _} -> key == "client_secret" end)
      # client_id still travels in the body.
      assert {"client_id", "agent_client"} in form
    end

    test "accepts a JWT subject" do
      form =
        Delegation.new(@endpoint, "c")
        |> Delegation.subject_token("eyJ", :jwt)
        |> Delegation.actor_token("agent_at", :access_token)
        |> form!()

      assert {"subject_token_type", @jwt_urn} in form
    end
  end

  describe "refusals before any HTTP" do
    test "a missing actor is refused before any request is sent" do
      agent = counting_stub()

      assert {:error, %Error{kind: :missing_actor} = error} =
               Delegation.new(@endpoint, "c")
               |> Delegation.subject_token("user_at", :access_token)
               |> Delegation.exchange()

      assert error.message =~ "impersonation"
      assert Agent.get(agent, & &1) == []
    end

    test "a missing subject is refused before any request is sent" do
      agent = counting_stub()

      assert {:error, %Error{kind: :missing_subject}} =
               Delegation.new(@endpoint, "c")
               |> Delegation.actor_token("agent_at", :access_token)
               |> Delegation.exchange()

      assert Agent.get(agent, & &1) == []
    end

    test "impersonation is the only way to omit the actor" do
      form =
        Delegation.new(@endpoint, "c")
        |> Delegation.subject_token("user_at", :access_token)
        |> Delegation.impersonation()
        |> form!()

      refute Enum.any?(form, fn {key, _} -> String.starts_with?(key, "actor_token") end)
      assert Delegation.impersonation?(Delegation.impersonation(a_request()))
      refute Delegation.impersonation?(a_request())
    end
  end

  describe "the wire" do
    test "posts a form-encoded body, actor fields and all, in order" do
      agent = counting_stub()

      assert {:ok, %Token{access_token: "delegated_at"}} =
               a_request()
               |> Delegation.resource("https://gateway.example.com/connect")
               |> Delegation.exchange()

      expected =
        URI.encode_query([
          {"grant_type", Delegation.grant_type()},
          {"subject_token", "user_at"},
          {"subject_token_type", @access_token_urn},
          {"actor_token", "agent_at"},
          {"actor_token_type", @access_token_urn},
          {"client_id", "agent_client"},
          {"client_secret", "agent_secret"},
          {"resource", "https://gateway.example.com/connect"}
        ])

      assert Agent.get(agent, & &1) == [expected]
    end

    test "sends the secret as a Basic header, not a form field, when asked" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Req.Test.stub(Delegation, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        header = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        Agent.update(agent, &(&1 ++ [{header, raw}]))
        Req.Test.json(conn, @success_body)
      end)

      assert {:ok, _} = a_request() |> Delegation.client_auth(:basic) |> Delegation.exchange()

      expected = "Basic " <> Base.encode64("agent_client:agent_secret")
      assert [{^expected, raw}] = Agent.get(agent, & &1)
      refute raw =~ "agent_secret"
    end

    test "a success response becomes a token with an absolute expiry" do
      counting_stub()

      before = System.os_time(:second)
      assert {:ok, token} = Delegation.exchange(a_request())
      later = System.os_time(:second)

      assert token.access_token == "delegated_at"
      assert token.issued_token_type == :access_token
      assert token.token_type == "Bearer"
      assert token.scope == "mcp tools"

      # expires_at = now + expires_in, in Unix seconds, allowing for the clock
      # ticking during the request.
      assert token.expires_at >= before + 900
      assert token.expires_at <= later + 900
      refute Token.expired?(token)
    end

    test "an RFC 6749 error body is a server error with code and status" do
      Req.Test.stub(Delegation, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          ~s({"error":"invalid_target","error_description":"unknown resource"})
        )
      end)

      assert {:error, %Error{kind: :server} = error} = Delegation.exchange(a_request())
      assert error.status == 400
      assert error.error == "invalid_target"
      assert error.error in Delegation.server_error_codes()
      assert error.error_description == "unknown resource"
      assert error.message =~ "unknown resource"
    end

    test "a failure without an OAuth body is an invalid response" do
      Req.Test.stub(Delegation, fn conn ->
        Plug.Conn.send_resp(conn, 502, "<html>bad gateway</html>")
      end)

      assert {:error, %Error{kind: :invalid_response} = error} = Delegation.exchange(a_request())
      assert error.message =~ "502"
    end

    test "a 2xx missing issued_token_type is an invalid response" do
      # RFC 8693 §2.2.1 makes the field REQUIRED; a server that drops it is out
      # of contract, and guessing would hide that.
      Req.Test.stub(Delegation, fn conn ->
        Req.Test.json(conn, %{"access_token" => "x", "token_type" => "Bearer"})
      end)

      assert {:error, %Error{kind: :invalid_response} = error} = Delegation.exchange(a_request())
      assert error.message =~ "issued_token_type"
    end

    test "a 2xx missing token_type is an invalid response" do
      Req.Test.stub(Delegation, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "x",
          "issued_token_type" => @access_token_urn
        })
      end)

      assert {:error, %Error{kind: :invalid_response} = error} = Delegation.exchange(a_request())
      assert error.message =~ "token_type"
    end

    test "a 2xx that is not a JSON object is an invalid response" do
      Req.Test.stub(Delegation, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)

      assert {:error, %Error{kind: :invalid_response}} = Delegation.exchange(a_request())
    end

    test "an unreachable endpoint is an HTTP error" do
      Req.Test.stub(Delegation, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Error{kind: :http}} = Delegation.exchange(a_request())
    end
  end

  describe "the issued token" do
    defp a_token(expires_at) do
      %Token{
        access_token: "delegated_at",
        issued_token_type: :access_token,
        token_type: "Bearer",
        expires_at: expires_at,
        scope: nil
      }
    end

    test "with no stated expiry is not expired" do
      refute Token.expired?(a_token(nil))
    end

    test "expires early by the refresh skew" do
      assert Delegation.refresh_skew_secs() == 60
      assert Token.expired?(a_token(System.os_time(:second) + 30))
      refute Token.expired?(a_token(System.os_time(:second) + 600))
    end

    test "omits absent optionals when serialized" do
      map = a_token(nil) |> Token.to_map()
      refute Map.has_key?(map, "expires_at")
      refute Map.has_key?(map, "scope")
      assert map["issued_token_type"] == @access_token_urn
    end

    test "round-trips through its wire shape" do
      token = a_token(1_700_000_000)
      assert token |> Token.to_map() |> Token.from_map() == token
    end
  end

  describe "the provider" do
    defp a_provider(opts \\ []) do
      request =
        Keyword.get_lazy(opts, :request, fn ->
          Delegation.new(@endpoint, "agent_client") |> Delegation.client_secret("agent_secret")
        end)

      {:ok, provider} =
        Provider.start_link(
          request: request,
          subject:
            Keyword.get_lazy(opts, :subject, fn ->
              TokenSource.static_token("user_at", :access_token)
            end),
          actor: Keyword.get(opts, :actor, TokenSource.static_token("agent_at", :access_token))
        )

      provider
    end

    # A GenServer provider makes its own Req calls, so the stub has to be
    # registered first and then explicitly allowed for that process — otherwise
    # the exchange escapes to the real network.
    defp allow(provider), do: Req.Test.allow(Delegation, self(), provider)

    test "exchanges once and serves from cache until expiry" do
      agent = counting_stub()
      provider = a_provider()
      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert {:ok, "delegated_at"} = Provider.get_token(provider)

      assert length(Agent.get(agent, & &1)) == 1
      assert %Token{access_token: "delegated_at"} = Provider.token(provider)
    end

    test "re-exchanges after invalidate" do
      agent = counting_stub()
      provider = a_provider()
      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      Provider.invalidate(provider)
      assert Provider.token(provider) == nil
      assert {:ok, "delegated_at"} = Provider.get_token(provider)

      assert length(Agent.get(agent, & &1)) == 2
    end

    test "re-exchanges a token that is already inside the skew" do
      # Expires in 30s: inside the 60s buffer, so the second call must exchange
      # again rather than serve it.
      agent = counting_stub(%{@success_body | "expires_in" => 30})
      provider = a_provider()
      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert {:ok, "delegated_at"} = Provider.get_token(provider)

      assert length(Agent.get(agent, & &1)) == 2
    end

    test "pulls a fresh subject token on every exchange" do
      agent = counting_stub()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      subject =
        TokenSource.dynamic(
          fn -> {:ok, "user_#{Agent.get_and_update(counter, &{&1 + 1, &1 + 1})}"} end,
          :access_token
        )

      provider = a_provider(subject: subject)
      allow(provider)

      assert {:ok, _} = Provider.get_token(provider)
      Provider.invalidate(provider)
      assert {:ok, _} = Provider.get_token(provider)

      assert [first, second] = Agent.get(agent, & &1)
      assert first =~ "subject_token=user_1"
      assert second =~ "subject_token=user_2"
    end

    test "uses a client_credentials actor, fresh each time" do
      agent = counting_stub()
      {:ok, fake} = FakeOAuth.start_link()
      provider = a_provider(actor: TokenSource.client_credentials(fake))
      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert [body] = Agent.get(agent, & &1)
      assert body =~ "actor_token=agent_live_1"
      assert body =~ "actor_token_type=#{URI.encode_www_form(@access_token_urn)}"
    end

    test "uses an authorization-code subject" do
      agent = counting_stub()

      {:ok, user} =
        DatagroutConduit.AuthCode.Provider.start_link(
          grant: %DatagroutConduit.AuthCode.Grant{
            access_token: "user_access_token",
            client_id: "client_abc",
            token_endpoint: "https://as.example.com/oauth/token",
            expires_at: System.os_time(:second) + 3600
          }
        )

      provider = a_provider(subject: TokenSource.authorization_code(user))
      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert [body] = Agent.get(agent, & &1)
      assert body =~ "subject_token=user_access_token"
    end

    test "without an actor fails loudly unless impersonating" do
      agent = counting_stub()
      provider = a_provider(request: Delegation.new(@endpoint, "c"), actor: nil)
      allow(provider)

      assert {:error, %Error{kind: :missing_actor}} = Provider.get_token(provider)
      assert Agent.get(agent, & &1) == []
    end

    test "without an actor exchanges when impersonation was asked for" do
      agent = counting_stub()

      provider =
        a_provider(
          request: Delegation.new(@endpoint, "c") |> Delegation.impersonation(),
          actor: nil
        )

      allow(provider)

      assert {:ok, "delegated_at"} = Provider.get_token(provider)
      assert [body] = Agent.get(agent, & &1)
      refute body =~ "actor_token"
    end

    test "propagates an upstream source failure as that source's own reason" do
      counting_stub()

      provider =
        a_provider(
          subject: TokenSource.dynamic(fn -> {:error, :vault_unreachable} end, :access_token)
        )

      allow(provider)

      assert {:error, :vault_unreachable} = Provider.get_token(provider)
    end

    test "serializes concurrent callers into a single exchange" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Delegation, fn conn ->
        Agent.update(agent, &(&1 + 1))
        # Slow, so the other callers are reliably queued behind the leader.
        Process.sleep(100)
        Req.Test.json(conn, @success_body)
      end)

      provider = a_provider()
      allow(provider)

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Provider.get_token(provider) end) end)
        |> Task.await_many(5_000)

      assert results == List.duplicate({:ok, "delegated_at"}, 5)
      assert Agent.get(agent, & &1) == 1
    end

    test "exposes the request template, without tokens" do
      provider = a_provider()
      assert %Delegation{client_id: "agent_client"} = Provider.request(provider)
    end
  end

  describe "secrets" do
    test "inspecting a request never prints the secret or either token" do
      rendered = inspect(a_request())
      refute rendered =~ "agent_secret"
      refute rendered =~ "user_at"
      refute rendered =~ "agent_at"
      assert rendered =~ "agent_client"
    end

    test "inspecting a token source names its kind, not its token" do
      rendered = inspect(TokenSource.static_token("user_at", :jwt))
      refute rendered =~ "user_at"
      assert rendered =~ "static"
      assert rendered =~ @jwt_urn
    end

    test "inspecting an issued token never prints the bearer" do
      rendered = inspect(a_token(1_700_000_000))
      refute rendered =~ "delegated_at"
      assert rendered =~ "Bearer"
    end

    test "inspecting a provider's state never prints a token or the secret" do
      counting_stub()
      provider = a_provider()
      allow(provider)
      assert {:ok, _} = Provider.get_token(provider)

      rendered = provider |> :sys.get_state() |> inspect()
      refute rendered =~ "agent_secret"
      refute rendered =~ "user_at"
      refute rendered =~ "agent_at"
      refute rendered =~ "delegated_at"
    end
  end
end
