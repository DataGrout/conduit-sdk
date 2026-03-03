# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  SERVER_URL = "https://gateway.datagrout.ai/servers/test-uuid/mcp"
  EXTERNAL_URL = "https://example.com/mcp"

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def test_initialize_with_dg_url
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert client.use_intelligent_interface
  end

  def test_initialize_with_external_url
    client = DatagroutConduit::Client.new(url: EXTERNAL_URL, auth: { bearer: "tok" })
    refute client.use_intelligent_interface
  end

  def test_initialize_raises_on_unknown_transport
    assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" }, transport: :grpc)
    end
  end

  def test_not_initialized_raises_on_list_tools
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(DatagroutConduit::NotInitializedError) do
      client.list_tools
    end
  end

  def test_connect_and_list_tools
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "initialize" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0",
          "id" => "1",
          "result" => {
            "protocolVersion" => "2025-03-26",
            "serverInfo" => { "name" => "test-server", "version" => "1.0.0" },
            "capabilities" => {}
          }
        })
      )

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "notifications/initialized" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "result" => {} })
      )

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/list" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0",
          "id" => "2",
          "result" => {
            "tools" => [
              { "name" => "discover", "description" => "DG semantic search" },
              { "name" => "perform", "description" => "DG tool execution" },
              { "name" => "salesforce@1/get_lead@1", "description" => "Get a lead" }
            ]
          }
        })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect

    assert client.initialized?
    assert_equal "test-server", client.server_info["name"]

    tools = client.list_tools
    assert_equal 2, tools.size
    assert_equal "discover", tools[0].name
    assert_equal "perform", tools[1].name
  end

  def test_list_tools_without_intelligent_interface
    stub_initialize!
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/list" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0",
          "id" => "2",
          "result" => {
            "tools" => [
              { "name" => "discover", "description" => "DG semantic search" },
              { "name" => "salesforce@1/get_lead@1", "description" => "Get a lead" }
            ]
          }
        })
      )

    client = DatagroutConduit::Client.new(
      url: SERVER_URL, auth: { bearer: "tok" },
      use_intelligent_interface: false
    )
    client.connect

    tools = client.list_tools
    assert_equal 2, tools.size
  end

  def test_call_tool
    stub_initialize!
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0",
          "id" => "2",
          "result" => {
            "content" => [
              { "type" => "text", "text" => "Lead: John Doe" }
            ]
          }
        })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect

    result = client.call_tool("get_lead", { id: "123" })
    assert_equal "Lead: John Doe", result["text"]
  end

  def test_disconnect
    stub_initialize!

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    assert client.initialized?

    client.disconnect
    refute client.initialized?
  end

  def test_mcp_error_response
    stub_initialize!
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/list" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0",
          "id" => "2",
          "error" => { "code" => -32601, "message" => "Method not found" }
        })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect

    err = assert_raises(DatagroutConduit::McpError) { client.list_tools }
    assert_equal(-32601, err.code)
    assert_includes err.message, "Method not found"
  end

  def test_rate_limit_error
    stub_initialize!
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/list" }
      .to_return(
        status: 429,
        headers: {
          "Content-Type" => "application/json",
          "X-RateLimit-Used" => "50",
          "X-RateLimit-Limit" => "50"
        },
        body: "{}"
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect

    err = assert_raises(DatagroutConduit::RateLimitedError) { client.list_tools }
    assert_equal 50, err.used
    assert_equal 50, err.limit
  end

  def test_jsonrpc_transport
    jsonrpc_url = "https://gateway.datagrout.ai/servers/test-uuid/jsonrpc"

    stub_request(:post, jsonrpc_url)
      .with { |req| body = JSON.parse(req.body); body["method"] == "initialize" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0", "id" => "1",
          "result" => {
            "protocolVersion" => "2025-03-26",
            "serverInfo" => { "name" => "jsonrpc-server", "version" => "1.0.0" },
            "capabilities" => {}
          }
        })
      )

    stub_request(:post, jsonrpc_url)
      .with { |req| body = JSON.parse(req.body); body["method"] == "notifications/initialized" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "result" => {} })
      )

    client = DatagroutConduit::Client.new(
      url: jsonrpc_url, auth: { bearer: "tok" }, transport: :jsonrpc
    )
    client.connect
    assert client.initialized?
  end

  def test_initialize_with_disable_mtls
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" }, disable_mtls: true)
    assert client.use_intelligent_interface
  end

  def test_initialize_with_identity_dir
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" }, identity_dir: "/tmp/certs")
    assert client.use_intelligent_interface
  end

  def test_mcp_transport_sends_accept_header
    stub_request(:post, SERVER_URL)
      .with { |req| req.headers["Accept"] == "application/json, text/event-stream" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0", "id" => "1",
          "result" => {
            "protocolVersion" => "2025-03-26",
            "serverInfo" => { "name" => "test-server", "version" => "1.0.0" },
            "capabilities" => {}
          }
        })
      )

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "notifications/initialized" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    assert client.initialized?
  end

  def test_mcp_session_id_tracking
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "initialize" }
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "Mcp-Session-Id" => "sess-abc-123"
        },
        body: JSON.generate({
          "jsonrpc" => "2.0", "id" => "1",
          "result" => {
            "protocolVersion" => "2025-03-26",
            "serverInfo" => { "name" => "test-server", "version" => "1.0.0" },
            "capabilities" => {}
          }
        })
      )

    stub_request(:post, SERVER_URL)
      .with { |req|
        body = JSON.parse(req.body)
        body["method"] == "notifications/initialized" &&
          req.headers["Mcp-Session-Id"] == "sess-abc-123"
      }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    assert client.initialized?
  end

  def test_handle_202_accepted
    stub_initialize!

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "notifications/initialized" }
      .to_return(status: 202, body: "")

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    assert client.initialized?
  end

  def test_sse_response_parsing
    stub_initialize!

    sse_body = "data: {\"jsonrpc\":\"2.0\",\"id\":\"2\",\"result\":{\"tools\":[{\"name\":\"my-tool\",\"description\":\"A tool\"}]}}\n\n"

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/list" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect

    tools = client.list_tools
    assert_equal 1, tools.size
    assert_equal "my-tool", tools[0].name
  end

  # ================================================================
  # Phase 0: Wire Protocol Bug Fixes
  # ================================================================

  def test_perform_sends_tool_and_args_keys
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/discovery.perform" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.perform("my_tool", { "id" => "42" })

    refute_nil captured
    assert_equal "tools/call", captured["method"]
    assert_equal "data-grout/discovery.perform", captured["params"]["name"]
    args = captured["params"]["arguments"]
    assert_equal "my_tool", args["tool"]
    assert_equal({ "id" => "42" }, args["args"])
    refute args.key?("tool_name"), "should not send tool_name"
  end

  def test_prism_focus_sends_source_and_target_type
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/prism.focus" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.prism_focus(data: "hello", source_type: "text", target_type: "embedding")

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "hello", args["data"]
    assert_equal "text", args["source_type"]
    assert_equal "embedding", args["target_type"]
    refute args.key?("lens"), "should not send lens"
  end

  def test_prism_focus_sends_optional_annotations
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/prism.focus" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.prism_focus(
      data: "blob",
      source_type: "json",
      target_type: "csv",
      source_annotations: ["a"],
      target_annotations: ["b"],
      context: "testing"
    )

    args = captured["params"]["arguments"]
    assert_equal ["a"], args["source_annotations"]
    assert_equal ["b"], args["target_annotations"]
    assert_equal "testing", args["context"]
  end

  # ================================================================
  # Phase 1: New Typed Methods
  # ================================================================

  def test_plan_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/discovery.plan" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.plan(goal: "find leads in Salesforce", k: 5, policy: "cheap")

    refute_nil captured
    assert_equal "data-grout/discovery.plan", captured["params"]["name"]
    args = captured["params"]["arguments"]
    assert_equal "find leads in Salesforce", args["goal"]
    assert_equal 5, args["k"]
    assert_equal "cheap", args["policy"]
  end

  def test_refract_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/prism.refract" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.refract(goal: "summarise", payload: { text: "hello world" }, verbose: true)

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "summarise", args["goal"]
    assert_equal({ "text" => "hello world" }, args["payload"])
    assert_equal true, args["verbose"]
  end

  def test_chart_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/prism.chart" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.chart(goal: "bar chart of sales", payload: [1, 2, 3], chart_type: "bar", title: "Sales")

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "bar chart of sales", args["goal"]
    assert_equal [1, 2, 3], args["payload"]
    assert_equal "bar", args["chart_type"]
    assert_equal "Sales", args["title"]
  end

  # ================================================================
  # Phase 2: Logic Cell Methods
  # ================================================================

  def test_remember_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/logic.remember" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.remember(statement: "The sky is blue", tag: "facts")

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "The sky is blue", args["statement"]
    assert_equal "facts", args["tag"]
  end

  def test_remember_raises_without_statement_or_facts
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(ArgumentError) { client.remember }
  end

  def test_query_cell_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/logic.query" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.query_cell(question: "What colour is the sky?", limit: 5)

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "What colour is the sky?", args["question"]
    assert_equal 5, args["limit"]
  end

  def test_query_cell_raises_without_question_or_patterns
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(ArgumentError) { client.query_cell }
  end

  def test_forget_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/logic.forget" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.forget(handles: ["h1", "h2"])

    refute_nil captured
    assert_equal ["h1", "h2"], captured["params"]["arguments"]["handles"]
  end

  def test_forget_raises_without_handles_or_pattern
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(ArgumentError) { client.forget }
  end

  def test_constrain_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/logic.constrain" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.constrain(rule: "never store PII", tag: "privacy")

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "never store PII", args["rule"]
    assert_equal "privacy", args["tag"]
  end

  def test_reflect_sends_correct_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/logic.reflect" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.reflect(entity: "user:42", summary_only: true)

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "user:42", args["entity"]
    assert_equal true, args["summary_only"]
  end

  # ================================================================
  # Phase 3: Generic dg() Hook
  # ================================================================

  def test_dg_sends_namespaced_method
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/prism.render" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => { "output" => "rendered" } })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.dg("prism.render", { payload: "data", goal: "summary" })

    refute_nil captured
    assert_equal "tools/call", captured["method"]
    assert_equal "data-grout/prism.render", captured["params"]["name"]
    args = captured["params"]["arguments"]
    assert_equal "data", args["payload"]
    assert_equal "summary", args["goal"]
  end

  def test_dg_raises_when_not_initialized
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(DatagroutConduit::NotInitializedError) do
      client.dg("prism.render", {})
    end
  end

  private

  def stub_initialize!
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "initialize" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "jsonrpc" => "2.0", "id" => "1",
          "result" => {
            "protocolVersion" => "2025-03-26",
            "serverInfo" => { "name" => "test-server", "version" => "1.0.0" },
            "capabilities" => {}
          }
        })
      )

    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "notifications/initialized" }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "result" => {} })
      )
  end

  # ================================================================
  # Parity fix tests
  # ================================================================

  def test_plan_with_query_only
    stub_initialize!
    captured = nil
    stub_request(:post, SERVER_URL)
      .with { |req| body = JSON.parse(req.body); body["method"] == "tools/call" && body.dig("params", "name") == "data-grout/discovery.plan" && (captured = body) }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "jsonrpc" => "2.0", "id" => "2", "result" => {} })
      )

    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    client.connect
    client.plan(query: "invoice VIP customers", k: 3)

    refute_nil captured
    args = captured["params"]["arguments"]
    assert_equal "invoice VIP customers", args["query"]
    assert_nil args["goal"]
    assert_equal 3, args["k"]
  end

  def test_plan_raises_without_goal_or_query
    client = DatagroutConduit::Client.new(url: SERVER_URL, auth: { bearer: "tok" })
    assert_raises(ArgumentError) do
      client.plan
    end
  end
end
