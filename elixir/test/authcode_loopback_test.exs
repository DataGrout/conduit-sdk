defmodule DatagroutConduit.AuthCode.LoopbackTest do
  @moduledoc """
  Tests for the loopback redirect listener.

  Ports the Rust reference suite. These bind real sockets on 127.0.0.1 and drive
  them with real requests, because the failures worth catching here are exactly
  the ones a mocked server cannot have: a port that will not re-bind, a favicon
  request mistaken for the redirect, a response that never flushes.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.AuthCode.{Error, Loopback}

  # Issue a bare GET and return {status, body}. Raw TCP so nothing intercepts
  # it and the request line is exactly what a browser would send.
  defp get(port, target) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(socket, "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n")
    raw = read_all(socket, "")
    :gen_tcp.close(socket)

    [head, body] =
      case String.split(raw, "\r\n\r\n", parts: 2) do
        [h, b] -> [h, b]
        [h] -> [h, ""]
      end

    status = head |> String.split("\r\n") |> hd() |> String.split(" ") |> Enum.at(1)
    {String.to_integer(status), body}
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end

  # Fire a request from another process and return the listener's outcome.
  defp redirect_to(listener, target) do
    port = Loopback.port(listener)
    requester = Task.async(fn -> get(port, target) end)
    outcome = Loopback.wait(listener, 5_000)
    {outcome, Task.await(requester)}
  end

  test "binds a loopback port and reports it" do
    {:ok, listener} = Loopback.bind()
    assert Loopback.port(listener) > 0

    assert Loopback.redirect_uri(listener) ==
             "http://127.0.0.1:#{Loopback.port(listener)}/callback"

    Loopback.close(listener)
  end

  test "the redirect URI uses the literal address, not localhost" do
    # RFC 8252, and it avoids IPv6-vs-IPv4 resolution surprises.
    {:ok, listener} = Loopback.bind()
    uri = Loopback.redirect_uri(listener)
    assert String.contains?(uri, "127.0.0.1")
    refute String.contains?(uri, "localhost")
    Loopback.close(listener)
  end

  test "bind_for reuses the exact port and path of a saved URI" do
    # A saved client id is bound to its redirect URI exactly, so a later run has
    # to come back on the same port.
    {:ok, first} = Loopback.bind_on(0, "/cb")
    uri = Loopback.redirect_uri(first)
    port = Loopback.port(first)
    Loopback.close(first)

    {:ok, again} = Loopback.bind_for(uri)
    assert Loopback.port(again) == port
    assert Loopback.redirect_uri(again) == uri
    Loopback.close(again)
  end

  test "bind_for fails loudly when the port is taken" do
    {:ok, held} = Loopback.bind()

    # Better a clear failure the caller can answer by re-registering than
    # authorizing against a URI the server will reject.
    assert {:error, %Error{kind: :http, message: message}} =
             Loopback.bind_for(Loopback.redirect_uri(held))

    assert message =~ "cannot bind loopback port"
    Loopback.close(held)
  end

  test "bind_for rejects a URI with no port" do
    assert {:error, %Error{message: message}} = Loopback.bind_for("https://example.com/callback")
    assert message =~ "names no port"
  end

  test "normalises a path without a leading slash" do
    {:ok, listener} = Loopback.bind_on(0, "cb")
    assert String.ends_with?(Loopback.redirect_uri(listener), "/cb")
    Loopback.close(listener)
  end

  test "captures code and state from the redirect" do
    {:ok, listener} = Loopback.bind()
    {outcome, {status, body}} = redirect_to(listener, "/callback?code=the_code&state=the_state")

    assert status == 200
    # The user sees an outcome rather than a browser error.
    assert body =~ "Signed in"
    assert {:ok, %{code: "the_code", state: "the_state"}} = outcome
  end

  test "ignores a favicon request and keeps waiting" do
    {:ok, listener} = Loopback.bind()
    port = Loopback.port(listener)

    requester =
      Task.async(fn ->
        # A browser asks for this unprompted; treating it as the redirect would
        # abort the flow.
        favicon = get(port, "/favicon.ico")
        {favicon, get(port, "/callback?code=c2&state=s2")}
      end)

    outcome = Loopback.wait(listener, 5_000)
    {{favicon_status, _}, _} = Task.await(requester)

    assert favicon_status == 404
    assert {:ok, %{code: "c2"}} = outcome
  end

  test "surfaces a denial as a typed error" do
    {:ok, listener} = Loopback.bind()

    {outcome, _} =
      redirect_to(listener, "/callback?error=access_denied&error_description=User%20said%20no")

    assert {:error, %Error{kind: :denied, message: message}} = outcome
    assert message =~ "access_denied — User said no"
  end

  test "rejects a redirect with neither an error nor a code" do
    {:ok, listener} = Loopback.bind()
    {outcome, {status, _}} = redirect_to(listener, "/callback")

    assert status == 400
    assert {:error, %Error{message: message}} = outcome
    assert message =~ "neither an error nor a code"
  end

  test "times out when no redirect arrives" do
    {:ok, listener} = Loopback.bind()
    assert {:error, %Error{message: message}} = Loopback.wait(listener, 200)
    assert message =~ "timed out"
  end

  test "decodes percent escapes in the code and state" do
    # Codes and state values are opaque and routinely contain characters that
    # must survive a round trip through the query string.
    {:ok, listener} = Loopback.bind()
    {outcome, _} = redirect_to(listener, "/callback?code=a%2Fb&state=x%20y")

    assert {:ok, %{code: "a/b", state: "x y"}} = outcome
  end

  test "wait stops listening afterwards" do
    # One-shot: the port is released once the redirect is captured, so a later
    # run can re-bind it.
    {:ok, listener} = Loopback.bind()
    port = Loopback.port(listener)
    redirect_to(listener, "/callback?code=c&state=s")

    assert {:ok, again} = Loopback.bind_on(port, "/callback")
    Loopback.close(again)
  end

  test "a timeout also releases the port" do
    {:ok, listener} = Loopback.bind()
    port = Loopback.port(listener)
    assert {:error, _} = Loopback.wait(listener, 200)

    assert {:ok, again} = Loopback.bind_on(port, "/callback")
    Loopback.close(again)
  end

  test "close is safe to call more than once" do
    {:ok, listener} = Loopback.bind()
    assert :ok = Loopback.close(listener)
    assert :ok = Loopback.close(listener)
  end
end
