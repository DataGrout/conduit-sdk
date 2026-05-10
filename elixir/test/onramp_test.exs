defmodule DatagroutConduit.OnrampTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.Onramp
  alias DatagroutConduit.Onramp.{OnrampOptions, OnrampCredentials}

  @gateway "https://app.datagrout.ai"
  @token_url "#{@gateway}/servers/abc/oauth/token"

  @complete_body %{
    "client_id" => "agt_abc123",
    "client_secret" => "sk_xyz789",
    "token_url" => @token_url,
    "mcp_url" => "#{@gateway}/servers/abc/mcp",
    "rpc_url" => "#{@gateway}/servers/abc/rpc",
    "scopes" => ["mcp:read", "tools:call"],
    "expires_in" => 2_592_000
  }

  def default_opts do
    %OnrampOptions{
      gateway: @gateway,
      agent_name: "test-agent",
      agent_type: "claude-sonnet-4-6",
      intended_use: "Testing."
    }
  end

  # ─── OnrampOptions struct ─────────────────────────────────────────────────────

  describe "OnrampOptions" do
    test "holds required fields" do
      opts = %OnrampOptions{gateway: @gateway, agent_name: "my-agent"}
      assert opts.gateway == @gateway
      assert opts.agent_name == "my-agent"
    end

    test "optional fields default to nil" do
      opts = %OnrampOptions{gateway: @gateway, agent_name: "bare"}
      assert is_nil(opts.agent_type)
      assert is_nil(opts.intended_use)
      assert is_nil(opts.access_code)
    end

    test "all fields can be set" do
      opts = %OnrampOptions{
        gateway: @gateway,
        agent_name: "my-agent",
        agent_type: "gpt-4o",
        intended_use: "extraction",
        access_code: "code123"
      }
      assert opts.agent_type == "gpt-4o"
      assert opts.access_code == "code123"
    end
  end

  # ─── OnrampCredentials struct ─────────────────────────────────────────────────

  describe "OnrampCredentials" do
    test "holds all fields" do
      creds = %OnrampCredentials{
        client_id: "agt_abc",
        client_secret: "sk_xyz",
        token_url: @token_url,
        scopes: ["mcp:read"],
        expires_in: 2_592_000,
        mcp_url: "#{@gateway}/servers/abc/mcp",
        rpc_url: "#{@gateway}/servers/abc/rpc"
      }
      assert creds.client_id == "agt_abc"
      assert creds.scopes == ["mcp:read"]
      assert creds.expires_in == 2_592_000
    end

    test "mcp_url and rpc_url default to nil" do
      creds = %OnrampCredentials{
        client_id: "x", client_secret: "y", token_url: @token_url
      }
      assert is_nil(creds.mcp_url)
      assert is_nil(creds.rpc_url)
    end

    test "scopes defaults to empty list" do
      creds = %OnrampCredentials{client_id: "x", client_secret: "y", token_url: @token_url}
      assert creds.scopes == []
    end
  end

  # ─── register_only ────────────────────────────────────────────────────────────

  describe "register_only/1" do
    test "returns {:ok, creds} on successful two-step flow" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        cond do
          conn.request_path == "/onramp" ->
            Req.Test.json(conn, %{"session_token" => "sess_abc123"})

          conn.request_path == "/onramp/complete" ->
            Req.Test.json(conn, @complete_body)
        end
      end)

      assert {:ok, creds} = Onramp.register_only(default_opts())
      assert creds.client_id == "agt_abc123"
      assert creds.client_secret == "sk_xyz789"
      assert creds.mcp_url == "#{@gateway}/servers/abc/mcp"
      assert creds.scopes == ["mcp:read", "tools:call"]
      assert creds.expires_in == 2_592_000
    end

    test "returns {:error, ...} when init is rejected" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        Plug.Conn.send_resp(conn, 429, "rate_limited")
      end)

      assert {:error, {:onramp_init_rejected, 429, _}} = Onramp.register_only(default_opts())
    end

    test "returns {:error, ...} when complete is rejected" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        cond do
          conn.request_path == "/onramp" ->
            Req.Test.json(conn, %{"session_token" => "sess_abc123"})

          conn.request_path == "/onramp/complete" ->
            Plug.Conn.send_resp(conn, 410, "expired")
        end
      end)

      assert {:error, {:onramp_complete_rejected, 410, _}} = Onramp.register_only(default_opts())
    end

    test "handles absent mcp_url and rpc_url gracefully" do
      partial = Map.drop(@complete_body, ["mcp_url", "rpc_url"])

      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        cond do
          conn.request_path == "/onramp" ->
            Req.Test.json(conn, %{"session_token" => "sess_abc123"})

          conn.request_path == "/onramp/complete" ->
            Req.Test.json(conn, partial)
        end
      end)

      assert {:ok, creds} = Onramp.register_only(default_opts())
      assert is_nil(creds.mcp_url)
      assert is_nil(creds.rpc_url)
    end
  end

  # ─── register_and_exchange/1 ──────────────────────────────────────────────────

  describe "register_and_exchange/1" do
    test "returns {:ok, {creds, token}} on full success" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        cond do
          conn.request_path == "/onramp" ->
            Req.Test.json(conn, %{"session_token" => "sess_abc123"})

          conn.request_path == "/onramp/complete" ->
            Req.Test.json(conn, @complete_body)

          String.ends_with?(conn.request_path, "/oauth/token") ->
            Req.Test.json(conn, %{"access_token" => "tok_live123"})
        end
      end)

      assert {:ok, {creds, token}} = Onramp.register_and_exchange(default_opts())
      assert creds.client_id == "agt_abc123"
      assert token == "tok_live123"
    end

    test "propagates init error" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        Plug.Conn.send_resp(conn, 429, "rate_limited")
      end)

      assert {:error, {:onramp_init_rejected, 429, _}} =
               Onramp.register_and_exchange(default_opts())
    end

    test "propagates token exchange error" do
      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        cond do
          conn.request_path == "/onramp" ->
            Req.Test.json(conn, %{"session_token" => "sess_abc123"})

          conn.request_path == "/onramp/complete" ->
            Req.Test.json(conn, @complete_body)

          true ->
            Plug.Conn.send_resp(conn, 401, "invalid_client")
        end
      end)

      assert {:error, {:token_exchange_failed, 401, _}} =
               Onramp.register_and_exchange(default_opts())
    end
  end

  # ─── exchange_token/1 ─────────────────────────────────────────────────────────

  describe "exchange_token/1" do
    test "returns {:ok, token} on success" do
      creds = %OnrampCredentials{
        client_id: "agt_abc",
        client_secret: "sk_xyz",
        token_url: @token_url
      }

      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        Req.Test.json(conn, %{"access_token" => "tok_live123"})
      end)

      assert {:ok, "tok_live123"} = Onramp.exchange_token(creds)
    end

    test "returns {:error, ...} on failure" do
      creds = %OnrampCredentials{
        client_id: "x", client_secret: "y", token_url: @token_url
      }

      Req.Test.stub(DatagroutConduit.Onramp, fn conn ->
        Plug.Conn.send_resp(conn, 401, "invalid_client")
      end)

      assert {:error, {:token_exchange_failed, 401, _}} = Onramp.exchange_token(creds)
    end
  end
end
