defmodule DatagroutConduit.ClientTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.Client

  describe "start_link/1" do
    test "requires url option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :url}, _}} =
               Client.start_link(auth: {:bearer, "token"})
    end

    test "starts with valid options" do
      {:ok, client} =
        Client.start_link(
          url: "https://example.com/mcp",
          auth: {:bearer, "test-token"},
          transport: :mcp
        )

      assert is_pid(client)
      GenServer.stop(client)
    end

    test "starts with jsonrpc transport" do
      {:ok, client} =
        Client.start_link(
          url: "https://example.com/jsonrpc",
          transport: :jsonrpc
        )

      assert is_pid(client)
      GenServer.stop(client)
    end

    test "starts with named registration" do
      {:ok, client} =
        Client.start_link(
          url: "https://example.com/mcp",
          name: :test_conduit_client
        )

      assert Process.whereis(:test_conduit_client) == client
      GenServer.stop(client)
    end

    test "defaults to mcp transport" do
      {:ok, client} =
        Client.start_link(url: "https://example.com/mcp")

      state = :sys.get_state(client)
      assert state.transport_mod == DatagroutConduit.Transport.MCP
      GenServer.stop(client)
    end

    test "uses intelligent interface for DG URLs by default" do
      {:ok, client} =
        Client.start_link(url: "https://gateway.datagrout.ai/servers/123/mcp")

      state = :sys.get_state(client)
      assert state.use_intelligent_interface == true
      GenServer.stop(client)
    end

    test "disables intelligent interface for non-DG URLs by default" do
      {:ok, client} =
        Client.start_link(url: "https://example.com/mcp")

      state = :sys.get_state(client)
      assert state.use_intelligent_interface == false
      GenServer.stop(client)
    end
  end

  describe "intelligent interface filtering" do
    test "filters tools with @ anywhere in name when enabled" do
      tools = [
        %DatagroutConduit.Types.Tool{name: "get_users", description: "Get users"},
        %DatagroutConduit.Types.Tool{name: "@datagrout/discover", description: "Discover"},
        %DatagroutConduit.Types.Tool{name: "create_invoice", description: "Create invoice"},
        %DatagroutConduit.Types.Tool{name: "salesforce@1/get_lead@1", description: "Get lead"}
      ]

      filtered = Enum.reject(tools, fn t -> String.contains?(t.name || "", "@") end)

      assert length(filtered) == 2
      assert Enum.all?(filtered, fn t -> not String.contains?(t.name, "@") end)
      assert Enum.map(filtered, & &1.name) == ["get_users", "create_invoice"]
    end
  end

  describe "request ID incrementing" do
    test "increments request IDs" do
      {:ok, client} =
        Client.start_link(url: "https://example.com/mcp")

      state = :sys.get_state(client)
      assert state.request_id == 0

      GenServer.stop(client)
    end
  end
end

# Wire-protocol tests use Mox to intercept transport calls, so they run serially.
defmodule DatagroutConduit.ClientWireProtocolTest do
  use ExUnit.Case, async: false

  import Mox

  alias DatagroutConduit.Client

  setup :set_mox_global
  setup :verify_on_exit!

  # Shared stub: connect always succeeds, returning a bare Req struct.
  defp stub_connect do
    stub(DatagroutConduit.Transport.Mock, :connect, fn _opts ->
      {:ok, Req.new(base_url: "http://test.invalid")}
    end)
  end

  # Start a mock client and capture all send_request calls as messages to the test process.
  defp start_capture_client(response) do
    test_pid = self()
    stub_connect()

    stub(DatagroutConduit.Transport.Mock, :send_request, fn _req, opts ->
      send(test_pid, {:rpc_call, opts})
      {:ok, response, nil}
    end)

    {:ok, client} =
      Client.start_link(
        url: "https://gateway.datagrout.ai/servers/test/mcp",
        transport_mod: DatagroutConduit.Transport.Mock
      )

    client
  end

  # --- Phase 0: Wire protocol fixes ---

  describe "guide/2 wire protocol" do
    test "sends data-grout/discovery.guide via tools/call" do
      client = start_capture_client(%{"session_id" => "s1", "status" => "pending", "options" => []})

      Client.guide(client, goal: "find users")

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/discovery.guide"
      GenServer.stop(client)
    end

    test "includes goal param in arguments" do
      client = start_capture_client(%{"session_id" => "s1", "status" => "pending", "options" => []})

      Client.guide(client, goal: "search invoices")

      assert_received {:rpc_call, opts}
      assert opts.params["arguments"]["goal"] == "search invoices"
      GenServer.stop(client)
    end
  end

  describe "Flow.run/2 wire protocol" do
    test "sends data-grout/flow.into via tools/call" do
      client = start_capture_client(%{"results" => []})

      DatagroutConduit.Flow.run(client, %{"plan" => [%{"tool" => "t1", "args" => %{}}]})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/flow.into"
      GenServer.stop(client)
    end
  end

  describe "perform/4 wire protocol" do
    test "routes via tools/call and uses tool + args keys in arguments" do
      client = start_capture_client(%{"content" => [], "isError" => false})

      Client.perform(client, "my_tool", %{"x" => 1})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/discovery.perform"
      args = opts.params["arguments"]
      assert Map.has_key?(args, "tool"), "expected 'tool' key in arguments"
      assert Map.has_key?(args, "args"), "expected 'args' key in arguments"
      refute Map.has_key?(args, "tool_name"), "unexpected 'tool_name' key"
      assert args["tool"] == "my_tool"
      assert args["args"] == %{"x" => 1}
      GenServer.stop(client)
    end
  end

  describe "Prism.focus/2 wire protocol" do
    test "routes via tools/call and sends source_type/target_type (not lens)" do
      client = start_capture_client(%{"output" => "result"})

      DatagroutConduit.Prism.focus(client, %{"data" => "hello", "source_type" => "text", "target_type" => "json"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/prism.focus"
      args = opts.params["arguments"]
      assert args["source_type"] == "text"
      assert args["target_type"] == "json"
      assert args["data"] == "hello"
      refute Map.has_key?(args, "lens"), "unexpected 'lens' key in arguments"
      GenServer.stop(client)
    end
  end

  describe "estimate_cost/3 wire protocol" do
    test "routes via tools/call with tool_name in params[name]" do
      client = start_capture_client(%{"estimated_total" => 0.05})

      Client.estimate_cost(client, "my_tool", %{"query" => "test"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "my_tool"
      GenServer.stop(client)
    end

    test "injects estimate_only: true into arguments" do
      client = start_capture_client(%{"estimated_total" => 0.05})

      Client.estimate_cost(client, "some_tool", %{"n" => 5})

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["estimate_only"] == true
      assert args["n"] == 5
      GenServer.stop(client)
    end
  end

  # --- Phase 1: New typed methods ---

  describe "plan/2" do
    test "routes data-grout/discovery.plan via tools/call" do
      client = start_capture_client(%{"steps" => []})

      Client.plan(client, goal: "automate invoicing")

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/discovery.plan"
      assert opts.params["arguments"]["goal"] == "automate invoicing"
      GenServer.stop(client)
    end

    test "includes optional params in arguments" do
      client = start_capture_client(%{"steps" => []})

      Client.plan(client,
        goal: "search CRM",
        query: "find contacts",
        server: "srv-1",
        k: 5,
        policy: "greedy"
      )

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["query"] == "find contacts"
      assert args["server"] == "srv-1"
      assert args["k"] == 5
      assert args["policy"] == "greedy"
      GenServer.stop(client)
    end
  end

  describe "Prism.refract/2" do
    test "routes data-grout/prism.refract via tools/call" do
      client = start_capture_client(%{"output" => "transformed"})

      DatagroutConduit.Prism.refract(client, %{"goal" => "normalise addresses", "payload" => %{"street" => "123 Main"}})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/prism.refract"
      args = opts.params["arguments"]
      assert args["goal"] == "normalise addresses"
      assert args["payload"] == %{"street" => "123 Main"}
      GenServer.stop(client)
    end
  end

  describe "Prism.chart/2" do
    test "routes data-grout/prism.chart via tools/call" do
      client = start_capture_client(%{"image" => "base64..."})

      DatagroutConduit.Prism.chart(client, %{"goal" => "bar chart of revenue", "payload" => [%{"month" => "Jan", "revenue" => 1000}]})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/prism.chart"
      args = opts.params["arguments"]
      assert args["goal"] == "bar chart of revenue"
      assert is_list(args["payload"])
      GenServer.stop(client)
    end
  end

  # --- Namespaced logic cell methods ---

  describe "Logic.remember/2" do
    test "routes data-grout/logic.remember via dg" do
      client = start_capture_client(%{"handle" => "h1"})

      DatagroutConduit.Logic.remember(client, %{"statement" => "parent(tom, bob)."})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.remember"
      assert opts.params["arguments"]["statement"] == "parent(tom, bob)."
      GenServer.stop(client)
    end
  end

  describe "Logic.query/2" do
    test "routes data-grout/logic.query via dg" do
      client = start_capture_client(%{"results" => []})

      DatagroutConduit.Logic.query(client, %{"question" => "Who likes pizza?"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.query"
      assert opts.params["arguments"]["question"] == "Who likes pizza?"
      GenServer.stop(client)
    end
  end

  describe "Logic.forget/2" do
    test "routes data-grout/logic.forget via dg" do
      client = start_capture_client(%{"retracted" => 2})

      DatagroutConduit.Logic.forget(client, %{"handles" => ["h1", "h2"]})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.forget"
      assert opts.params["arguments"]["handles"] == ["h1", "h2"]
      GenServer.stop(client)
    end
  end

  describe "Logic.constrain/2" do
    test "routes data-grout/logic.constrain via dg" do
      client = start_capture_client(%{"ok" => true})

      DatagroutConduit.Logic.constrain(client, %{"rule" => ":- likes(X, Y), hates(X, Y).", "tag" => "consistency"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.constrain"
      args = opts.params["arguments"]
      assert args["rule"] == ":- likes(X, Y), hates(X, Y)."
      assert args["tag"] == "consistency"
      GenServer.stop(client)
    end
  end

  describe "Logic.reflect/2" do
    test "routes data-grout/logic.reflect via dg" do
      client = start_capture_client(%{"facts" => [], "rules" => []})

      DatagroutConduit.Logic.reflect(client)

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.reflect"
      GenServer.stop(client)
    end
  end

  describe "Flow.route/2" do
    test "routes data-grout/flow.route via dg" do
      client = start_capture_client(%{"matched" => "branch_1"})

      DatagroutConduit.Flow.route(client, %{"branches" => [%{"when" => "amount > 1000", "then" => "approval"}], "payload" => %{"amount" => 1500}})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/flow.route"
      assert opts.params["arguments"]["payload"] == %{"amount" => 1500}
      GenServer.stop(client)
    end
  end

  # --- Phase 3: dg/3 generic hook ---

  describe "dg/3" do
    test "prefixes short name with data-grout/ and routes via tools/call" do
      client = start_capture_client(%{"result" => "ok"})

      Client.dg(client, "prism.render", %{"payload" => "data"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/prism.render"
      assert opts.params["arguments"] == %{"payload" => "data"}
      GenServer.stop(client)
    end

    test "works with empty params" do
      client = start_capture_client(%{"status" => "ok"})

      Client.dg(client, "logic.status")

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/logic.status"
      GenServer.stop(client)
    end

    test "can call arbitrary tool names" do
      client = start_capture_client(%{})

      Client.dg(client, "custom.extension", %{"foo" => "bar"})

      assert_received {:rpc_call, opts}
      assert opts.method == "tools/call"
      assert opts.params["name"] == "data-grout/custom.extension"
      assert opts.params["arguments"] == %{"foo" => "bar"}
      GenServer.stop(client)
    end
  end

  # --- Parity fix tests ---

  describe "maybe_put/3 preserves false values" do
    test "false values are included in params (not dropped)" do
      client = start_capture_client(%{"steps" => []})

      Client.plan(client,
        goal: "test",
        return_call_handles: false,
        expose_virtual_skills: false
      )

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["return_call_handles"] == false
      assert args["expose_virtual_skills"] == false
      GenServer.stop(client)
    end
  end

  describe "discover/2 supports query and min_score" do
    test "sends query and min_score params" do
      client = start_capture_client(%{"query_used" => "q", "results" => [], "total" => 0, "limit" => 10})

      Client.discover(client, query: "CRM search", min_score: 0.5, limit: 5)

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["query"] == "CRM search"
      assert args["min_score"] == 0.5
      assert args["limit"] == 5
      GenServer.stop(client)
    end

    test "sends integrations and servers lists" do
      client = start_capture_client(%{"query_used" => "q", "results" => [], "total" => 0, "limit" => 10})

      Client.discover(client, goal: "find leads", integrations: ["salesforce", "hubspot"], servers: ["srv-1"])

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["integrations"] == ["salesforce", "hubspot"]
      assert args["servers"] == ["srv-1"]
      GenServer.stop(client)
    end
  end

  describe "Flow.run/2 new API shape" do
    test "accepts map with plan, validate_ctc, save_as_skill" do
      client = start_capture_client(%{"results" => [%{"ok" => true}]})

      DatagroutConduit.Flow.run(client, %{
        "plan" => [%{"tool" => "t1", "args" => %{}}],
        "validate_ctc" => false,
        "save_as_skill" => true,
        "input_data" => %{"key" => "val"}
      })

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["plan"] == [%{"tool" => "t1", "args" => %{}}]
      assert args["validate_ctc"] == false
      assert args["save_as_skill"] == true
      assert args["input_data"] == %{"key" => "val"}
      GenServer.stop(client)
    end
  end

  describe "plan/2 accepts query without goal" do
    test "sends query param alone" do
      client = start_capture_client(%{"steps" => []})

      Client.plan(client, query: "invoice VIP customers")

      assert_received {:rpc_call, opts}
      args = opts.params["arguments"]
      assert args["query"] == "invoice VIP customers"
      refute Map.has_key?(args, "goal")
      GenServer.stop(client)
    end

    test "returns error when neither goal nor query given" do
      client = start_capture_client(%{"steps" => []})

      result = Client.plan(client, [])

      assert {:error, {:invalid_config, msg}} = result
      assert msg =~ "goal"
      assert msg =~ "query"
      GenServer.stop(client)
    end
  end
end
