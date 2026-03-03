defmodule DatagroutConduit.OAuthTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.OAuth

  describe "start_link/1" do
    test "requires client_id, client_secret, and token_endpoint" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :client_id}, _}} =
               OAuth.start_link(client_secret: "s", token_endpoint: "https://example.com/token")

      assert {:error, {%KeyError{key: :client_secret}, _}} =
               OAuth.start_link(client_id: "id", token_endpoint: "https://example.com/token")

      assert {:error, {%KeyError{key: :token_endpoint}, _}} =
               OAuth.start_link(client_id: "id", client_secret: "s")
    end

    test "starts with valid options" do
      {:ok, pid} =
        OAuth.start_link(
          client_id: "test-id",
          client_secret: "test-secret",
          token_endpoint: "https://auth.example.com/oauth/token"
        )

      assert is_pid(pid)
      GenServer.stop(pid)
    end

    test "starts with named registration" do
      {:ok, pid} =
        OAuth.start_link(
          client_id: "test-id",
          client_secret: "test-secret",
          token_endpoint: "https://auth.example.com/oauth/token",
          name: :test_oauth_provider
        )

      assert Process.whereis(:test_oauth_provider) == pid
      GenServer.stop(pid)
    end
  end

  describe "derive_token_endpoint/1" do
    test "derives from MCP URL" do
      assert OAuth.derive_token_endpoint("https://gateway.datagrout.ai/servers/123/mcp") ==
               "https://gateway.datagrout.ai/servers/123/oauth/token"
    end

    test "derives from JSONRPC URL" do
      assert OAuth.derive_token_endpoint("https://gateway.datagrout.ai/servers/123/jsonrpc") ==
               "https://gateway.datagrout.ai/servers/123/oauth/token"
    end

    test "handles trailing slash" do
      assert OAuth.derive_token_endpoint("https://gateway.datagrout.ai/servers/123/mcp/") ==
               "https://gateway.datagrout.ai/servers/123/oauth/token"
    end

    test "returns URL unchanged if no mcp/jsonrpc suffix" do
      url = "https://auth.example.com/oauth/token"
      assert OAuth.derive_token_endpoint(url) == url
    end
  end

  describe "state management" do
    test "initial state has no cached token" do
      {:ok, pid} =
        OAuth.start_link(
          client_id: "id",
          client_secret: "secret",
          token_endpoint: "https://example.com/token"
        )

      state = :sys.get_state(pid)
      assert state.cached_token == nil
      assert state.expires_at == nil

      GenServer.stop(pid)
    end
  end

  describe "invalidate/1" do
    test "clears cached token" do
      {:ok, pid} =
        OAuth.start_link(
          client_id: "id",
          client_secret: "secret",
          token_endpoint: "https://example.com/token"
        )

      :sys.replace_state(pid, fn state ->
        %{state | cached_token: "old-token", expires_at: System.monotonic_time(:second) + 3600}
      end)

      state = :sys.get_state(pid)
      assert state.cached_token == "old-token"

      OAuth.invalidate(pid)
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.cached_token == nil
      assert state.expires_at == nil

      GenServer.stop(pid)
    end
  end
end
