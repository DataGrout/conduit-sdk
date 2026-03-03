defmodule DatagroutConduit.Transport.JSONRPC do
  @moduledoc """
  Plain JSON-RPC 2.0 over HTTP transport.

  Sends HTTP POST requests with standard JSON-RPC 2.0 envelope and
  expects a JSON response body.
  """

  @behaviour DatagroutConduit.Transport.Behaviour

  @impl true
  def connect(opts) do
    url = opts.url
    identity = opts[:identity]
    auth = opts[:auth]

    connect_options = build_connect_options(identity)
    headers = build_headers(auth)

    req =
      Req.new(
        base_url: url,
        headers: headers,
        connect_options: connect_options,
        receive_timeout: 120_000
      )

    {:ok, req}
  end

  @impl true
  def send_request(req, opts) do
    do_send_request(req, opts, _retried: false)
  end

  defp do_send_request(req, opts, _retried: retried) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => opts.id,
      "method" => opts.method,
      "params" => opts[:params] || %{}
    }

    oauth = opts[:oauth]

    case Req.post(req, url: "", json: body) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        parse_response(response_body)

      {:ok, %Req.Response{status: 429, headers: resp_headers}} ->
        retry_after = get_header(resp_headers, "retry-after")
        {:error, {:rate_limited, retry_after}}

      {:ok, %Req.Response{status: 401}} when not retried and oauth != nil ->
        DatagroutConduit.OAuth.invalidate(oauth)
        do_send_request(req, opts, _retried: true)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(v) -> if String.downcase(k) == name, do: v
      {k, [v | _]} -> if String.downcase(k) == name, do: v
      _ -> nil
    end)
  end

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> extract_result(parsed)
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_response(body) when is_map(body) do
    extract_result(body)
  end

  defp extract_result(%{"error" => error}) do
    {:error, {:jsonrpc_error, error["code"], error["message"], error["data"]}}
  end

  defp extract_result(%{"result" => result}) do
    {:ok, result}
  end

  defp extract_result(other) do
    {:ok, other}
  end

  defp build_headers(nil), do: []
  defp build_headers({:bearer, token}), do: [{"authorization", "Bearer #{token}"}]
  defp build_headers({:api_key, key}), do: [{"x-api-key", key}]
  defp build_headers({:basic, user, pass}), do: [{"authorization", "Basic #{Base.encode64("#{user}:#{pass}")}"}]
  defp build_headers(_), do: []

  defp build_connect_options(nil), do: []

  defp build_connect_options(%DatagroutConduit.Identity{} = identity) do
    ssl_opts =
      [
        certfile: identity.cert_path,
        keyfile: identity.key_path
      ]
      |> maybe_add(:cacertfile, identity.ca_path)
      |> maybe_add_pem(:cert, identity.cert_pem)
      |> maybe_add_pem(:key, identity.key_pem)
      |> maybe_add_pem(:cacerts, identity.ca_pem)

    [transport_opts: ssl_opts]
  end

  defp build_connect_options(_), do: []

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_pem(opts, _key, nil), do: opts

  defp maybe_add_pem(opts, :cert, pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] -> Keyword.put(opts, :cert, [{:Certificate, der}])
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :key, pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, _} | _] -> Keyword.put(opts, :key, {type, der})
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :cacerts, pem) do
    certs =
      :public_key.pem_decode(pem)
      |> Enum.filter(fn {type, _, _} -> type == :Certificate end)
      |> Enum.map(fn {:Certificate, der, _} -> der end)

    if certs != [], do: Keyword.put(opts, :cacerts, certs), else: opts
  end
end
