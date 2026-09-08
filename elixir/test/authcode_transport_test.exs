defmodule DatagroutConduit.AuthCodeTransportTest.FakeOAuth do
  @moduledoc """
  A stand-in for `DatagroutConduit.OAuth` that answers the same two messages
  without going near the network. It hands out a new token each time it is
  invalidated, so a retry can be told apart from the first attempt.
  """

  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, 1}

  @impl true
  def handle_call(:get_token, _from, n), do: {:reply, {:ok, "machine_#{n}"}, n}

  @impl true
  def handle_cast(:invalidate, n), do: {:noreply, n + 1}
end

defmodule DatagroutConduit.AuthCodeTransportTest do
  @moduledoc """
  The transports must authenticate with an authorization-code grant.

  Each resolves auth on the way out and invalidates it on a 401, which is the
  whole reason an expired access token recovers by refreshing instead of
  surfacing to the caller as an auth failure. Driven against both HTTP
  transports, which carry independent copies of that path.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.{Auth, AuthCode}
  alias DatagroutConduit.AuthCode.{Grant, Provider}
  alias DatagroutConduit.AuthCodeTransportTest.FakeOAuth
  alias DatagroutConduit.Transport

  @endpoint "https://gateway.datagrout.ai/connect"
  @token "https://gateway.datagrout.ai/oauth/token"

  @http_transports [Transport.MCP, Transport.JSONRPC]

  defp a_grant(opts \\ []) do
    %Grant{
      access_token: "user_access_token",
      client_id: "client_abc",
      token_endpoint: @token,
      refresh_token: Keyword.get(opts, :refresh, "rt"),
      expires_at: System.os_time(:second) + Keyword.get(opts, :expires_in, 3600)
    }
  end

  # Build a Req against the Req.Test plug, the way a transport's connect would,
  # then hand it the auth header the client would merge.
  defp req_for(transport, auth) do
    {:ok, req} = transport.connect(%{url: @endpoint, identity: nil, auth: nil})
    {:ok, headers} = Auth.resolved_headers(auth)
    Req.merge(req, plug: {Req.Test, __MODULE__}, headers: headers)
  end

  defp send_request(transport, req, auth) do
    transport.send_request(req, %{method: "tools/list", params: %{}, id: 1, auth: auth})
  end

  describe "resolving an authorization-code grant" do
    test "a grant becomes a bearer header" do
      auth = Auth.normalize({:authorization_code, a_grant()})
      assert {:ok, [{"authorization", "Bearer user_access_token"}]} = Auth.resolved_headers(auth)
    end

    test "a grant map straight from JSON is accepted" do
      map = a_grant() |> Grant.to_map() |> Jason.encode!() |> Jason.decode!()
      auth = Auth.normalize({:authorization_code, map})
      assert {:ok, [{"authorization", "Bearer user_access_token"}]} = Auth.resolved_headers(auth)
    end

    test "a caller-owned provider is used as is" do
      {:ok, provider} = Provider.start_link(grant: a_grant())
      # Same process, so a rotated refresh token reaches the caller's copy.
      assert {:authorization_code, ^provider} =
               Auth.normalize({:authorization_code, provider})
    end

    test "an expired grant is refreshed before the request" do
      Req.Test.stub(AuthCode, fn conn ->
        Req.Test.json(conn, %{"access_token" => "refreshed", "expires_in" => 3600})
      end)

      {:authorization_code, provider} =
        auth = Auth.normalize({:authorization_code, a_grant(expires_in: -10)})

      Req.Test.allow(AuthCode, self(), provider)

      assert {:ok, [{"authorization", "Bearer refreshed"}]} = Auth.resolved_headers(auth)
    end

    test "a static bearer is not provider-backed" do
      # So a 401 against one is final rather than retried forever.
      refute Auth.provider_backed?({:bearer, "static"})
      assert Auth.provider_backed?(Auth.normalize({:authorization_code, a_grant()}))
    end

    test "unusable authorization_code auth raises rather than going unauthenticated" do
      # A configuration mistake, not a transient failure. Carrying on without
      # auth would turn a typo into a puzzling 401 much later.
      assert_raise ArgumentError, ~r/must be a Grant/, fn ->
        Auth.normalize({:authorization_code, "a token string"})
      end
    end

    test "a provider that cannot produce a token reports why" do
      # The reason the fetch failed, not an empty header list — a caller must
      # not mistake "could not authenticate" for "no auth configured".
      Req.Test.stub(AuthCode, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
      end)

      {:authorization_code, provider} =
        auth = Auth.normalize({:authorization_code, a_grant(expires_in: -10)})

      Req.Test.allow(AuthCode, self(), provider)

      assert {:error, %AuthCode.Error{kind: :token_exchange, status: 400}} =
               Auth.resolve(auth)

      assert {:error, %AuthCode.Error{kind: :token_exchange}} = Auth.resolved_headers(auth)
    end
  end

  describe "401 recovery" do
    test "a 401 refreshes the grant and retries once" do
      for transport <- @http_transports do
        {:ok, agent} = Agent.start_link(fn -> [] end)

        Req.Test.stub(AuthCode, fn conn ->
          Agent.update(agent, &(&1 ++ ["token"]))
          Req.Test.json(conn, %{"access_token" => "refreshed", "expires_in" => 3600})
        end)

        {:authorization_code, provider} =
          auth = Auth.normalize({:authorization_code, a_grant()})

        Req.Test.allow(AuthCode, self(), provider)

        Req.Test.stub(__MODULE__, fn conn ->
          bearer = auth_header(conn)
          Agent.update(agent, &(&1 ++ ["rpc:#{bearer}"]))

          if bearer == "Bearer user_access_token" do
            # Stale access token — what a rotated or revoked one looks like.
            Plug.Conn.send_resp(conn, 401, "unauthorized")
          else
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}})
          end
        end)

        result = send_request(transport, req_for(transport, auth), auth)

        assert match?({:ok, %{"ok" => true}}, result) or
                 match?({:ok, %{"ok" => true}, _}, result),
               "#{inspect(transport)} did not recover: #{inspect(result)}"

        # First attempt with the stale token, a refresh, then one retry — and no
        # third attempt, so a genuinely bad credential cannot loop.
        assert Agent.get(agent, & &1) == [
                 "rpc:Bearer user_access_token",
                 "token",
                 "rpc:Bearer refreshed"
               ],
               "#{inspect(transport)} took the wrong path"
      end
    end

    test "a 401 that survives a refresh is reported" do
      for transport <- @http_transports do
        {:ok, agent} = Agent.start_link(fn -> 0 end)

        Req.Test.stub(AuthCode, fn conn ->
          Req.Test.json(conn, %{"access_token" => "still_bad", "expires_in" => 3600})
        end)

        {:authorization_code, provider} =
          auth = Auth.normalize({:authorization_code, a_grant()})

        Req.Test.allow(AuthCode, self(), provider)

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(agent, &(&1 + 1))
          Plug.Conn.send_resp(conn, 401, "unauthorized")
        end)

        assert {:error, {:http_error, 401, "unauthorized"}} =
                 send_request(transport, req_for(transport, auth), auth)

        # Exactly one retry: a revoked grant fails fast instead of recursing.
        assert Agent.get(agent, & &1) == 2,
               "#{inspect(transport)} retried the wrong number of times"
      end
    end

    test "a 401 without a provider is not retried" do
      for transport <- @http_transports do
        {:ok, agent} = Agent.start_link(fn -> 0 end)
        auth = {:bearer, "static"}

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(agent, &(&1 + 1))
          Plug.Conn.send_resp(conn, 401, "unauthorized")
        end)

        # Nothing to refresh, so there is nothing to retry — and the server's
        # own explanation must survive, exactly as it would for any other
        # error status. A wildcard here once hid it being dropped.
        assert {:error, {:http_error, 401, "unauthorized"}} =
                 send_request(transport, req_for(transport, auth), auth)

        assert Agent.get(agent, & &1) == 1, "#{inspect(transport)} retried a static bearer"
      end
    end

    test "a 401 refreshes a client_credentials token too" do
      # The machine grant had this path first; adding the user grant must not
      # have displaced it. It was also unreachable before, because the client
      # never handed the transport a provider at all.
      #
      # A stand-in provider rather than a real one: DatagroutConduit.OAuth
      # fetches over Req with no test plug, so a real one would reach the
      # network. What matters here is the transport's behaviour, not the fetch.
      for transport <- @http_transports do
        {:ok, agent} = Agent.start_link(fn -> [] end)
        {:ok, fake} = FakeOAuth.start_link()
        auth = {:oauth, fake}

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(agent, &(&1 ++ ["rpc:#{auth_header(conn)}"]))

          if auth_header(conn) == "Bearer machine_1" do
            Plug.Conn.send_resp(conn, 401, "unauthorized")
          else
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}})
          end
        end)

        result = send_request(transport, req_for(transport, auth), auth)

        assert match?({:ok, %{"ok" => true}}, result) or
                 match?({:ok, %{"ok" => true}, _}, result),
               "#{inspect(transport)} did not recover the machine grant: #{inspect(result)}"

        assert Agent.get(agent, & &1) == ["rpc:Bearer machine_1", "rpc:Bearer machine_2"],
               "#{inspect(transport)} took the wrong path for the machine grant"
      end
    end
  end

  describe "a token that cannot be fetched" do
    # Before this, a failed fetch was logged and dropped, and the request went
    # out with no Authorization header at all. The caller then saw a bare 401 —
    # one round trip later, and saying nothing about the actual cause.

    defp failing_authcode_auth do
      Req.Test.stub(AuthCode, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
      end)

      {:authorization_code, provider} =
        auth = Auth.normalize({:authorization_code, a_grant(expires_in: -10)})

      Req.Test.allow(AuthCode, self(), provider)
      auth
    end

    test "is not sent as an unauthenticated request" do
      auth = failing_authcode_auth()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(agent, &(&1 + 1))
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      {:ok, client} =
        DatagroutConduit.Client.start_link(
          url: @endpoint,
          transport_mod: Transport.JSONRPC,
          auth: auth
        )

      assert {:error, {:auth_error, %AuthCode.Error{kind: :token_exchange}}} =
               DatagroutConduit.Client.list_tools(client)

      # Never reached the server: there was nothing useful to send.
      assert Agent.get(agent, & &1) == 0
    end

    test "surfaces from a 401 refresh instead of a second 401" do
      for transport <- @http_transports do
        {:ok, agent} = Agent.start_link(fn -> 0 end)

        # A live grant to start, so the first request goes out; the refresh
        # triggered by the 401 is what fails.
        {:authorization_code, provider} =
          auth = Auth.normalize({:authorization_code, a_grant()})

        Req.Test.stub(AuthCode, fn conn ->
          Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
        end)

        Req.Test.allow(AuthCode, self(), provider)

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(agent, &(&1 + 1))
          Plug.Conn.send_resp(conn, 401, "unauthorized")
        end)

        assert {:error, {:auth_error, %AuthCode.Error{kind: :token_exchange}}} =
                 send_request(transport, req_for(transport, auth), auth),
               "#{inspect(transport)} hid the refresh failure"

        # One attempt, then the refresh failed; no blind retry.
        assert Agent.get(agent, & &1) == 1
      end
    end

    test "stops the WebSocket transport rather than connecting without it" do
      # No per-request retry on WS: the token rides the upgrade or not at all.
      auth = failing_authcode_auth()
      Process.flag(:trap_exit, true)

      assert {:error, {:auth_error, %AuthCode.Error{kind: :token_exchange}}} =
               Transport.Ws.start_link(url: "wss://gateway.datagrout.ai/ws", auth: auth)
    end
  end

  describe "WebSocket upgrade headers" do
    # This previously interpolated the {:ok, token} tuple that get_token
    # returns, so the upgrade carried a malformed bearer and OAuth never
    # authenticated over WS.
    defp upgrade_headers(auth) do
      {:ok, headers} = Transport.Ws.build_headers(auth)
      headers
    end

    test "carries an authorization-code bearer" do
      headers = upgrade_headers({:authorization_code, a_grant()})
      assert {"authorization", "Bearer user_access_token"} in headers
    end

    test "carries a client_credentials bearer, not an {:ok, token} tuple" do
      {:ok, fake} = FakeOAuth.start_link()
      headers = upgrade_headers({:oauth, fake})

      # The bug this replaced interpolated the {:ok, token} tuple that
      # get_token returns, so the upgrade carried a malformed bearer.
      assert {"authorization", "Bearer machine_1"} in headers
    end

    test "still carries a static bearer" do
      assert {"authorization", "Bearer static"} in upgrade_headers({:bearer, "static"})
    end

    test "still carries an api key" do
      assert {"x-api-key", "k"} in upgrade_headers({:api_key, "k"})
    end

    test "sends no authorization header without auth" do
      headers = upgrade_headers(nil)
      refute Enum.any?(headers, fn {name, _} -> name == "authorization" end)
    end

    test "always carries the subprotocol" do
      for auth <- [nil, {:bearer, "t"}, {:authorization_code, a_grant()}] do
        assert Enum.any?(upgrade_headers(auth), fn {name, _} ->
                 name == "sec-websocket-protocol"
               end)
      end
    end
  end

  defp auth_header(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
  end
end
