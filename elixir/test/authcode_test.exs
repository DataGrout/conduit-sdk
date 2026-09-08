defmodule DatagroutConduit.AuthCodeTest do
  @moduledoc """
  Ports the Rust reference suite for the authorization-code flow.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.AuthCode
  alias DatagroutConduit.AuthCode.{Error, Grant, RegisteredClient, ServerMetadata}

  @resource "https://gateway.datagrout.ai/connect"
  @authorize "https://gateway.datagrout.ai/oauth/authorize"
  @token "https://gateway.datagrout.ai/oauth/token"
  @register "https://gateway.datagrout.ai/register"

  @metadata %{
    "issuer" => "https://gateway.datagrout.ai",
    "authorization_endpoint" => @authorize,
    "token_endpoint" => @token,
    "registration_endpoint" => @register,
    "code_challenge_methods_supported" => ["S256"],
    "grant_types_supported" => ["authorization_code", "refresh_token"]
  }

  # A server that serves AS metadata and 404s the protected-resource probe.
  defp stub_metadata(metadata \\ @metadata) do
    Req.Test.stub(AuthCode, fn conn ->
      cond do
        String.contains?(conn.request_path, "oauth-protected-resource") ->
          Plug.Conn.send_resp(conn, 404, "not found")

        String.contains?(conn.request_path, ".well-known") ->
          Req.Test.json(conn, metadata)

        true ->
          Plug.Conn.send_resp(conn, 404, "unexpected #{conn.request_path}")
      end
    end)
  end

  # A flow standing where discover leaves it, with a client id set.
  defp a_flow(metadata \\ @metadata) do
    stub_metadata(metadata)
    {:ok, flow} = AuthCode.discover(@resource)
    AuthCode.with_client_id(flow, "client_abc", "http://127.0.0.1:8765/callback")
  end

  defp a_grant(opts \\ []) do
    %Grant{
      access_token: "at",
      client_id: "client_abc",
      token_endpoint: @token,
      refresh_token: opts[:refresh],
      expires_at: opts[:expires_at]
    }
  end

  defp now, do: System.os_time(:second)

  describe "PKCE" do
    test "verifier meets the RFC 7636 length and alphabet" do
      verifier = AuthCode.generate_verifier()
      assert String.length(verifier) == 43
      assert verifier =~ ~r/\A[A-Za-z0-9\-_]+\z/
    end

    test "verifiers are unique" do
      assert 1..50
             |> Enum.map(fn _ -> AuthCode.generate_verifier() end)
             |> Enum.uniq()
             |> length() ==
               50
    end

    test "challenge matches the RFC 7636 test vector" do
      assert AuthCode.challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end

    test "challenge is unpadded base64url" do
      challenge = AuthCode.challenge_s256("anything")
      refute String.contains?(challenge, "=")
      assert challenge =~ ~r/\A[A-Za-z0-9\-_]+\z/
    end
  end

  describe "authorize_url/1" do
    test "carries every required parameter" do
      {:ok, url, pending} = AuthCode.authorize_url(a_flow())

      assert String.starts_with?(url, @authorize <> "?")

      for param <- ["response_type=code", "client_id=client_abc", "code_challenge_method=S256"] do
        assert String.contains?(url, param)
      end

      assert String.contains?(url, "state=#{pending.state}")

      assert String.contains?(
               url,
               "code_challenge=#{AuthCode.challenge_s256(pending.code_verifier)}"
             )
    end

    test "percent-encodes the redirect URI" do
      {:ok, url, _} = AuthCode.authorize_url(a_flow())
      # The unreserved set only: a raw : or / would be read as structure.
      assert String.contains?(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback")
    end

    test "binds the token to the resource" do
      {:ok, url, _} = AuthCode.authorize_url(a_flow())
      # RFC 8707, so the token cannot be replayed against a different resource.
      assert String.contains?(url, "resource=#{AuthCode.urlencode(@resource)}")
    end

    test "requires a client id" do
      stub_metadata()
      {:ok, flow} = AuthCode.discover(@resource)
      assert {:error, %Error{kind: :no_client_id}} = AuthCode.authorize_url(flow)
    end

    test "appends when the endpoint already has a query" do
      metadata = Map.put(@metadata, "authorization_endpoint", @authorize <> "?tenant=acme")
      {:ok, url, _} = AuthCode.authorize_url(a_flow(metadata))
      assert String.contains?(url, "?tenant=acme&response_type=code")
    end

    test "requests the default scope" do
      {:ok, url, _} = AuthCode.authorize_url(a_flow())
      assert String.contains?(url, "scope=mcp%20tools")
    end

    test "honours a custom scope" do
      {:ok, url, _} = a_flow() |> AuthCode.with_scope("mcp") |> AuthCode.authorize_url()
      assert String.contains?(url, "scope=mcp")
    end
  end

  describe "state / CSRF" do
    test "exchange refuses a mismatched state" do
      flow = a_flow()
      {:ok, _url, pending} = AuthCode.authorize_url(flow)

      # Refused before anything is sent: the stub would 404 an unexpected POST.
      assert {:error, %Error{kind: :state_mismatch}} =
               AuthCode.exchange(flow, pending, "code", "wrong")
    end

    test "exchange refuses an empty state" do
      flow = a_flow()
      {:ok, _url, pending} = AuthCode.authorize_url(flow)

      assert {:error, %Error{kind: :state_mismatch}} =
               AuthCode.exchange(flow, pending, "code", "")
    end
  end

  describe "exchange/4" do
    test "sends the verifier and resource, and returns a grant" do
      flow = a_flow()
      {:ok, _url, pending} = AuthCode.authorize_url(flow)

      Req.Test.stub(AuthCode, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)

        assert form["grant_type"] == "authorization_code"
        assert form["code"] == "the_code"
        assert form["client_id"] == "client_abc"
        assert form["code_verifier"] == pending.code_verifier
        assert form["redirect_uri"] == "http://127.0.0.1:8765/callback"
        assert form["resource"] == @resource

        Req.Test.json(conn, %{
          "access_token" => "at_1",
          "refresh_token" => "rt_1",
          "expires_in" => 3600,
          "scope" => "mcp tools"
        })
      end)

      assert {:ok, grant} = AuthCode.exchange(flow, pending, "the_code", pending.state)
      assert grant.access_token == "at_1"
      assert grant.refresh_token == "rt_1"
      assert grant.client_id == "client_abc"
      assert grant.token_endpoint == @token
      assert grant.resource == @resource
      assert_in_delta grant.expires_at, now() + 3600, 5
    end

    test "reports a rejection with its status and body" do
      flow = a_flow()
      {:ok, _url, pending} = AuthCode.authorize_url(flow)

      Req.Test.stub(AuthCode, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
      end)

      assert {:error, %Error{kind: :token_exchange, status: 400, body: body}} =
               AuthCode.exchange(flow, pending, "code", pending.state)

      assert body =~ "invalid_grant"
    end

    test "refuses a token response that is not an object" do
      flow = a_flow()
      {:ok, _url, pending} = AuthCode.authorize_url(flow)

      # A 200 carrying a JSON array is not a token response. Reporting it beats
      # a match error deep in the parse.
      Req.Test.stub(AuthCode, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s(["not","an","object"]))
      end)

      assert {:error, %Error{kind: :http, message: message}} =
               AuthCode.exchange(flow, pending, "code", pending.state)

      assert message =~ "expected a JSON object"
    end
  end

  describe "Grant" do
    test "a grant with no stated expiry is not expired" do
      refute Grant.expired?(a_grant())
    end

    test "a grant expires early by the refresh skew" do
      # Expires in 30s, skew is 60s → already due for refresh.
      assert Grant.expired?(a_grant(expires_at: now() + 30, refresh: "rt"))
      refute Grant.expired?(a_grant(expires_at: now() + 600, refresh: "rt"))
    end

    test "refreshing without a refresh token is a typed error" do
      assert {:error, %Error{kind: :not_refreshable}} = Grant.refresh(a_grant(expires_at: 0))
    end

    test "refresh keeps the old token when the server does not rotate" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at_2", "expires_in" => 3600})
      end)

      assert {:ok, refreshed} = Grant.refresh(a_grant(expires_at: 0, refresh: "rt_1"))
      assert refreshed.access_token == "at_2"
      # Not nil: silently dropping it would make the grant unrefreshable.
      assert refreshed.refresh_token == "rt_1"
    end

    test "refresh rotates the token when the server issues a new one" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "at_2",
          "refresh_token" => "rt_2",
          "expires_in" => 3600
        })
      end)

      assert {:ok, refreshed} = Grant.refresh(a_grant(expires_at: 0, refresh: "rt_1"))
      assert refreshed.refresh_token == "rt_2"
    end

    test "refresh sends the resource when the grant is bound" do
      grant = %{a_grant(expires_at: 0, refresh: "rt") | resource: @resource}

      Req.Test.stub(AuthCode, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)
        assert form["grant_type"] == "refresh_token"
        assert form["resource"] == @resource
        Req.Test.json(conn, %{"access_token" => "at_2"})
      end)

      assert {:ok, refreshed} = Grant.refresh(grant)
      # The binding survives the refresh, or the next one would drop it.
      assert refreshed.resource == @resource
    end

    test "round-trips with the cross-language field names" do
      grant = %Grant{
        access_token: "at",
        refresh_token: "rt",
        expires_at: 1_700_000_000,
        client_id: "cid",
        token_endpoint: @token,
        scope: "mcp tools",
        resource: @resource
      }

      map = Grant.to_map(grant)

      assert Enum.sort(Map.keys(map)) ==
               Enum.sort(~w[access_token client_id token_endpoint refresh_token expires_at scope
                            resource])

      back = map |> Jason.encode!() |> Jason.decode!() |> Grant.from_map()
      assert Grant.to_map(back) == map
    end

    test "omits absent optionals" do
      map = Grant.to_map(%Grant{access_token: "at", client_id: "cid", token_endpoint: @token})
      # Not written as nulls: another SDK reading this must see absence.
      assert Enum.sort(Map.keys(map)) == ~w[access_token client_id token_endpoint]
    end

    test "reads a minimal payload" do
      grant =
        Grant.from_map(%{
          "access_token" => "at",
          "client_id" => "cid",
          "token_endpoint" => @token
        })

      assert is_nil(grant.refresh_token)
      assert is_nil(grant.expires_at)
      refute Grant.refreshable?(grant)
    end

    test "expires_at is Unix seconds, not a monotonic reading" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at", "expires_in" => 3600})
      end)

      {:ok, refreshed} = Grant.refresh(a_grant(expires_at: 0, refresh: "rt"))
      # A monotonic reading is meaningless once written down; this must be a
      # wall-clock instant.
      assert_in_delta refreshed.expires_at, now() + 3600, 5
    end
  end

  describe "Provider" do
    alias DatagroutConduit.AuthCode.Provider

    test "returns a live token without refreshing" do
      # No stub registered, so any request would fail the test.
      {:ok, provider} =
        Provider.start_link(grant: a_grant(expires_at: now() + 3600, refresh: "rt"))

      assert {:ok, "at"} = Provider.get_token(provider)
    end

    test "refreshes and reports a rotated grant" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "at_2",
          "refresh_token" => "rt_2",
          "expires_in" => 3600
        })
      end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt_1"))
      # The refresh happens inside the GenServer, so it needs the stub too.
      Req.Test.allow(AuthCode, self(), provider)

      assert {:ok, "at_2"} = Provider.get_token(provider)
      assert Provider.dirty?(provider)

      assert {:ok, rotated} = Provider.take_if_dirty(provider)
      assert rotated.refresh_token == "rt_2"
      # Cleared, so a persistence loop writes once per rotation.
      refute Provider.dirty?(provider)
      assert :clean = Provider.take_if_dirty(provider)
    end

    test "invalidate forces the next fetch to refresh" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at_2", "expires_in" => 3600})
      end)

      {:ok, provider} =
        Provider.start_link(grant: a_grant(expires_at: now() + 3600, refresh: "rt"))

      Req.Test.allow(AuthCode, self(), provider)

      assert {:ok, "at"} = Provider.get_token(provider)
      Provider.invalidate(provider)
      assert {:ok, "at_2"} = Provider.get_token(provider)
    end

    test "invalidate keeps the refresh token" do
      {:ok, provider} =
        Provider.start_link(grant: a_grant(expires_at: now() + 3600, refresh: "rt"))

      Provider.invalidate(provider)
      # Dropping the grant would make recovery impossible.
      assert Provider.grant(provider).refresh_token == "rt"
    end

    test "take_if_dirty is clean until something changes" do
      {:ok, provider} = Provider.start_link(grant: a_grant())
      assert :clean = Provider.take_if_dirty(provider)
    end

    test "from_auth accepts every shape" do
      assert :none = Provider.from_auth(nil)

      {:ok, running} = Provider.start_link(grant: a_grant())
      assert {:ok, ^running} = Provider.from_auth(running)

      assert {:ok, from_grant} = Provider.from_auth(a_grant())
      assert {:ok, "at"} = Provider.get_token(from_grant)

      assert {:ok, from_map} = Provider.from_auth(Grant.to_map(a_grant()))
      assert {:ok, "at"} = Provider.get_token(from_map)

      # A map written with atom keys loads too.
      atom_keyed = %{access_token: "at", client_id: "cid", token_endpoint: @token}
      assert {:ok, from_atoms} = Provider.from_auth(atom_keyed)
      assert {:ok, "at"} = Provider.get_token(from_atoms)
    end

    test "from_auth rejects nonsense" do
      assert {:error, _} = Provider.from_auth("a token string")
    end
  end

  describe "Provider concurrency" do
    alias DatagroutConduit.AuthCode.Provider

    test "state stays answerable while a refresh is in flight" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        send(test_pid, {:refresh_started, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        Req.Test.json(conn, %{"access_token" => "at_2", "expires_in" => 3600})
      end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt"))
      Req.Test.allow(AuthCode, self(), provider)

      caller = Task.async(fn -> Provider.get_token(provider) end)
      assert_receive {:refresh_started, refresher}, 2_000

      # The refresh runs off the GenServer, so these answer immediately. Run
      # inline, they would block for the whole round trip and a hung endpoint
      # would wedge the provider entirely.
      assert Provider.grant(provider).access_token == "at"
      refute Provider.dirty?(provider)
      assert :clean = Provider.take_if_dirty(provider)

      send(refresher, :release)
      assert {:ok, "at_2"} = Task.await(caller, 5_000)
    end

    test "concurrent callers share one refresh" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        send(test_pid, :token_request)
        Req.Test.json(conn, %{"access_token" => "at_2", "expires_in" => 3600})
      end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt"))
      Req.Test.allow(AuthCode, self(), provider)

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Provider.get_token(provider) end) end)
        |> Task.await_many(5_000)

      assert results == List.duplicate({:ok, "at_2"}, 5)

      # One request, shared by every waiter.
      assert_received :token_request
      refute_received :token_request
    end

    test "a failing refresh answers every waiter without a stampede" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        send(test_pid, :token_request)
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
      end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt"))
      Req.Test.allow(AuthCode, self(), provider)

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Provider.get_token(provider) end) end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &match?({:error, %Error{kind: :token_exchange}}, &1))
      # A dead token endpoint costs one request, not one per waiter.
      assert_received :token_request
      refute_received :token_request
    end

    test "a later call retries after a failure rather than replaying it" do
      # The shared failure belongs to the callers that queued behind that
      # attempt, not to the future: once it has settled, the next call tries
      # again.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(AuthCode, fn conn ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> Plug.Conn.send_resp(conn, 400, ~s({"error":"temporarily_unavailable"}))
          _ -> Req.Test.json(conn, %{"access_token" => "at_2", "expires_in" => 3600})
        end
      end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt"))
      Req.Test.allow(AuthCode, self(), provider)

      assert {:error, %Error{kind: :token_exchange}} = Provider.get_token(provider)
      assert {:ok, "at_2"} = Provider.get_token(provider)
    end

    test "a crash in the refresh answers the waiters instead of hanging them" do
      Req.Test.stub(AuthCode, fn _conn -> raise "boom" end)

      {:ok, provider} = Provider.start_link(grant: a_grant(expires_at: 0, refresh: "rt"))
      Req.Test.allow(AuthCode, self(), provider)

      # Monitored rather than linked, so the provider outlives it.
      assert {:error, %Error{}} = Provider.get_token(provider)
      assert Process.alive?(provider)
    end
  end

  describe "metadata" do
    test "S256 support is assumed when unadvertised" do
      # RFC 8414 makes the field optional and DataGrout omits it on some paths.
      {:ok, metadata} =
        ServerMetadata.from_map(Map.delete(@metadata, "code_challenge_methods_supported"))

      assert ServerMetadata.supports_s256?(metadata)
    end

    test "a server advertising only plain is refused" do
      {:ok, metadata} =
        ServerMetadata.from_map(Map.put(@metadata, "code_challenge_methods_supported", ["plain"]))

      refute ServerMetadata.supports_s256?(metadata)
    end

    test "tolerates a missing registration endpoint" do
      {:ok, metadata} = ServerMetadata.from_map(Map.delete(@metadata, "registration_endpoint"))
      assert is_nil(metadata.registration_endpoint)
    end

    test "metadata without the required endpoints is a discovery error" do
      assert {:error, %Error{kind: :discovery}} =
               ServerMetadata.from_map(%{"issuer" => "https://gateway.datagrout.ai"})
    end
  end

  describe "discover/1" do
    test "refuses to downgrade PKCE" do
      stub_metadata(Map.put(@metadata, "code_challenge_methods_supported", ["plain"]))
      assert {:error, %Error{kind: :pkce_unsupported}} = AuthCode.discover(@resource)
    end

    test "follows protected-resource metadata" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        send(test_pid, {:hit, conn.host, conn.request_path})

        if String.contains?(conn.request_path, "oauth-protected-resource") do
          Req.Test.json(conn, %{"authorization_servers" => ["https://as.example.com"]})
        else
          Req.Test.json(conn, @metadata)
        end
      end)

      assert {:ok, _flow} = AuthCode.discover(@resource)
      assert_received {:hit, "as.example.com", "/.well-known/oauth-authorization-server"}
    end

    test "falls back to the resource origin" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        if String.contains?(conn.request_path, "oauth-protected-resource") do
          Plug.Conn.send_resp(conn, 404, "")
        else
          send(test_pid, {:hit, conn.host, conn.request_path})
          Req.Test.json(conn, @metadata)
        end
      end)

      assert {:ok, _flow} = AuthCode.discover(@resource)
      # DataGrout serves AS metadata at the origin, not under /connect.
      assert_received {:hit, "gateway.datagrout.ai", "/.well-known/oauth-authorization-server"}
    end

    test "ignores resource metadata that is not an object" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        if String.contains?(conn.request_path, "oauth-protected-resource") do
          # A proxy answering 200 with a string body is not metadata.
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, ~s("not an object"))
        else
          send(test_pid, {:hit, conn.request_path})
          Req.Test.json(conn, @metadata)
        end
      end)

      assert {:ok, _flow} = AuthCode.discover(@resource)
      assert_received {:hit, "/.well-known/oauth-authorization-server"}
    end

    test "reports failure when no metadata is found" do
      Req.Test.stub(AuthCode, fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end)
      assert {:error, %Error{kind: :discovery}} = AuthCode.discover(@resource)
    end

    test "falls back to openid-configuration" do
      test_pid = self()

      Req.Test.stub(AuthCode, fn conn ->
        cond do
          String.contains?(conn.request_path, "openid-configuration") ->
            send(test_pid, :oidc)
            Req.Test.json(conn, @metadata)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, _flow} = AuthCode.discover(@resource)
      assert_received :oidc
    end
  end

  describe "register/3" do
    test "sends a public client and returns the pair" do
      stub_metadata()
      {:ok, flow} = AuthCode.discover(@resource)

      Req.Test.stub(AuthCode, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["client_name"] == "My App"
        assert payload["redirect_uris"] == ["http://127.0.0.1:8765/callback"]
        # No secret: a desktop app cannot keep one, and PKCE stands in.
        assert payload["token_endpoint_auth_method"] == "none"
        assert payload["application_type"] == "native"

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"client_id" => "issued_id"})
      end)

      assert {:ok, registered, flow} =
               AuthCode.register(flow, "My App", "http://127.0.0.1:8765/callback")

      assert registered.client_id == "issued_id"
      # The URI travels with the id, because redirect matching is exact.
      assert registered.redirect_uri == "http://127.0.0.1:8765/callback"
      assert flow.client_id == "issued_id"
    end

    test "without an endpoint is a distinct error" do
      stub_metadata(Map.delete(@metadata, "registration_endpoint"))
      {:ok, flow} = AuthCode.discover(@resource)

      assert {:error, %Error{kind: :no_registration_endpoint}} =
               AuthCode.register(flow, "App", "http://127.0.0.1:1/cb")
    end

    test "rejection carries the status and body" do
      stub_metadata()
      {:ok, flow} = AuthCode.discover(@resource)

      Req.Test.stub(AuthCode, fn conn -> Plug.Conn.send_resp(conn, 403, "forbidden") end)

      assert {:error, %Error{kind: :registration_rejected, status: 403, body: "forbidden"}} =
               AuthCode.register(flow, "App", "http://127.0.0.1:1/cb")
    end

    test "restoring a registered client restores both halves" do
      stub_metadata()
      {:ok, flow} = AuthCode.discover(@resource)

      registered = %RegisteredClient{
        client_id: "saved_id",
        redirect_uri: "http://127.0.0.1:9/cb"
      }

      flow = AuthCode.with_registered_client(flow, registered)

      assert flow.client_id == "saved_id"
      assert flow.redirect_uri == "http://127.0.0.1:9/cb"
    end

    test "registered client round-trips" do
      registered = %RegisteredClient{client_id: "cid", redirect_uri: "http://127.0.0.1:9/cb"}

      back =
        registered
        |> RegisteredClient.to_map()
        |> Jason.encode!()
        |> Jason.decode!()
        |> RegisteredClient.from_map()

      assert back == registered
    end
  end

  describe "helpers" do
    test "origin strips paths and keeps non-default ports" do
      assert AuthCode.origin_of("https://example.com/a/b?c=d") == "https://example.com"
      assert AuthCode.origin_of("http://127.0.0.1:8765/callback") == "http://127.0.0.1:8765"
      # A default port is not part of the origin.
      assert AuthCode.origin_of("https://example.com:443/x") == "https://example.com"
      assert is_nil(AuthCode.origin_of("not a url"))
    end

    test "urlencode escapes everything outside the unreserved set" do
      assert AuthCode.urlencode("a b") == "a%20b"
      assert AuthCode.urlencode("-._~") == "-._~"
      assert AuthCode.urlencode("/:") == "%2F%3A"
    end

    test "secure_compare is length-independent" do
      assert AuthCode.secure_compare("abc", "abc")
      refute AuthCode.secure_compare("abc", "abcd")
      refute AuthCode.secure_compare("abc", "abd")
      refute AuthCode.secure_compare("", "a")
      assert AuthCode.secure_compare("", "")
    end

    test "default scope matches the server's own vocabulary" do
      # The authorization server's registration default. DataGrout stores what
      # it is given, so an invented scope is accepted silently and means nothing.
      assert AuthCode.default_scope() == "mcp tools"
    end

    test "error kinds use the shared wire names" do
      # The taxonomy is part of the cross-language contract.
      assert Error.discovery("x").kind == :discovery
      assert Error.no_registration_endpoint().kind == :no_registration_endpoint
      assert Error.registration_rejected(1, "").kind == :registration_rejected
      assert Error.no_client_id().kind == :no_client_id
      assert Error.pkce_unsupported().kind == :pkce_unsupported
      assert Error.state_mismatch().kind == :state_mismatch
      assert Error.token_exchange(1, "").kind == :token_exchange
      assert Error.not_refreshable().kind == :not_refreshable
      assert Error.denied("access_denied").kind == :denied
      assert Error.http("x").kind == :http
    end

    test "errors are exceptions with a readable message" do
      assert Exception.message(Error.denied("access_denied", "User said no")) ==
               "authorization denied: access_denied — User said no"
    end
  end
end
