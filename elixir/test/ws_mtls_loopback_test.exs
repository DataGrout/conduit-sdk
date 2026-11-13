defmodule DatagroutConduit.Transport.Ws.MtlsLoopbackTest do
  @moduledoc """
  The WS connection against a real `wss://` server that demands a client
  certificate, using the shared fixtures in `testdata/mtls`.

  The option-shape tests in `ws_conn_test.exs` passed while a PEM identity
  could not connect at all: the cert went to `:ssl` as `[{:Certificate, der}]`,
  which it rejects as an invalid option before the handshake. Only a real
  handshake catches that, so this one performs it.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.Identity
  alias DatagroutConduit.Transport.Ws.Conn

  @fixtures Path.expand("../../testdata/mtls", __DIR__)
  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  setup do
    Process.flag(:trap_exit, true)
    {:ok, port} = start_server(self())
    %{url: "wss://localhost:#{port}/ws"}
  end

  test "a PEM identity presents its certificate and the upgrade headers", %{url: url} do
    {:ok, identity} =
      Identity.from_pem(fixture!("client.pem"), fixture!("client-key.pem"), fixture!("ca.pem"))

    assert {:ok, _pid} = connect(url, identity)
    assert_receive {:upgraded, "conduit-sdk test client", "Bearer loopback"}, 5_000
  end

  test "a path identity presents its certificate", %{url: url} do
    {:ok, identity} =
      Identity.from_paths(path("client.pem"), path("client-key.pem"), path("ca.pem"))

    assert {:ok, _pid} = connect(url, identity)
    assert_receive {:upgraded, "conduit-sdk test client", "Bearer loopback"}, 5_000
  end

  test "without an identity the handshake never completes", %{url: url} do
    assert {:error, _} = connect(url, nil)
    refute_received {:upgraded, _, _}
  end

  defp connect(url, identity) do
    Conn.start_link(url,
      parent: self(),
      headers: [{"authorization", "Bearer loopback"}],
      identity: identity
    )
  end

  # ── A one-connection wss:// server ──────────────────────────────────────────

  defp start_server(test) do
    {:ok, listen} =
      :ssl.listen(0,
        certfile: path(~c"server.pem"),
        keyfile: path(~c"server-key.pem"),
        cacertfile: path(~c"ca.pem"),
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        mode: :binary,
        active: false,
        reuseaddr: true
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen)
    spawn_link(fn -> accept(listen, test) end)
    {:ok, port}
  end

  defp accept(listen, test) do
    {:ok, transport} = :ssl.transport_accept(listen, 5_000)

    case :ssl.handshake(transport, 5_000) do
      {:ok, socket} ->
        {:ok, der} = :ssl.peercert(socket)
        headers = read_request(socket, "")
        :ok = :ssl.send(socket, upgrade_response(headers))
        send(test, {:upgraded, common_name(der), headers["authorization"]})
        # Hold the connection open until the test process goes away.
        receive do
          :never -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      [head | _] = String.split(acc, "\r\n\r\n", parts: 2)
      [_request_line | lines] = String.split(head, "\r\n")

      Map.new(lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(k), String.trim(v)}
      end)
    else
      {:ok, data} = :ssl.recv(socket, 0, 5_000)
      read_request(socket, acc <> data)
    end
  end

  defp upgrade_response(headers) do
    accept = Base.encode64(:crypto.hash(:sha, headers["sec-websocket-key"] <> @ws_guid))

    protocol =
      case headers["sec-websocket-protocol"] do
        nil -> ""
        p -> "Sec-WebSocket-Protocol: #{p}\r\n"
      end

    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{accept}\r\n" <> protocol <> "\r\n"
  end

  defp common_name(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:rdnSequence, rdns} = elem(tbs, 6)

    Enum.find_value(List.flatten(rdns), fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {_string_type, cn}} -> to_string(cn)
      {:AttributeTypeAndValue, {2, 5, 4, 3}, cn} -> to_string(cn)
      _ -> nil
    end)
  end

  defp path(name) when is_list(name), do: String.to_charlist(path(to_string(name)))
  defp path(name), do: Path.join(@fixtures, name)
  defp fixture!(name), do: File.read!(path(name))
end
