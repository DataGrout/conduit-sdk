defmodule DatagroutConduit.Transport.Ws.ConnTest do
  @moduledoc """
  The WebSocket handshake must present the mTLS identity.

  The HTTP transports hand an identity to Finch as `transport_opts`; the WS
  connection accepted the same identity and discarded it, so a `wss://`
  connection presented no client certificate.  These tests assert on the
  WebSockex options `Conn` builds, without opening a socket.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.Identity
  alias DatagroutConduit.Transport.Ws.Conn

  @url "wss://gateway.datagrout.ai/servers/abc/ws"
  @headers [{"authorization", "Bearer t"}]

  describe "build_ws_opts/3 without an identity" do
    test "still verifies the server on wss:// instead of WebSockex's insecure default" do
      opts = Conn.build_ws_opts(@url, @headers, nil)
      ssl = opts[:ssl_options]

      assert opts[:extra_headers] == @headers
      assert opts[:handle_initial_conn_failure] == true

      assert ssl[:verify] == :verify_peer
      assert ssl[:cacertfile] == CAStore.file_path()
      assert ssl[:server_name_indication] == ~c"gateway.datagrout.ai"
      assert [match_fun: _] = ssl[:customize_hostname_check]

      # No identity, so nothing to present.
      for key <- [:cert, :key, :certfile, :keyfile, :cacerts] do
        refute Keyword.has_key?(ssl, key), "unexpected #{inspect(key)} without an identity"
      end
    end

    test "adds no TLS options to a plain ws:// connection" do
      opts = Conn.build_ws_opts("ws://localhost:4000/ws", @headers, nil)

      assert opts[:extra_headers] == @headers
      refute Keyword.has_key?(opts, :ssl_options)
    end
  end

  describe "build_ws_opts/3 with a PEM identity" do
    setup do
      {cert_pem, key_pem} = generate_test_pems()
      %{cert_pem: cert_pem, key_pem: key_pem}
    end

    test "presents the client cert and key on wss://", %{cert_pem: cert_pem, key_pem: key_pem} do
      {:ok, identity} = Identity.from_pem(cert_pem, key_pem)

      opts = Conn.build_ws_opts(@url, @headers, identity)
      ssl = opts[:ssl_options]

      assert [{:Certificate, der}] = ssl[:cert]
      assert [{:Certificate, ^der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      assert {_type, _der} = ssl[:key]

      # Headers are untouched by the identity.
      assert opts[:extra_headers] == @headers
    end

    test "verifies the peer against the default bundle when the identity has no CA", ctx do
      {:ok, identity} = Identity.from_pem(ctx.cert_pem, ctx.key_pem)

      ssl = Conn.build_ws_opts(@url, @headers, identity)[:ssl_options]

      assert ssl[:verify] == :verify_peer
      assert ssl[:cacertfile] == CAStore.file_path()
      refute Keyword.has_key?(ssl, :cacerts)
      assert ssl[:server_name_indication] == ~c"gateway.datagrout.ai"
    end

    test "trusts the identity's CA when one is present", ctx do
      # A self-signed cert doubles as its own CA for the purpose of the option shape.
      {:ok, identity} = Identity.from_pem(ctx.cert_pem, ctx.key_pem, ctx.cert_pem)

      ssl = Conn.build_ws_opts(@url, @headers, identity)[:ssl_options]

      assert [der] = ssl[:cacerts]
      assert [{:Certificate, ^der, :not_encrypted}] = :public_key.pem_decode(ctx.cert_pem)
      refute Keyword.has_key?(ssl, :cacertfile)
      assert ssl[:verify] == :verify_peer
    end

    test "does not present a certificate on a plain ws:// connection", ctx do
      {:ok, identity} = Identity.from_pem(ctx.cert_pem, ctx.key_pem)

      opts = Conn.build_ws_opts("ws://localhost:4000/ws", @headers, identity)

      refute Keyword.has_key?(opts, :ssl_options)
    end
  end

  describe "build_ws_opts/3 with a path identity" do
    test "points :ssl at the files, and at the CA file when given" do
      identity = %Identity{
        cert_path: "/etc/conduit/identity.pem",
        key_path: "/etc/conduit/identity_key.pem",
        ca_path: "/etc/conduit/ca.pem"
      }

      ssl = Conn.build_ws_opts(@url, @headers, identity)[:ssl_options]

      assert ssl[:certfile] == "/etc/conduit/identity.pem"
      assert ssl[:keyfile] == "/etc/conduit/identity_key.pem"
      assert ssl[:cacertfile] == "/etc/conduit/ca.pem"
      assert ssl[:verify] == :verify_peer
      refute Keyword.has_key?(ssl, :cert)
      refute Keyword.has_key?(ssl, :key)
    end
  end

  # --- Test Helpers ---

  defp generate_test_pems do
    dir = Path.join(System.tmp_dir!(), "conduit_ws_conn_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "key.pem")
    cert_path = Path.join(dir, "cert.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key_path,
          "-out",
          cert_path,
          "-days",
          "365",
          "-subj",
          "/CN=conduit-test"
        ],
        stderr_to_stdout: true
      )

    cert_pem = File.read!(cert_path)
    key_pem = File.read!(key_path)

    File.rm_rf!(dir)

    {cert_pem, key_pem}
  end
end
