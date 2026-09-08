defmodule DatagroutConduit.AuthCode.Loopback do
  @moduledoc """
  Capture the OAuth redirect on `127.0.0.1`.

  A native app has no web server to redirect to, so it runs one for a few
  seconds: bind a loopback port, send the user to the consent page, and read the
  `code` off the single request the browser makes coming back.

  This lives in its own module rather than in `DatagroutConduit.AuthCode` so a
  headless caller can take the flow without a listener it will never bind — the
  same split every conduit SDK makes, so the surface looks the same in every
  language. It runs on `:gen_tcp` and needs no dependency.

      alias DatagroutConduit.AuthCode

      {:ok, listener} = AuthCode.Loopback.bind()
      {:ok, flow} = AuthCode.discover(gateway)
      {:ok, _registered, flow} =
        AuthCode.register(flow, "My App", AuthCode.Loopback.redirect_uri(listener))

      {:ok, url, pending} = AuthCode.authorize_url(flow)
      IO.puts("Open: \#{url}")

      {:ok, redirect} = AuthCode.Loopback.wait(listener, 300_000)
      {:ok, grant} = AuthCode.exchange(flow, pending, redirect.code, redirect.state)
  """

  alias DatagroutConduit.AuthCode.Error

  @typedoc "What the authorization server sent back to the redirect URI."
  @type redirect :: %{code: String.t(), state: String.t()}

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), port: :inet.port_number(), path: String.t()}

  defstruct [:socket, :port, :path]

  # Most bytes read from a redirect request. A URL longer than this is not a
  # redirect we can use.
  @max_request_bytes 8192

  @doc """
  Bind an OS-assigned port on `127.0.0.1`.

  Letting the OS choose avoids fighting whatever else owns a fixed port — and
  because registration happens after binding, the real port is already known by
  the time the redirect URI is registered.
  """
  @spec bind() :: {:ok, t()} | {:error, Error.t()}
  def bind, do: bind_on(0, "/callback")

  @doc """
  Bind a specific port and path.

  Use when the client was registered out of band against a fixed redirect URI
  and the authorization server will accept no other.
  """
  @spec bind_on(:inet.port_number(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def bind_on(port, path) do
    opts = [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true, packet: :raw]

    case :gen_tcp.listen(port, opts) do
      {:ok, socket} ->
        {:ok, bound} = :inet.port(socket)
        normalized = if String.starts_with?(path, "/"), do: path, else: "/" <> path
        {:ok, %__MODULE__{socket: socket, port: bound, path: normalized}}

      {:error, reason} ->
        {:error, Error.http("cannot bind loopback port: #{inspect(reason)}")}
    end
  end

  @doc """
  Re-bind the exact port and path of a previously registered redirect URI.

  Needed whenever a saved `DatagroutConduit.AuthCode.RegisteredClient` is
  reused: the authorization server matches the redirect URI exactly, so the
  listener has to come back on the same port it registered.

  Fails if that port is occupied. The right recovery is to `bind/0` a fresh port
  and register a new client — not to retry, and not to authorize against a URI
  the server will reject.
  """
  @spec bind_for(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def bind_for(redirect_uri) do
    uri = URI.parse(redirect_uri)

    cond do
      is_nil(uri.scheme) or is_nil(uri.host) ->
        {:error, Error.http("bad redirect_uri #{redirect_uri}")}

      # URI fills in the scheme's default port, so `uri.port` alone cannot tell
      # an explicit one from an absent one. The authority is what decides.
      not String.contains?(redirect_uri, "#{uri.host}:#{uri.port}") ->
        {:error, Error.http("redirect_uri #{redirect_uri} names no port")}

      true ->
        bind_on(uri.port, uri.path || "/")
    end
  end

  @doc "The port actually bound."
  @spec port(t()) :: :inet.port_number()
  def port(%__MODULE__{port: port}), do: port

  @doc """
  The redirect URI to register and to send in the authorize request.

  Uses `127.0.0.1` rather than `localhost`: RFC 8252 recommends the literal
  address, and it sidesteps hosts where `localhost` resolves to IPv6 first while
  the listener is bound to IPv4.
  """
  @spec redirect_uri(t()) :: String.t()
  def redirect_uri(%__MODULE__{port: port, path: path}), do: "http://127.0.0.1:#{port}#{path}"

  @doc """
  Wait for the browser's redirect, up to `timeout` milliseconds.

  Serves a small page either way so the user sees an outcome rather than a
  browser error, then stops listening. Requests to other paths are answered 404
  and ignored — browsers routinely ask for `/favicon.ico`, and treating that as
  the redirect would abort the flow.
  """
  @spec wait(t(), timeout()) :: {:ok, redirect()} | {:error, Error.t()}
  def wait(%__MODULE__{} = listener, timeout \\ 300_000) do
    # A monotonic clock, because this measures an interval. Grant expiry is the
    # opposite case and uses Unix seconds, so it survives being written down.
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      accept_loop(listener, deadline, timeout)
    after
      close(listener)
    end
  end

  @doc "Stop listening. Safe to call more than once."
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  # --- Internal ---

  defp accept_loop(listener, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timed_out(timeout)
    else
      case :gen_tcp.accept(listener.socket, remaining) do
        {:ok, conn} ->
          case handle(listener, conn) do
            :continue -> accept_loop(listener, deadline, timeout)
            outcome -> outcome
          end

        {:error, :timeout} ->
          timed_out(timeout)

        {:error, reason} ->
          {:error, Error.http("loopback accept failed: #{inspect(reason)}")}
      end
    end
  end

  defp timed_out(timeout) do
    {:error,
     Error.http("timed out after #{div(timeout, 1000)}s waiting for the authorization redirect")}
  end

  # Serve one request. Returns the outcome, or :continue when the request was
  # not the redirect and we should keep waiting.
  defp handle(listener, conn) do
    result =
      case :gen_tcp.recv(conn, 0, 5_000) do
        {:ok, raw} -> dispatch(listener, conn, raw)
        {:error, _} -> :continue
      end

    :gen_tcp.close(conn)
    result
  end

  defp dispatch(listener, conn, raw) do
    case request_target(raw) do
      nil ->
        :continue

      target ->
        {path, query} = split_target(target)

        if path == listener.path do
          respond_to_redirect(conn, parse_query(query))
        else
          respond(conn, 404, "Not found")
          :continue
        end
    end
  end

  defp respond_to_redirect(conn, %{"error" => error} = params) do
    respond(conn, 200, "Authorization was denied. You can close this window.")
    {:error, Error.denied(error, params["error_description"])}
  end

  defp respond_to_redirect(conn, %{"code" => code, "state" => state}) do
    respond(conn, 200, "Signed in. You can close this window and return to the app.")
    {:ok, %{code: code, state: state}}
  end

  defp respond_to_redirect(conn, _params) do
    respond(conn, 400, "Missing code or state.")
    {:error, Error.discovery("redirect carried neither an error nor a code/state pair")}
  end

  # The request target from a raw HTTP request line.
  defp request_target(raw) do
    raw
    |> binary_part(0, min(byte_size(raw), @max_request_bytes))
    |> String.split(~r/\r?\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.split(" ")
    |> case do
      [_method, target | _] -> target
      _ -> nil
    end
  end

  defp split_target(target) do
    case String.split(target, "?", parts: 2) do
      [path, query] -> {path, query}
      [path] -> {path, ""}
    end
  end

  # Decode a query string.
  #
  # Authorization codes and state values are opaque and routinely contain
  # characters that must survive a round trip through the query string, so
  # `%XX` escapes and `+` are decoded.
  defp parse_query(""), do: %{}
  defp parse_query(query), do: URI.decode_query(query)

  defp respond(conn, status, message) do
    body = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>DataGrout</title>\
    <style>body{font:15px/1.5 system-ui,sans-serif;margin:16vh auto;max-width:26rem;\
    text-align:center;color-scheme:light dark}</style></head>\
    <body><p>#{message}</p></body></html>
    """

    :gen_tcp.send(conn, [
      "HTTP/1.1 #{status} OK\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end
end
