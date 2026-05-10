defmodule DatagroutConduit.Client do
  @moduledoc """
  MCP/JSONRPC client GenServer.

  Manages connection state (URL, auth tokens, request IDs, mTLS identity)
  and provides high-level methods for MCP protocol operations and DataGrout
  extensions.

  ## Usage

      {:ok, client} = DatagroutConduit.Client.start_link(
        url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
        auth: {:bearer, "token"}
      )

      {:ok, tools} = DatagroutConduit.Client.list_tools(client)
      {:ok, result} = DatagroutConduit.Client.call_tool(client, "tool-name", %{arg: "val"})

  ## Options

    * `:url` - Remote server URL (required)
    * `:auth` - Authentication: `{:bearer, token}`, `{:api_key, key}`, `{:basic, user, pass}`, or `{:oauth, pid}`
    * `:transport` - `:mcp` (default) or `:jsonrpc`
    * `:transport_mod` - Override transport module directly (e.g. for testing)
    * `:identity` - `%DatagroutConduit.Identity{}` for mTLS (auto-discovered for DG URLs)
    * `:use_intelligent_interface` - Filter `@`-containing tools from `list_tools` (default: `true` for DG URLs)
    * `:name` - GenServer registration name
  """

  use GenServer

  require Logger

  alias DatagroutConduit.{Identity, Types}
  alias DatagroutConduit.Transport

  @type auth ::
          {:bearer, String.t()}
          | {:api_key, String.t()}
          | {:basic, String.t(), String.t()}
          | {:oauth, GenServer.server()}
          | nil

  defstruct [
    :url,
    :auth,
    :transport_mod,
    :transport_req,
    :identity,
    :use_intelligent_interface,
    :dg_warned,
    :mcp_session_id,
    # Non-nil when using :websocket transport.
    :ws_pid,
    request_id: 0
  ]

  # --- Public API ---

  @doc "Starts the client GenServer. See module docs for options."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Lists tools available on the remote server."
  @spec list_tools(GenServer.server()) :: {:ok, [Types.Tool.t()]} | {:error, term()}
  def list_tools(client) do
    GenServer.call(client, :list_tools, 60_000)
  end

  @doc "Calls a tool on the remote server."
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, Types.ToolResult.t()} | {:error, term()}
  def call_tool(client, name, arguments \\ %{}) do
    GenServer.call(client, {:call_tool, name, arguments}, 120_000)
  end

  @doc "Lists resources available on the remote server."
  @spec list_resources(GenServer.server()) :: {:ok, [Types.Resource.t()]} | {:error, term()}
  def list_resources(client) do
    GenServer.call(client, :list_resources, 60_000)
  end

  @doc "Reads a resource from the remote server."
  @spec read_resource(GenServer.server(), String.t()) :: {:ok, [Types.ResourceContent.t()]} | {:error, term()}
  def read_resource(client, uri) do
    GenServer.call(client, {:read_resource, uri}, 60_000)
  end

  @doc "Lists prompts available on the remote server."
  @spec list_prompts(GenServer.server()) :: {:ok, [Types.Prompt.t()]} | {:error, term()}
  def list_prompts(client) do
    GenServer.call(client, :list_prompts, 60_000)
  end

  @doc "Gets a prompt with the given arguments."
  @spec get_prompt(GenServer.server(), String.t(), map()) :: {:ok, [Types.PromptMessage.t()]} | {:error, term()}
  def get_prompt(client, name, arguments \\ %{}) do
    GenServer.call(client, {:get_prompt, name, arguments}, 60_000)
  end

  # --- DataGrout Extensions ---

  @doc "Semantic discovery: find tools matching a goal."
  @spec discover(GenServer.server(), keyword()) :: {:ok, Types.DiscoverResult.t()} | {:error, term()}
  def discover(client, opts) do
    GenServer.call(client, {:discover, opts}, 60_000)
  end

  @doc "Execute a tool with DG extensions (demux, refract, chart)."
  @spec perform(GenServer.server(), String.t(), map(), keyword()) :: {:ok, Types.ToolResult.t()} | {:error, term()}
  def perform(client, tool_name, args \\ %{}, opts \\ []) do
    GenServer.call(client, {:perform, tool_name, args, opts}, 120_000)
  end

  @doc """
  Execute multiple tool calls in a single gateway request.

  Each element should be a map with `"tool"` and `"args"` keys.
  Returns a list of results in the same order as the input calls.

  ## Example

      calls = [
        %{"tool" => "data-grout/data.count", "args" => %{"data" => [1, 2, 3]}},
        %{"tool" => "data-grout/data.keys",  "args" => %{"data" => %{"a" => 1}}}
      ]
      {:ok, results} = Client.perform_batch(client, calls)
  """
  @spec perform_batch(GenServer.server(), list(map())) :: {:ok, list()} | {:error, term()}
  def perform_batch(client, calls) when is_list(calls) do
    GenServer.call(client, {:perform_batch, calls}, 120_000)
  end

  @doc """
  Start or continue a guided execution session.

  ## Options

    * `:goal` - Natural language description (required for new sessions)
    * `:session_id` - Continue an existing session
    * `:choice` - Make a choice in the current session
  """
  @spec guide(GenServer.server(), keyword()) :: {:ok, Types.GuideState.t()} | {:error, term()}
  def guide(client, opts) do
    GenServer.call(client, {:guide, opts}, 60_000)
  end

  @doc "Estimate cost of calling a tool without executing it."
  @spec estimate_cost(GenServer.server(), String.t(), map()) :: {:ok, Types.CreditEstimate.t()} | {:error, term()}
  def estimate_cost(client, tool_name, args \\ %{}) do
    GenServer.call(client, {:estimate_cost, tool_name, args}, 30_000)
  end

  @doc """
  Plan tool execution for a goal using semantic discovery.

  At least one of `:goal` or `:query` must be provided.

  ## Options

    * `:goal` - Natural language goal
    * `:query` - Semantic search query
    * `:server` - Restrict to a specific server
    * `:k` - Number of candidates to consider
    * `:policy` - Execution policy
    * `:have` - Tools or data already available
    * `:return_call_handles` - Include call handles in response
    * `:expose_virtual_skills` - Include virtual skills in candidates
    * `:model_overrides` - Override model selection
  """
  @spec plan(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(client, opts) do
    GenServer.call(client, {:plan, opts}, 60_000)
  end

  # --- Generic Hook ---

  @doc """
  Call any DataGrout first-party tool by its short name.

  The short name (e.g. `"prism.render"`) is automatically prefixed with `data-grout/`.

      DatagroutConduit.Client.dg(client, "prism.render", %{"payload" => data})
  """
  @spec dg(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def dg(client, tool_short_name, params \\ %{}) do
    GenServer.call(client, {:dg, tool_short_name, params}, 60_000)
  end

  # --- WebSocket Push Subscriptions ---

  @doc """
  Subscribe to a server-push topic (WebSocket transport only).

  Requires `transport: :websocket` when starting the client.

  Events arrive as `{:subscription_event, subscription_id, event}` messages
  in the calling process's mailbox, where `event` is a map with `:event` and
  `:data` keys.

      {:ok, sub_id} = DatagroutConduit.Client.subscribe(client, "agents.my-agent-id.events")
      receive do
        {:subscription_event, ^sub_id, %{event: e, data: d}} -> IO.inspect({e, d})
      end
      :ok = DatagroutConduit.Client.unsubscribe(client, sub_id)

  Returns `{:ok, subscription_id}` or `{:error, :not_ws_transport}`.
  """
  @spec subscribe(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(client, topic) do
    GenServer.call(client, {:subscribe, topic}, 15_000)
  end

  @doc """
  Cancel a server-side push subscription.

  Requires `transport: :websocket`. Returns `:ok`.
  """
  @spec unsubscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(client, subscription_id) do
    GenServer.call(client, {:unsubscribe, subscription_id}, 10_000)
  end

  # --- Bootstrap ---

  @doc """
  Bootstrap an mTLS identity and start a client with it.

  Checks for an existing identity first. If found and not near expiry,
  starts a client with it. Otherwise generates a keypair, registers with
  DataGrout, saves the identity to disk, and starts a client.

  ## Options

    * `:url` - Remote server URL (required)
    * `:auth_token` - Bearer token for registration (required for first run)
    * `:name` - Human-readable label (default: `"conduit-client"`)
    * `:identity_dir` - Directory to store identity files (default: `~/.conduit/`)
    * `:endpoint` - Registration endpoint (default: DG substrate endpoint)
    * `:threshold_days` - Days before expiry to trigger rotation (default: 7)
    * All other options are forwarded to `start_link/1`
  """
  @spec bootstrap_identity(keyword()) :: {:ok, pid()} | {:error, term()}
  def bootstrap_identity(opts) do
    {auth_token, opts} = Keyword.pop(opts, :auth_token)
    {reg_name, opts} = Keyword.pop(opts, :name, "conduit-client")
    {identity_dir, opts} = Keyword.pop_lazy(opts, :identity_dir, fn ->
      DatagroutConduit.Registration.default_identity_dir()
    end)
    {endpoint, opts} = Keyword.pop(opts, :endpoint)
    {threshold_days, opts} = Keyword.pop(opts, :threshold_days, 7)

    existing = Identity.try_discover(override_dir: identity_dir)

    identity =
      if existing && !Identity.needs_rotation?(existing, threshold_days: threshold_days) do
        existing
      else
        case do_register(auth_token, reg_name, identity_dir, endpoint) do
          {:ok, identity} -> identity
          {:error, _} = err -> err
        end
      end

    case identity do
      {:error, _} = err -> err
      %Identity{} = id -> start_link(Keyword.put(opts, :identity, id))
    end
  end

  @doc """
  Bootstrap an mTLS identity using OAuth client_credentials.

  Like `bootstrap_identity/1` but performs the OAuth token exchange
  inline instead of requiring a pre-obtained bearer token.

  ## Options

    * `:url` - Remote server URL (required)
    * `:client_id` - OAuth client ID (required)
    * `:client_secret` - OAuth client secret (required)
    * `:token_endpoint` - OAuth token endpoint (derived from `:url` if absent)
    * `:scope` - OAuth scope (optional)
    * All other options from `bootstrap_identity/1`
  """
  @spec bootstrap_identity_oauth(keyword()) :: {:ok, pid()} | {:error, term()}
  def bootstrap_identity_oauth(opts) do
    {client_id, opts} = Keyword.pop!(opts, :client_id)
    {client_secret, opts} = Keyword.pop!(opts, :client_secret)
    {scope, opts} = Keyword.pop(opts, :scope)

    url = Keyword.fetch!(opts, :url)

    {token_endpoint, opts} = Keyword.pop_lazy(opts, :token_endpoint, fn ->
      DatagroutConduit.OAuth.derive_token_endpoint(url)
    end)

    body =
      %{
        "grant_type" => "client_credentials",
        "client_id" => client_id,
        "client_secret" => client_secret
      }
      |> then(fn b -> if scope, do: Map.put(b, "scope", scope), else: b end)

    case Req.post(token_endpoint, form: body) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        case resp["access_token"] do
          nil -> {:error, {:oauth_error, "no access_token in response"}}
          token -> bootstrap_identity(Keyword.put(opts, :auth_token, token))
        end

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error, {:oauth_error, status, resp}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  Bootstrap by performing the autonomous DG onramp flow.

  The all-in-one flow: onramp (no prior credentials required) →
  OAuth token exchange → mTLS identity registration and persistence.

  On subsequent runs the saved mTLS identity is auto-discovered and
  no credentials are needed.

  ## Options

    * `:opts` - `%DatagroutConduit.Onramp.OnrampOptions{}` (required)
    * `:url` - MCP server URL; required when the onramp response omits `mcp_url`
    * `:name` - Human-readable identity label (default: `"conduit-client"`)
    * `:identity_dir` - Custom directory for identity persistence
    * All other options from `bootstrap_identity/1`
  """
  @spec bootstrap_onramp(keyword()) :: {:ok, pid()} | {:error, term()}
  def bootstrap_onramp(opts) do
    {onramp_opts, opts} = Keyword.pop!(opts, :opts)
    {url, opts} = Keyword.pop(opts, :url)
    {name, opts} = Keyword.pop(opts, :name, "conduit-client")
    {identity_dir, _opts_rest} = Keyword.pop_lazy(opts, :identity_dir, fn ->
      DatagroutConduit.Registration.default_identity_dir()
    end)

    existing = DatagroutConduit.Identity.try_discover(override_dir: identity_dir)

    if existing && !DatagroutConduit.Identity.needs_rotation?(existing) do
      if is_nil(url), do: {:error, :url_required_for_existing_identity}, else:
        start_link(Keyword.merge(opts, [url: url, identity: existing]))
    else
      case DatagroutConduit.Onramp.register_and_exchange(onramp_opts) do
        {:ok, {creds, token}} ->
          mcp_url = creds.mcp_url || url

          if is_nil(mcp_url) do
            {:error, :url_required_when_mcp_url_absent}
          else
            bootstrap_identity(
              Keyword.merge(opts, [
                url: mcp_url,
                auth_token: token,
                name: name,
                identity_dir: identity_dir
              ])
            )
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp do_register(auth_token, name, identity_dir, endpoint) do
    alias DatagroutConduit.Registration

    if auth_token == nil do
      {:error, :auth_token_required}
    else
      {:ok, {private_pem, public_pem}} = Registration.generate_keypair()

      reg_opts = [auth_token: auth_token, name: name]
      reg_opts = if endpoint, do: Keyword.put(reg_opts, :endpoint, endpoint), else: reg_opts

      case Registration.register_identity(public_pem, reg_opts) do
        {:ok, %Registration.RegistrationResponse{cert_pem: cert_pem, ca_cert_pem: ca_pem}} ->
          if identity_dir do
            Registration.save_identity(cert_pem, private_pem, ca_pem, identity_dir)
          end

          case Identity.from_pem(cert_pem, private_pem, ca_pem) do
            {:ok, identity} -> {:ok, identity}
            {:error, _} = err -> err
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    auth = Keyword.get(opts, :auth)
    transport = Keyword.get(opts, :transport, :mcp)
    is_dg = DatagroutConduit.is_dg_url?(url)

    identity =
      Keyword.get_lazy(opts, :identity, fn ->
        if is_dg, do: Identity.try_discover(), else: nil
      end)

    use_ii = Keyword.get(opts, :use_intelligent_interface, is_dg)

    if transport == :websocket do
      ws_opts = [url: url, auth: auth, identity: identity]

      case DatagroutConduit.Transport.Ws.start_link(ws_opts) do
        {:ok, ws_pid} ->
          state = %__MODULE__{
            url: url,
            auth: auth,
            transport_mod: nil,
            transport_req: nil,
            identity: identity,
            use_intelligent_interface: use_ii,
            dg_warned: false,
            ws_pid: ws_pid,
            request_id: 0
          }

          {:ok, state}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      transport_mod =
        Keyword.get(opts, :transport_mod) ||
          case transport do
            :jsonrpc -> Transport.JSONRPC
            _ -> Transport.MCP
          end

      resolved_auth = resolve_auth(auth)

      {:ok, req} = transport_mod.connect(%{url: url, identity: identity, auth: resolved_auth})

      state = %__MODULE__{
        url: url,
        auth: auth,
        transport_mod: transport_mod,
        transport_req: req,
        identity: identity,
        use_intelligent_interface: use_ii,
        dg_warned: false,
        ws_pid: nil,
        request_id: 0
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {id, state} = next_id(state)

    case send_rpc(state, "tools/list", %{}, id) do
      {:ok, result, state} ->
        tools =
          (result["tools"] || [])
          |> Enum.map(&Types.parse_tool/1)
          |> maybe_filter_intelligent(state.use_intelligent_interface)

        {:reply, {:ok, tools}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:call_tool, name, arguments}, _from, state) do
    {id, state} = next_id(state)
    params = %{"name" => name, "arguments" => stringify_keys(arguments)}

    case send_rpc(state, "tools/call", params, id) do
      {:ok, result, state} ->
        tool_result = %Types.ToolResult{
          content: result["content"] || [],
          is_error: result["isError"] == true,
          meta: result["_meta"] || result["_datagrout"] || %{}
        }

        {:reply, {:ok, tool_result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_resources, _from, state) do
    {id, state} = next_id(state)

    case send_rpc(state, "resources/list", %{}, id) do
      {:ok, result, state} ->
        resources = Enum.map(result["resources"] || [], &Types.parse_resource/1)
        {:reply, {:ok, resources}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:read_resource, uri}, _from, state) do
    {id, state} = next_id(state)

    case send_rpc(state, "resources/read", %{"uri" => uri}, id) do
      {:ok, result, state} ->
        contents = Enum.map(result["contents"] || [], &Types.parse_resource_content/1)
        {:reply, {:ok, contents}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_prompts, _from, state) do
    {id, state} = next_id(state)

    case send_rpc(state, "prompts/list", %{}, id) do
      {:ok, result, state} ->
        prompts = Enum.map(result["prompts"] || [], &Types.parse_prompt/1)
        {:reply, {:ok, prompts}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:get_prompt, name, arguments}, _from, state) do
    {id, state} = next_id(state)
    params = %{"name" => name, "arguments" => stringify_keys(arguments)}

    case send_rpc(state, "prompts/get", params, id) do
      {:ok, result, state} ->
        messages = Enum.map(result["messages"] || [], &Types.parse_prompt_message/1)
        {:reply, {:ok, messages}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  # --- WebSocket Push Handlers ---

  def handle_call({:subscribe, _topic}, _from, %{ws_pid: nil} = state) do
    {:reply, {:error, :not_ws_transport}, state}
  end

  def handle_call({:subscribe, topic}, _from, %{ws_pid: ws_pid} = state) do
    result = DatagroutConduit.Transport.Ws.subscribe(ws_pid, topic)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, _sub_id}, _from, %{ws_pid: nil} = state) do
    {:reply, {:error, :not_ws_transport}, state}
  end

  def handle_call({:unsubscribe, sub_id}, _from, %{ws_pid: ws_pid} = state) do
    result = DatagroutConduit.Transport.Ws.unsubscribe(ws_pid, sub_id)
    {:reply, result, state}
  end

  # --- DG Extension Handlers (direct JSON-RPC methods) ---

  def handle_call({:discover, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "discover")
    {id, state} = next_id(state)

    params =
      %{"limit" => Keyword.get(opts, :limit, 10)}
      |> maybe_put("goal", Keyword.get(opts, :goal))
      |> maybe_put("query", Keyword.get(opts, :query))
      |> maybe_put("min_score", Keyword.get(opts, :min_score))
      |> maybe_put("integrations", Keyword.get(opts, :integrations))
      |> maybe_put("servers", Keyword.get(opts, :servers))
      # Legacy single-value forms
      |> maybe_put("integration", Keyword.get(opts, :integration))
      |> maybe_put("server", Keyword.get(opts, :server))

    case call_dg_tool(state, "data-grout/discovery.discover", params, id) do
      {:ok, result, state} ->
        discover_result = Types.parse_discover_result(result)
        {:reply, {:ok, discover_result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:perform, tool_name, args, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "perform")
    {id, state} = next_id(state)

    params =
      %{
        "tool" => tool_name,
        "args" => stringify_keys(args)
      }
      |> maybe_put("demux", Keyword.get(opts, :demux))
      |> maybe_put("refract", Keyword.get(opts, :refract))
      |> maybe_put("chart", Keyword.get(opts, :chart))

    case call_dg_tool(state, "data-grout/discovery.perform", params, id) do
      {:ok, result, state} ->
        tool_result = %Types.ToolResult{
          content: result["content"] || [],
          is_error: result["isError"] == true,
          meta: result["_meta"] || result["_datagrout"] || %{}
        }

        {:reply, {:ok, tool_result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:perform_batch, calls}, _from, state) do
    state = maybe_warn_non_dg(state, "perform_batch")
    {id, state} = next_id(state)

    case call_dg_tool(state, "data-grout/discovery.perform", calls, id) do
      {:ok, results, state} when is_list(results) ->
        {:reply, {:ok, results}, state}

      {:ok, result, state} ->
        {:reply, {:ok, [result]}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:guide, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "guide")
    {id, state} = next_id(state)

    params =
      %{}
      |> maybe_put("goal", Keyword.get(opts, :goal))
      |> maybe_put("session_id", Keyword.get(opts, :session_id))
      |> maybe_put("choice", Keyword.get(opts, :choice))

    case call_dg_tool(state, "data-grout/discovery.guide", params, id) do
      {:ok, result, state} ->
        guide_state = Types.parse_guide_state(result)
        {:reply, {:ok, guide_state}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:estimate_cost, tool_name, args}, _from, state) do
    state = maybe_warn_non_dg(state, "estimate_cost")
    {id, state} = next_id(state)

    params = Map.merge(stringify_keys(args), %{"estimate_only" => true})

    case call_dg_tool(state, tool_name, params, id) do
      {:ok, result, state} ->
        estimate = Types.parse_credit_estimate(result)
        {:reply, {:ok, estimate}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:plan, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "plan")

    if Keyword.get(opts, :goal) == nil and Keyword.get(opts, :query) == nil do
      {:reply, {:error, {:invalid_config, "plan() requires at least one of :goal or :query"}}, state}
    else
      {id, state} = next_id(state)

      params =
        %{}
        |> maybe_put("goal", Keyword.get(opts, :goal))
        |> maybe_put("query", Keyword.get(opts, :query))
        |> maybe_put("server", Keyword.get(opts, :server))
        |> maybe_put("k", Keyword.get(opts, :k))
        |> maybe_put("policy", Keyword.get(opts, :policy))
        |> maybe_put("have", Keyword.get(opts, :have))
        |> maybe_put("return_call_handles", Keyword.get(opts, :return_call_handles))
        |> maybe_put("expose_virtual_skills", Keyword.get(opts, :expose_virtual_skills))
        |> maybe_put("model_overrides", Keyword.get(opts, :model_overrides))

      case call_dg_tool(state, "data-grout/discovery.plan", params, id) do
        {:ok, result, state} ->
          {:reply, {:ok, result}, state}

        {{:error, _} = err, state} ->
          {:reply, err, state}
      end
    end
  end

  def handle_call({:dg, name, params}, _from, state) do
    state = maybe_warn_non_dg(state, "dg/#{name}")
    {id, state} = next_id(state)
    tool_name = "data-grout/#{name}"

    case call_dg_tool(state, tool_name, params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  # --- Internal Helpers ---

  # Route a DataGrout first-party tool call through the standard `tools/call`
  # path.  Both MCP and JSONRPC endpoints dispatch on `tools/call`; the tool
  # name goes in `params["name"]` and the arguments in `params["arguments"]`.
  # The server resolves both versioned and unversioned tool names.
  defp call_dg_tool(state, tool_name, arguments, id) do
    params = %{"name" => tool_name, "arguments" => arguments}

    case send_rpc(state, "tools/call", params, id) do
      {:ok, raw, new_state} ->
        # MCP tool responses (both MCP and JSONRPC transports) wrap the result in
        # a content envelope: %{"content" => [%{"type" => "text", "text" => "..."}]}
        # Unwrap one level so callers receive the actual tool output map.
        result = unwrap_content(raw)
        {:ok, result, new_state}

      other ->
        other
    end
  end

  defp unwrap_content(%{"content" => [%{"text" => text} | _]}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> %{"text" => text}
    end
  end

  defp unwrap_content(raw), do: raw

  defp send_rpc(%{ws_pid: ws_pid} = state, method, params, _id) when not is_nil(ws_pid) do
    case DatagroutConduit.Transport.Ws.send_request(ws_pid, method, params) do
      {:ok, result} -> {:ok, result, state}
      {:error, _} = err -> {err, state}
    end
  end

  defp send_rpc(state, method, params, id) do
    auth = resolve_auth(state.auth)

    req =
      if auth != resolve_auth(nil) do
        update_auth_header(state.transport_req, auth)
      else
        state.transport_req
      end

    request_opts =
      %{method: method, params: params, id: id}
      |> maybe_put(:session_id, state.mcp_session_id)

    case state.transport_mod.send_request(req, request_opts) do
      {:ok, result, new_session_id} when is_binary(new_session_id) ->
        {:ok, result, %{state | mcp_session_id: new_session_id}}

      {:ok, result, _} ->
        {:ok, result, state}

      {:ok, result} ->
        {:ok, result, state}

      {:error, _} = err ->
        {err, state}
    end
  end

  defp next_id(state) do
    id = state.request_id + 1
    {id, %{state | request_id: id}}
  end

  defp resolve_auth({:oauth, provider}) do
    case DatagroutConduit.OAuth.get_token(provider) do
      {:ok, token} -> {:bearer, token}
      {:error, reason} ->
        Logger.warning("OAuth token fetch failed: #{inspect(reason)}, proceeding without auth")
        nil
    end
  end

  defp resolve_auth(other), do: other

  defp update_auth_header(req, {:bearer, token}) do
    Req.merge(req, headers: [{"authorization", "Bearer #{token}"}])
  end

  defp update_auth_header(req, {:api_key, key}) do
    Req.merge(req, headers: [{"x-api-key", key}])
  end

  defp update_auth_header(req, {:basic, user, pass}) do
    Req.merge(req, headers: [{"authorization", "Basic #{Base.encode64("#{user}:#{pass}")}"}])
  end

  defp update_auth_header(req, _), do: req

  defp maybe_filter_intelligent(tools, true) do
    Enum.reject(tools, fn tool -> String.contains?(tool.name || "", "@") end)
  end

  defp maybe_filter_intelligent(tools, _), do: tools

  defp maybe_warn_non_dg(%{dg_warned: true} = state, _method), do: state

  defp maybe_warn_non_dg(state, method) do
    if not DatagroutConduit.is_dg_url?(state.url) do
      Logger.warning(
        "DataGrout extension '#{method}' called on non-DG URL (#{state.url}). " <>
          "DG-specific features may not be available."
      )

      %{state | dg_warned: true}
    else
      state
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
