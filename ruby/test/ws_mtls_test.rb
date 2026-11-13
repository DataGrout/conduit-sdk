# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "digest/sha1"

# The WS transport against a real `wss://` server that demands a client
# certificate, using the shared fixtures in `testdata/mtls`.
#
# The transport presented its certificate correctly, but an identity with a CA
# replaced the trust store with that CA alone, so a DataGrout-issued identity
# (which carries the DataGrout CA) could not verify the gateway's public
# certificate. The loopback proves the handshake; the store tests prove the
# system roots survive, which a loopback cannot.
class WsMtlsTest < Minitest::Test
  FIXTURES = File.expand_path("../../testdata/mtls", __dir__)
  WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def setup
    WebMock.allow_net_connect!
    @seen = Queue.new
    @server = start_server
    @url = "wss://localhost:#{@server.to_io.addr[1]}/ws"
  end

  def teardown
    @server&.close
    @accept_thread&.kill
    WebMock.disable_net_connect!
  end

  def test_presents_the_client_certificate_and_the_upgrade_headers
    transport = DatagroutConduit::Transport::Ws.new(
      url: @url, auth: { bearer: "loopback" }, identity: identity
    )

    transport.connect
    seen = @seen.pop(timeout: 5)
    transport.disconnect

    assert_equal({ peer_cn: "conduit-sdk test client", authorization: "Bearer loopback" }, seen)
  end

  def test_cannot_connect_without_an_identity_when_the_server_demands_one
    transport = DatagroutConduit::Transport::Ws.new(url: @url, auth: { bearer: "loopback" })

    assert_raises(DatagroutConduit::ConnectionError) { transport.connect }
    assert_nil @seen.pop(timeout: 0.2)
  end

  def test_the_identity_cert_store_trusts_its_ca_and_keeps_the_system_roots
    store = identity.cert_store

    assert store.verify(OpenSSL::X509::Certificate.new(fixture("server.pem")))

    skip "no system CA bundle on this host" unless File.exist?(OpenSSL::X509::DEFAULT_CERT_FILE)
    assert store.verify(system_root), "the identity's CA displaced the system roots"
  end

  def test_the_ws_context_uses_the_identity_store
    transport = DatagroutConduit::Transport::Ws.new(url: @url, identity: identity)
    ctx = transport.send(:build_ssl_context)

    assert_equal OpenSSL::SSL::VERIFY_PEER, ctx.verify_mode
    assert ctx.cert_store.verify(OpenSSL::X509::Certificate.new(fixture("server.pem")))

    skip "no system CA bundle on this host" unless File.exist?(OpenSSL::X509::DEFAULT_CERT_FILE)
    assert ctx.cert_store.verify(system_root), "the identity's CA displaced the system roots"
  end

  private

  def fixture(name) = File.read(File.join(FIXTURES, name))

  # The first certificate in the host's default bundle: a public root.
  def system_root = OpenSSL::X509::Certificate.new(File.read(OpenSSL::X509::DEFAULT_CERT_FILE))

  def identity
    DatagroutConduit::Identity.from_pem(
      fixture("client.pem"), fixture("client-key.pem"), ca_pem: fixture("ca.pem")
    )
  end

  # A one-connection wss:// server that refuses any client without a
  # certificate signed by the fixture CA.
  def start_server
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = OpenSSL::X509::Certificate.new(fixture("server.pem"))
    ctx.key = OpenSSL::PKey.read(fixture("server-key.pem"))
    ca_store = OpenSSL::X509::Store.new
    ca_store.add_cert(OpenSSL::X509::Certificate.new(fixture("ca.pem")))
    ctx.cert_store = ca_store
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT

    server = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), ctx)
    server.start_immediately = true
    @accept_thread = Thread.new { serve_one(server) }
    server
  end

  def serve_one(server)
    socket = server.accept
    headers = read_request(socket)
    accept = [Digest::SHA1.digest(headers["sec-websocket-key"] + WS_GUID)].pack("m0")
    protocol = headers["sec-websocket-protocol"]
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
      "Sec-WebSocket-Accept: #{accept}\r\n" \
      "#{protocol ? "Sec-WebSocket-Protocol: #{protocol}\r\n" : ''}\r\n"
    )
    cn = socket.peer_cert.subject.to_a.find { |name, _, _| name == "CN" }&.at(1)
    @seen << { peer_cn: cn, authorization: headers["authorization"] }
    sleep # hold the connection open until teardown kills the thread
  rescue OpenSSL::SSL::SSLError, IOError, Errno::ECONNRESET
    nil # the client was refused, which the no-identity test expects
  end

  def read_request(socket)
    head = +""
    head << socket.readpartial(4096) until head.include?("\r\n\r\n")
    head.split("\r\n\r\n", 2).first.split("\r\n").drop(1).to_h do |line|
      key, value = line.split(":", 2)
      [key.downcase, value.strip]
    end
  end
end
