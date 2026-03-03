# frozen_string_literal: true

require "json"
require "logger"

module DatagroutConduit
  # Main Conduit client. Connects to remote MCP / JSONRPC servers over HTTP,
  # sends requests, and parses responses. This is purely a client library —
  # it does NOT run a server or accept connections.
  class Client
    PROTOCOL_VERSION = "2025-03-26"
    CLIENT_NAME = "datagrout-conduit-ruby"

    attr_reader :transport, :server_info, :use_intelligent_interface

    def initialize(url:, auth: {}, transport: :mcp, identity: nil, identity_dir: nil,
                   use_intelligent_interface: nil, max_retries: 3, logger: nil, disable_mtls: false)
      @url = url
      @auth = auth
      @transport_mode = transport
      @identity = identity
      @identity_dir = identity_dir
      @disable_mtls = disable_mtls
      @max_retries = max_retries
      @initialized = false
      @server_info = nil
      @logger = logger || default_logger
      @is_dg = DatagroutConduit.dg_url?(url)
      @dg_warned = false

      @use_intelligent_interface = if use_intelligent_interface.nil?
                                     @is_dg
                                   else
                                     use_intelligent_interface
                                   end

      resolve_identity!
      @transport = build_transport
    end

    # Bootstrap an mTLS identity: discover existing or register a new one.
    #
    # Checks the auto-discovery chain first. If an existing identity is found
    # and not near expiry it is used as-is. Otherwise, a new keypair is
    # generated, registered with DataGrout using the provided bearer token,
    # saved to the identity directory, and loaded as the active identity.
    #
    # After the first successful bootstrap the identity is persisted locally
    # and auto-discovered on subsequent runs — no token or API key is needed.
    def self.bootstrap_identity(url:, auth_token:, name: "conduit-client", identity_dir: nil)
      dir = identity_dir || Registration.default_identity_dir || File.join(Dir.home, ".conduit")

      identity = Identity.try_discover(override_dir: dir)
      if identity && !identity.needs_rotation?
        return new(url: url, identity: identity)
      end

      private_pem, public_pem = Registration.generate_keypair
      reg = Registration.register_identity(
        public_pem,
        auth_token: auth_token,
        name: name
      )
      Registration.save_identity(reg.cert_pem, private_pem, dir, ca_pem: reg.ca_cert_pem)

      ca_path = reg.ca_cert_pem ? File.join(dir, "ca.pem") : nil
      identity = Identity.from_paths(
        File.join(dir, "identity.pem"),
        File.join(dir, "identity_key.pem"),
        ca_path: ca_path
      )

      new(url: url, identity: identity)
    end

    # Bootstrap an mTLS identity using OAuth 2.1 +client_credentials+.
    #
    # Same flow as {.bootstrap_identity} but obtains the bearer token via
    # OAuth client_credentials exchange first.
    def self.bootstrap_identity_oauth(url:, client_id:, client_secret:, name: "conduit-client", identity_dir: nil)
      provider = OAuth::TokenProvider.new(
        client_id: client_id,
        client_secret: client_secret,
        token_endpoint: OAuth::TokenProvider.derive_token_endpoint(url)
      )
      token = provider.get_token
      bootstrap_identity(url: url, auth_token: token, name: name, identity_dir: identity_dir)
    end

    def connect
      @transport.connect

      params = {
        "protocolVersion" => PROTOCOL_VERSION,
        "clientInfo" => { "name" => CLIENT_NAME, "version" => DatagroutConduit::VERSION },
        "capabilities" => { "tools" => {} }
      }

      response = @transport.send_request("initialize", params)

      if response.is_a?(Hash) && response["result"]
        result = response["result"]
        @server_info = result["serverInfo"]
      end

      @transport.send_request("notifications/initialized", nil, id: nil)
      @initialized = true
      self
    end

    def disconnect
      @transport.disconnect
      @initialized = false
      self
    end

    def initialized?
      @initialized
    end

    # ================================================================
    # Standard MCP Methods
    # ================================================================

    def list_tools
      ensure_initialized!

      all_tools = []
      cursor = nil

      loop do
        params = {}
        params["cursor"] = cursor if cursor

        response = send_with_retry("tools/list", params)
        result = response.is_a?(Hash) ? (response["result"] || response) : response

        tools_data = result["tools"] || []
        tools_data.each { |t| all_tools << Tool.from_hash(t) }

        cursor = result["nextCursor"] || result["next_cursor"]
        break unless cursor
      end

      if @use_intelligent_interface
        all_tools.reject! { |t| t.name.include?("@") }
      end

      all_tools
    end

    def call_tool(name, arguments = {})
      ensure_initialized!

      params = { "name" => name.to_s, "arguments" => normalize_hash(arguments) }
      response = send_with_retry("tools/call", params)
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      unwrap_content(result)
    end

    def list_resources
      ensure_initialized!

      response = send_with_retry("resources/list", {})
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      result["resources"] || []
    end

    def read_resource(uri)
      ensure_initialized!

      response = send_with_retry("resources/read", { "uri" => uri.to_s })
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      result["contents"] || []
    end

    def list_prompts
      ensure_initialized!

      response = send_with_retry("prompts/list", {})
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      result["prompts"] || []
    end

    def get_prompt(name, arguments = {})
      ensure_initialized!

      params = { "name" => name.to_s }
      params["arguments"] = normalize_hash(arguments) unless arguments.nil? || arguments.empty?

      response = send_with_retry("prompts/get", params)
      result = response.is_a?(Hash) ? (response["result"] || response) : response
      result["messages"] || []
    end

    # ================================================================
    # DataGrout Extensions
    # ================================================================

    # Semantic discovery — find tools by natural language goal or query.
    def discover(goal: nil, query: nil, limit: 10, min_score: 0.0,
                 integrations: [], servers: [])
      warn_if_not_dg("discover")
      ensure_initialized!

      params = { "limit" => limit, "min_score" => min_score }
      params["goal"] = goal if goal
      params["query"] = query if query
      params["integrations"] = integrations unless integrations.empty?
      params["servers"] = servers unless servers.empty?

      result = call_dg_tool("data-grout/discovery.discover", params)
      DiscoverResult.from_hash(result)
    end

    # Execute a tool call through the DataGrout intelligent interface.
    def perform(tool_name, arguments = {}, demux: false, demux_mode: nil)
      warn_if_not_dg("perform")
      ensure_initialized!

      params = { "tool" => tool_name.to_s, "args" => normalize_hash(arguments) }
      params["demux"] = demux if demux
      params["demux_mode"] = demux_mode if demux_mode

      call_dg_tool("data-grout/discovery.perform", params)
    end

    # Start or continue a guided workflow.
    def guide(goal: nil, session_id: nil, choice: nil)
      warn_if_not_dg("guide")
      ensure_initialized!

      params = {}
      params["goal"] = goal if goal
      params["session_id"] = session_id if session_id
      params["choice"] = choice if choice

      result = call_dg_tool("data-grout/discovery.guide", params)
      GuidedSession.new(self, GuideState.from_hash(result))
    end

    # Execute a multi-step workflow plan.
    def flow_into(plan, validate_ctc: true, save_as_skill: false, input_data: nil)
      warn_if_not_dg("flow_into")
      ensure_initialized!

      params = {
        "plan" => plan,
        "validate_ctc" => validate_ctc,
        "save_as_skill" => save_as_skill
      }
      params["input_data"] = input_data if input_data

      call_dg_tool("data-grout/flow.into", params)
    end

    # Semantic type transformation via Prism.
    def prism_focus(data:, source_type:, target_type:, source_annotations: nil, target_annotations: nil, context: nil)
      params = { "data" => data, "source_type" => source_type, "target_type" => target_type }
      params["source_annotations"] = source_annotations if source_annotations
      params["target_annotations"] = target_annotations if target_annotations
      params["context"] = context if context
      warn_if_not_dg("prism_focus")
      ensure_initialized!
      call_dg_tool("data-grout/prism.focus", params)
    end

    # Semantic discovery plan — return a ranked list of tools for a goal.
    # At least one of `goal:` or `query:` must be provided.
    def plan(goal: nil, query: nil, **opts)
      raise ArgumentError, "plan() requires at least one of goal: or query:" unless goal || query

      params = {}
      params["goal"] = goal if goal
      params["query"] = query if query
      params["server"] = opts[:server] if opts[:server]
      params["k"] = opts[:k] if opts[:k]
      params["policy"] = opts[:policy] if opts[:policy]
      params["have"] = opts[:have] if opts[:have]
      params["return_call_handles"] = opts[:return_call_handles] if opts.key?(:return_call_handles)
      params["expose_virtual_skills"] = opts[:expose_virtual_skills] if opts.key?(:expose_virtual_skills)
      params["model_overrides"] = opts[:model_overrides] if opts[:model_overrides]
      warn_if_not_dg("plan")
      ensure_initialized!
      call_dg_tool("data-grout/discovery.plan", params)
    end

    # Transform / reshape a payload via Prism.
    def refract(goal:, payload:, **opts)
      params = { "goal" => goal, "payload" => payload }
      params["verbose"] = opts[:verbose] if opts.key?(:verbose)
      params["chart"] = opts[:chart] if opts.key?(:chart)
      warn_if_not_dg("refract")
      ensure_initialized!
      call_dg_tool("data-grout/prism.refract", params)
    end

    # Generate a chart/visual from a payload via Prism.
    def chart(goal:, payload:, **opts)
      params = { "goal" => goal, "payload" => payload }
      params["format"] = opts[:format] if opts[:format]
      params["chart_type"] = opts[:chart_type] if opts[:chart_type]
      params["title"] = opts[:title] if opts[:title]
      params["x_label"] = opts[:x_label] if opts[:x_label]
      params["y_label"] = opts[:y_label] if opts[:y_label]
      params["width"] = opts[:width] if opts[:width]
      params["height"] = opts[:height] if opts[:height]
      warn_if_not_dg("chart")
      ensure_initialized!
      call_dg_tool("data-grout/prism.chart", params)
    end

    # Generate a document toward a natural-language goal.
    def render(goal:, payload: nil, format: "markdown", sections: nil, **opts)
      params = { "goal" => goal, "format" => format }.merge(normalize_hash(opts))
      params["payload"] = payload if payload
      params["sections"] = sections if sections
      warn_if_not_dg("render")
      ensure_initialized!
      call_dg_tool("data-grout/prism.render", params)
    end

    # Convert content to another format (no LLM). Supports csv, xlsx, pdf, json, etc.
    def export(content:, format:, style: nil, metadata: nil, **opts)
      params = { "content" => content, "format" => format }.merge(normalize_hash(opts))
      params["style"] = style if style
      params["metadata"] = metadata if metadata
      warn_if_not_dg("export")
      ensure_initialized!
      call_dg_tool("data-grout/prism.export", params)
    end

    # Pause workflow for human approval.
    def request_approval(action:, details: nil, reason: nil, context: nil, **opts)
      params = { "action" => action }.merge(normalize_hash(opts))
      params["details"] = details if details
      params["reason"] = reason if reason
      params["context"] = context if context
      warn_if_not_dg("request_approval")
      ensure_initialized!
      call_dg_tool("data-grout/flow.request-approval", params)
    end

    # Request user clarification for missing fields.
    def request_feedback(missing_fields:, reason:, current_data: nil, suggestions: nil, context: nil, **opts)
      params = { "missing_fields" => missing_fields, "reason" => reason }.merge(normalize_hash(opts))
      params["current_data"] = current_data if current_data
      params["suggestions"] = suggestions if suggestions
      params["context"] = context if context
      warn_if_not_dg("request_feedback")
      ensure_initialized!
      call_dg_tool("data-grout/flow.request-feedback", params)
    end

    # List recent tool executions for the current server.
    def execution_history(limit: 50, offset: 0, status: nil, refractions_only: false, **opts)
      params = { "limit" => limit, "offset" => offset, "refractions_only" => refractions_only }.merge(normalize_hash(opts))
      params["status"] = status if status
      warn_if_not_dg("execution_history")
      ensure_initialized!
      call_dg_tool("data-grout/inspect.execution-history", params)
    end

    # Get details for a specific execution.
    def execution_details(execution_id:)
      params = { "execution_id" => execution_id }
      warn_if_not_dg("execution_details")
      ensure_initialized!
      call_dg_tool("data-grout/inspect.execution-details", params)
    end

    # ================================================================
    # Logic Cell Methods
    # ================================================================

    # Assert a fact or statement into the logic cell.
    def remember(statement: nil, facts: nil, tag: nil)
      raise ArgumentError, "must provide statement or facts" unless statement || facts

      params = {}
      params["statement"] = statement if statement
      params["facts"] = facts if facts
      params["tag"] = tag if tag
      warn_if_not_dg("remember")
      ensure_initialized!
      call_dg_tool("data-grout/logic.remember", params)
    end

    # Query the logic cell by question or patterns.
    def query_cell(question: nil, patterns: nil, limit: nil)
      raise ArgumentError, "must provide question or patterns" unless question || patterns

      params = {}
      params["question"] = question if question
      params["patterns"] = patterns if patterns
      params["limit"] = limit if limit
      warn_if_not_dg("query_cell")
      ensure_initialized!
      call_dg_tool("data-grout/logic.query", params)
    end

    # Remove facts from the logic cell by handles or pattern.
    def forget(handles: nil, pattern: nil)
      raise ArgumentError, "must provide handles or pattern" unless handles || pattern

      params = {}
      params["handles"] = handles if handles
      params["pattern"] = pattern if pattern
      warn_if_not_dg("forget")
      ensure_initialized!
      call_dg_tool("data-grout/logic.forget", params)
    end

    # Assert a constraint rule into the logic cell.
    def constrain(rule:, tag: nil)
      params = { "rule" => rule }
      params["tag"] = tag if tag
      warn_if_not_dg("constrain")
      ensure_initialized!
      call_dg_tool("data-grout/logic.constrain", params)
    end

    # Reflect on known facts about an entity.
    def reflect(entity: nil, summary_only: false)
      params = { "summary_only" => summary_only }
      params["entity"] = entity if entity
      warn_if_not_dg("reflect")
      ensure_initialized!
      call_dg_tool("data-grout/logic.reflect", params)
    end

    # Call any DataGrout first-party tool by short name.
    # e.g. client.dg("prism.render", { payload: data, goal: "summary" })
    def dg(tool_short_name, params = {})
      ensure_initialized!
      call_dg_tool("data-grout/#{tool_short_name}", params)
    end

    # Estimate cost before execution.
    def estimate_cost(tool_name, arguments = {})
      ensure_initialized!

      args = normalize_hash(arguments).merge("estimate_only" => true)
      call_dg_tool(tool_name.to_s, args)
    end

    private

    def ensure_initialized!
      raise NotInitializedError unless @initialized
    end

    # Route a DataGrout first-party tool call through the standard MCP
    # `tools/call` path.  Both the MCP endpoint (/mcp) and the JSONRPC
    # endpoint (/rpc) dispatch on `tools/call`; the tool name goes in
    # `params["name"]` and the tool arguments in `params["arguments"]`.
    # The server resolves both versioned and unversioned tool names.
    def call_dg_tool(tool_name, arguments)
      params = { "name" => tool_name.to_s, "arguments" => normalize_hash(arguments) }
      response = send_with_retry("tools/call", params)
      raw = response.is_a?(Hash) ? (response["result"] || response) : response
      unwrap_content(raw)
    end

    # Unwrap the MCP content envelope that wraps tool results from both MCP and
    # JSONRPC transports: {"content" => [{"type" => "text", "text" => "<json>"}]}
    def unwrap_content(raw)
      return raw unless raw.is_a?(Hash)

      content = raw["content"]
      return raw unless content.is_a?(Array) && !content.empty?

      first = content.first
      return raw unless first.is_a?(Hash) && first["text"].is_a?(String)

      begin
        JSON.parse(first["text"])
      rescue JSON::ParserError
        { "text" => first["text"] }
      end
    end

    def send_with_retry(method, params)
      retries = @max_retries

      loop do
        response = @transport.send_request(method, params)
        return response
      rescue McpError => e
        if not_initialized_error?(e) && retries > 0
          @logger.warn { "Server not initialized, retrying (#{retries} left)..." }
          connect
          retries -= 1
          sleep 0.5
        else
          raise
        end
      end
    end

    def not_initialized_error?(error)
      return true if error.code == McpCodes::NOT_INITIALIZED
      return true if error.message.include?("not initialized")

      false
    end

    def build_transport
      case @transport_mode
      when :mcp, "mcp"
        Transport::Mcp.new(url: @url, auth: @auth, identity: @identity)
      when :jsonrpc, "jsonrpc"
        # When the user passes an MCP URL (ending in /mcp) and selects JSONRPC
        # transport, transparently rewrite the path to the DG JSONRPC endpoint.
        rpc_url = @url.end_with?("/mcp") ? @url.sub(%r{/mcp$}, "/rpc") : @url
        Transport::JsonRpc.new(url: rpc_url, auth: @auth, identity: @identity)
      else
        raise ConfigError, "Unknown transport: #{@transport_mode}. Use :mcp or :jsonrpc."
      end
    end

    def resolve_identity!
      return if @identity
      return if @disable_mtls
      return unless @is_dg

      @identity = Identity.try_discover(override_dir: @identity_dir)
    end

    def warn_if_not_dg(method_name)
      return if @is_dg
      return if @dg_warned

      @dg_warned = true
      @logger.warn do
        "[conduit] `#{method_name}` is a DataGrout-specific extension. " \
          "The connected server may not support it. " \
          "Standard MCP methods (list_tools, call_tool, ...) work on any server."
      end
    end

    def normalize_hash(hash)
      return {} if hash.nil?

      hash.each_with_object({}) do |(k, v), memo|
        memo[k.to_s] = v
      end
    end

    def default_logger
      logger = Logger.new($stderr)
      logger.level = Logger::WARN
      logger.progname = "conduit"
      logger
    end
  end

  # Wrapper around an active guided workflow session.
  class GuidedSession
    attr_reader :state

    def initialize(client, state)
      @client = client
      @state = state
    end

    def session_id
      @state.session_id
    end

    def status
      @state.status
    end

    def options
      @state.options
    end

    def result
      @state.result
    end

    def step
      @state.step
    end

    # Make a choice and advance the workflow.
    def choose(option_id)
      @client.guide(session_id: session_id, choice: option_id.to_s)
    end

    # Check if the workflow is completed and return the result.
    def complete
      if status == "completed" && result
        return result
      end

      raise Error, "Workflow not complete (status: #{status}). Call choose() with an option."
    end
  end
end
