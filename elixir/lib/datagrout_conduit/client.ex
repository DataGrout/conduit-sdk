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

  @doc """
  Execute a multi-step workflow plan.

  ## Options

    * `:plan` - Ordered list of tool call step descriptors (required)
    * `:validate_ctc` - Validate each call against its CTC schema (default: `true`)
    * `:save_as_skill` - Persist the flow as a reusable skill (default: `false`)
    * `:input_data` - Runtime input data for the flow (optional)
  """
  @spec flow_into(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def flow_into(client, opts) do
    GenServer.call(client, {:flow_into, opts}, 120_000)
  end

  @doc """
  Focus data through a prism transformation.

  ## Options

    * `:data` - The data to transform (required)
    * `:source_type` - Source type (required)
    * `:target_type` - Target type (required)
    * `:source_annotations` - Annotations describing source schema (optional)
    * `:target_annotations` - Annotations describing target schema (optional)
    * `:context` - Additional context for the transformation (optional)
  """
  @spec prism_focus(GenServer.server(), keyword()) :: {:ok, Types.PrismFocusResult.t()} | {:error, term()}
  def prism_focus(client, opts) do
    GenServer.call(client, {:prism_focus, opts}, 60_000)
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

  @doc """
  Refract a payload through a goal-directed transformation.

  ## Options

    * `:goal` - Transformation goal (required)
    * `:payload` - Data to transform (required)
    * `:verbose` - Include detailed transformation trace
    * `:chart` - Include chart in output
  """
  @spec refract(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def refract(client, opts) do
    GenServer.call(client, {:refract, opts}, 120_000)
  end

  @doc """
  Render a chart from a payload.

  ## Options

    * `:goal` - Chart description (required)
    * `:payload` - Data to chart (required)
    * `:format` - Output format (e.g. `"png"`, `"svg"`)
    * `:chart_type` - Chart type (e.g. `"bar"`, `"line"`)
    * `:title` - Chart title
    * `:x_label` - X-axis label
    * `:y_label` - Y-axis label
    * `:width` - Width in pixels
    * `:height` - Height in pixels
  """
  @spec chart(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def chart(client, opts) do
    GenServer.call(client, {:chart, opts}, 60_000)
  end

  @doc """
  Generate a document toward a natural-language goal.

  ## Options

    * `:goal` - Natural language description of the content to generate (required)
    * `:payload` - Input data (optional)
    * `:format` - Output format: markdown, html, pdf, json (default: markdown)
    * `:sections` - Optional list of section specs
  """
  @spec render(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(client, opts) do
    GenServer.call(client, {:render, opts}, 60_000)
  end

  @doc """
  Convert content to another format (no LLM). Supports csv, xlsx, pdf, json, html, markdown, etc.

  ## Options

    * `:content` - Data or string to export (required)
    * `:format` - Target format (required)
    * `:style` - Optional styling options
    * `:metadata` - Optional document metadata
  """
  @spec export(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(client, opts) do
    GenServer.call(client, {:export, opts}, 60_000)
  end

  @doc """
  Pause workflow for human approval. Use for destructive or policy-gated actions.

  ## Options

    * `:action` - Name of the action (required)
    * `:details` - Action-specific payload
    * `:reason` - Why approval is requested
    * `:context` - Workflow context
  """
  @spec request_approval(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_approval(client, opts) do
    GenServer.call(client, {:request_approval, opts}, 60_000)
  end

  @doc """
  Request user clarification for missing fields. Pauses until user provides values.

  ## Options

    * `:missing_fields` - List of field names (required)
    * `:reason` - Why this information is needed (required)
    * `:current_data` - Data already collected
    * `:suggestions` - Optional suggestions per field
    * `:context` - Workflow context
  """
  @spec request_feedback(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_feedback(client, opts) do
    GenServer.call(client, {:request_feedback, opts}, 60_000)
  end

  @doc """
  List recent tool executions for the current server.

  ## Options

    * `:limit` - Max results (default: 50)
    * `:offset` - Pagination offset
    * `:status` - Filter by success, error, timeout
    * `:refractions_only` - Only refraction executions
  """
  @spec execution_history(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def execution_history(client, opts \\ []) do
    GenServer.call(client, {:execution_history, opts}, 60_000)
  end

  @doc """
  Get details and transcript for a specific execution.

  ## Options

    * `:execution_id` - Unique execution ID (required)
  """
  @spec execution_details(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def execution_details(client, opts) do
    GenServer.call(client, {:execution_details, opts}, 60_000)
  end

  # --- Logic Cell Methods ---

  @doc """
  Assert a fact or facts into the logic cell.

  ## Options

    * `:statement` - Natural language or fact string (mutually exclusive with `:facts`)
    * `:facts` - A list of fact strings (mutually exclusive with `:statement`)
    * `:tag` - Optional tag for grouping facts
  """
  @spec remember(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def remember(client, opts) do
    GenServer.call(client, {:remember, opts}, 60_000)
  end

  @doc """
  Query the logic cell.

  ## Options

    * `:question` - Natural language question (mutually exclusive with `:patterns`)
    * `:patterns` - Query pattern list (mutually exclusive with `:question`)
    * `:limit` - Maximum number of results
  """
  @spec query_cell(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def query_cell(client, opts) do
    GenServer.call(client, {:query_cell, opts}, 60_000)
  end

  @doc """
  Retract facts from the logic cell.

  ## Options

    * `:handles` - List of fact handles to retract (mutually exclusive with `:pattern`)
    * `:pattern` - Pattern to retract matching facts (mutually exclusive with `:handles`)
  """
  @spec forget(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def forget(client, opts) do
    GenServer.call(client, {:forget, opts}, 60_000)
  end

  @doc """
  Assert a constraint rule into the logic cell.

  ## Options

    * `:rule` - Constraint rule text (required; server uses Prolog for evaluation)
    * `:tag` - Optional tag for grouping constraints
  """
  @spec constrain(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def constrain(client, opts) do
    GenServer.call(client, {:constrain, opts}, 60_000)
  end

  @doc """
  Reflect on the current state of the logic cell.

  ## Options

    * `:entity` - Restrict reflection to a specific entity
    * `:summary_only` - Return only a summary (omit raw facts)
  """
  @spec reflect(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def reflect(client, opts \\ []) do
    GenServer.call(client, {:reflect, opts}, 60_000)
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
      request_id: 0
    }

    {:ok, state}
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

  def handle_call({:flow_into, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "flow_into")
    {id, state} = next_id(state)

    params =
      %{
        "plan" => Keyword.fetch!(opts, :plan),
        "validate_ctc" => Keyword.get(opts, :validate_ctc, true),
        "save_as_skill" => Keyword.get(opts, :save_as_skill, false)
      }
      |> maybe_put("input_data", Keyword.get(opts, :input_data))

    case call_dg_tool(state, "data-grout/flow.into", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:prism_focus, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "prism_focus")
    {id, state} = next_id(state)

    params =
      %{
        "data" => Keyword.fetch!(opts, :data),
        "source_type" => Keyword.fetch!(opts, :source_type),
        "target_type" => Keyword.fetch!(opts, :target_type)
      }
      |> maybe_put("source_annotations", Keyword.get(opts, :source_annotations))
      |> maybe_put("target_annotations", Keyword.get(opts, :target_annotations))
      |> maybe_put("context", Keyword.get(opts, :context))

    case call_dg_tool(state, "data-grout/prism.focus", params, id) do
      {:ok, result, state} ->
        prism = %Types.PrismFocusResult{
          output: result["output"] || result,
          source_type: Keyword.get(opts, :source_type),
          target_type: Keyword.get(opts, :target_type)
        }

        {:reply, {:ok, prism}, state}

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

  def handle_call({:refract, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "refract")
    {id, state} = next_id(state)

    params =
      %{
        "goal" => Keyword.fetch!(opts, :goal),
        "payload" => Keyword.fetch!(opts, :payload)
      }
      |> maybe_put("verbose", Keyword.get(opts, :verbose))
      |> maybe_put("chart", Keyword.get(opts, :chart))

    case call_dg_tool(state, "data-grout/prism.refract", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:chart, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "chart")
    {id, state} = next_id(state)

    params =
      %{
        "goal" => Keyword.fetch!(opts, :goal),
        "payload" => Keyword.fetch!(opts, :payload)
      }
      |> maybe_put("format", Keyword.get(opts, :format))
      |> maybe_put("chart_type", Keyword.get(opts, :chart_type))
      |> maybe_put("title", Keyword.get(opts, :title))
      |> maybe_put("x_label", Keyword.get(opts, :x_label))
      |> maybe_put("y_label", Keyword.get(opts, :y_label))
      |> maybe_put("width", Keyword.get(opts, :width))
      |> maybe_put("height", Keyword.get(opts, :height))

    case call_dg_tool(state, "data-grout/prism.chart", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:render, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "render")
    {id, state} = next_id(state)
    params =
      %{"goal" => Keyword.fetch!(opts, :goal), "format" => Keyword.get(opts, :format, "markdown")}
      |> maybe_put("payload", Keyword.get(opts, :payload))
      |> maybe_put("sections", Keyword.get(opts, :sections))
    case call_dg_tool(state, "data-grout/prism.render", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:export, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "export")
    {id, state} = next_id(state)
    params =
      %{"content" => Keyword.fetch!(opts, :content), "format" => Keyword.fetch!(opts, :format)}
      |> maybe_put("style", Keyword.get(opts, :style))
      |> maybe_put("metadata", Keyword.get(opts, :metadata))
    case call_dg_tool(state, "data-grout/prism.export", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:request_approval, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "request_approval")
    {id, state} = next_id(state)
    params =
      %{"action" => Keyword.fetch!(opts, :action)}
      |> maybe_put("details", Keyword.get(opts, :details))
      |> maybe_put("reason", Keyword.get(opts, :reason))
      |> maybe_put("context", Keyword.get(opts, :context))
    case call_dg_tool(state, "data-grout/flow.request-approval", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:request_feedback, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "request_feedback")
    {id, state} = next_id(state)
    params =
      %{"missing_fields" => Keyword.fetch!(opts, :missing_fields), "reason" => Keyword.fetch!(opts, :reason)}
      |> maybe_put("current_data", Keyword.get(opts, :current_data))
      |> maybe_put("suggestions", Keyword.get(opts, :suggestions))
      |> maybe_put("context", Keyword.get(opts, :context))
    case call_dg_tool(state, "data-grout/flow.request-feedback", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:execution_history, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "execution_history")
    {id, state} = next_id(state)
    params =
      %{"limit" => Keyword.get(opts, :limit, 50), "offset" => Keyword.get(opts, :offset, 0)}
      |> maybe_put("status", Keyword.get(opts, :status))
      |> maybe_put("refractions_only", Keyword.get(opts, :refractions_only))
    case call_dg_tool(state, "data-grout/inspect.execution-history", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:execution_details, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "execution_details")
    {id, state} = next_id(state)
    params = %{"execution_id" => Keyword.fetch!(opts, :execution_id)}
    case call_dg_tool(state, "data-grout/inspect.execution-details", params, id) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {{:error, _} = err, new_state} -> {:reply, err, new_state}
    end
  end

  def handle_call({:remember, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "remember")
    {id, state} = next_id(state)

    params =
      %{}
      |> maybe_put("statement", Keyword.get(opts, :statement))
      |> maybe_put("facts", Keyword.get(opts, :facts))
      |> maybe_put("tag", Keyword.get(opts, :tag))

    case call_dg_tool(state, "data-grout/logic.remember", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:query_cell, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "query_cell")
    {id, state} = next_id(state)

    params =
      %{}
      |> maybe_put("question", Keyword.get(opts, :question))
      |> maybe_put("patterns", Keyword.get(opts, :patterns))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call_dg_tool(state, "data-grout/logic.query", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:forget, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "forget")
    {id, state} = next_id(state)

    params =
      %{}
      |> maybe_put("handles", Keyword.get(opts, :handles))
      |> maybe_put("pattern", Keyword.get(opts, :pattern))

    case call_dg_tool(state, "data-grout/logic.forget", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:constrain, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "constrain")
    {id, state} = next_id(state)

    params =
      %{"rule" => Keyword.fetch!(opts, :rule)}
      |> maybe_put("tag", Keyword.get(opts, :tag))

    case call_dg_tool(state, "data-grout/logic.constrain", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:reflect, opts}, _from, state) do
    state = maybe_warn_non_dg(state, "reflect")
    {id, state} = next_id(state)

    params =
      %{}
      |> maybe_put("entity", Keyword.get(opts, :entity))
      |> maybe_put("summary_only", Keyword.get(opts, :summary_only))

    case call_dg_tool(state, "data-grout/logic.reflect", params, id) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
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
