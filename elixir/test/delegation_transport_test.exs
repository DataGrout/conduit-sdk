defmodule DatagroutConduit.DelegationTransportTest do
  @moduledoc """
  The transports must authenticate with a delegated token.

  `DatagroutConduit.Auth` is the single choke point every transport calls, so a
  delegated token reaches the HTTP transports and the WebSocket upgrade through
  the same path as the other two grants: resolve on the way out, invalidate on a
  401. Driven against both HTTP transports, which carry independent copies of
  that path, and against the WS upgrade headers, which get one chance to send
  the bearer.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.{Auth, Delegation, Transport}
  alias DatagroutConduit.Delegation.{Error, Provider, TokenSource}

  @endpoint "https://gateway.datagrout.ai/connect"
  @token_endpoint "https://gateway.datagrout.ai/oauth/token"

  @http_transports [Transport.MCP, Transport.JSONRPC]

  defp delegated_auth do
    request =
      Delegation.new(@token_endpoint, "agent_client")
      |> Delegation.client_secret("agent_secret")
      |> Delegation.resource(@endpoint)

    {:ok, provider} =
      Provider.start_link(
        request: request,
        subject: TokenSource.static_token("user_at", :access_token),
        actor: TokenSource.static_token("agent_at", :access_token)
      )

    Req.Test.allow(Delegation, self(), provider)
    {:delegation, provider}
  end

  # A new delegated token on every exchange, so a re-exchange after a 401 is
  # distinguishable from the first attempt.
  defp exchange_stub do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Delegation, fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      Req.Test.json(conn, %{
        "access_token" => "delegated_#{n}",
        "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "token_type" => "Bearer",
        "expires_in" => 900
      })
    end)

    counter
  end

  defp failing_exchange_stub do
    Req.Test.stub(Delegation, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))
    end)
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

  defp auth_header(conn) do
    conn |> Plug.Conn.get_req_header("authorization") |> List.first()
  end

  describe "resolving a delegation" do
    test "an exchanged token becomes a bearer header" do
      exchange_stub()
      auth = delegated_auth()

      assert {:ok, [{"authorization", "Bearer delegated_1"}]} = Auth.resolved_headers(auth)
    end

    test "a running provider is used as is" do
      exchange_stub()
      {:delegation, provider} = delegated_auth()
      assert {:delegation, ^provider} = Auth.normalize({:delegation, provider})
    end

    test "provider options start a provider" do
      exchange_stub()

      auth =
        Auth.normalize(
          {:delegation,
           [
             request: Delegation.new(@token_endpoint, "agent_client"),
             subject: TokenSource.static_token("user_at", :access_token),
             actor: TokenSource.static_token("agent_at", :access_token)
           ]}
        )

      assert {:delegation, provider} = auth
      Req.Test.allow(Delegation, self(), provider)
      assert {:ok, [{"authorization", "Bearer delegated_1"}]} = Auth.resolved_headers(auth)
    end

    test "unusable delegation auth raises rather than going unauthenticated" do
      # A configuration mistake, not a transient failure.
      assert_raise ArgumentError, ~r/must be a running/, fn ->
        Auth.normalize({:delegation, "a token string"})
      end
    end

    test "is provider-backed, so a 401 is worth retrying" do
      exchange_stub()
      assert Auth.provider_backed?(delegated_auth())
    end

    test "a failed exchange reports why rather than returning empty headers" do
      failing_exchange_stub()
      auth = delegated_auth()

      assert {:error, %Error{kind: :server, status: 400, error: "invalid_grant"}} =
               Auth.resolve(auth)

      assert {:error, %Error{kind: :server}} = Auth.resolved_headers(auth)
    end

    test "a missing actor surfaces through Auth rather than reaching the endpoint" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Delegation, fn conn ->
        Agent.update(agent, &(&1 + 1))
        Req.Test.json(conn, %{})
      end)

      {:ok, provider} =
        Provider.start_link(
          request: Delegation.new(@token_endpoint, "agent_client"),
          subject: TokenSource.static_token("user_at", :access_token)
        )

      Req.Test.allow(Delegation, self(), provider)

      assert {:error, %Error{kind: :missing_actor}} = Auth.resolve({:delegation, provider})
      assert Agent.get(agent, & &1) == 0
    end
  end

  describe "401 recovery" do
    test "a 401 re-exchanges the delegated token and retries once" do
      for transport <- @http_transports do
        exchange_stub()
        auth = delegated_auth()
        {:ok, seen} = Agent.start_link(fn -> [] end)

        Req.Test.stub(__MODULE__, fn conn ->
          bearer = auth_header(conn)
          Agent.update(seen, &(&1 ++ [bearer]))

          if bearer == "Bearer delegated_1" do
            # A revoked or rotated delegated token.
            Plug.Conn.send_resp(conn, 401, "unauthorized")
          else
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}})
          end
        end)

        result = send_request(transport, req_for(transport, auth), auth)

        assert match?({:ok, %{"ok" => true}}, result) or
                 match?({:ok, %{"ok" => true}, _}, result),
               "#{inspect(transport)} did not recover: #{inspect(result)}"

        # One attempt with the stale token, then exactly one retry with the
        # re-exchanged one — so a genuinely bad credential cannot loop.
        assert Agent.get(seen, & &1) == ["Bearer delegated_1", "Bearer delegated_2"],
               "#{inspect(transport)} took the wrong path"
      end
    end

    test "a 401 that survives a re-exchange is reported" do
      for transport <- @http_transports do
        # A stub that always issues the same token, so the retry cannot help.
        Req.Test.stub(Delegation, fn conn ->
          Req.Test.json(conn, %{
            "access_token" => "delegated_same",
            "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
            "token_type" => "Bearer",
            "expires_in" => 900
          })
        end)

        auth = delegated_auth()
        {:ok, hits} = Agent.start_link(fn -> 0 end)

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(hits, &(&1 + 1))
          Plug.Conn.send_resp(conn, 401, "unauthorized")
        end)

        assert {:error, {:http_error, 401, "unauthorized"}} =
                 send_request(transport, req_for(transport, auth), auth)

        assert Agent.get(hits, & &1) == 2,
               "#{inspect(transport)} retried the wrong number of times"
      end
    end

    test "a re-exchange failure surfaces instead of a second 401" do
      for transport <- @http_transports do
        # A stale bearer on the way out, so the first request goes; the
        # re-exchange the 401 triggers is what fails.
        failing_exchange_stub()
        auth = delegated_auth()
        {:ok, hits} = Agent.start_link(fn -> 0 end)

        Req.Test.stub(__MODULE__, fn conn ->
          Agent.update(hits, &(&1 + 1))
          Plug.Conn.send_resp(conn, 401, "unauthorized")
        end)

        {:ok, req} = transport.connect(%{url: @endpoint, identity: nil, auth: nil})

        req =
          Req.merge(req,
            plug: {Req.Test, __MODULE__},
            headers: [{"authorization", "Bearer stale"}]
          )

        assert {:error, {:auth_error, %Error{kind: :server}}} =
                 send_request(transport, req, auth),
               "#{inspect(transport)} hid the re-exchange failure"

        assert Agent.get(hits, & &1) == 1
      end
    end
  end

  describe "WebSocket upgrade headers" do
    # Invariant 11: the delegated bearer rides the upgrade or not at all — there
    # is no per-request retry on WS.
    test "carry the exchanged delegated bearer" do
      exchange_stub()
      auth = delegated_auth()

      assert {:ok, headers} = Transport.Ws.build_headers(auth)
      assert {"authorization", "Bearer delegated_1"} in headers
      assert Enum.any?(headers, fn {name, _} -> name == "sec-websocket-protocol" end)
    end

    test "stop the transport rather than connecting without the token" do
      failing_exchange_stub()
      auth = delegated_auth()
      Process.flag(:trap_exit, true)

      assert {:error, {:auth_error, %Error{kind: :server}}} =
               Transport.Ws.start_link(url: "wss://gateway.datagrout.ai/ws", auth: auth)
    end
  end

  describe "the client" do
    test "does not send an unauthenticated request when the exchange fails" do
      failing_exchange_stub()
      auth = delegated_auth()
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(hits, &(&1 + 1))
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      {:ok, client} =
        DatagroutConduit.Client.start_link(
          url: @endpoint,
          transport_mod: Transport.JSONRPC,
          auth: auth
        )

      assert {:error, {:auth_error, %Error{kind: :server}}} =
               DatagroutConduit.Client.list_tools(client)

      # Never reached the server: there was nothing useful to send.
      assert Agent.get(hits, & &1) == 0
    end
  end
end
