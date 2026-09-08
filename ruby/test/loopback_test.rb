# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# Tests for the loopback redirect listener.
#
# Ports the Rust reference suite. These bind real sockets on 127.0.0.1 and
# drive them with real requests, because the failures worth catching here are
# exactly the ones a mocked server cannot have: a port that will not re-bind, a
# favicon request mistaken for the redirect, a response that never flushes.
class LoopbackTest < Minitest::Test
  AC = DatagroutConduit::AuthCode
  Listener = DatagroutConduit::AuthCode::LoopbackListener

  def setup
    # These talk to real sockets, so WebMock must stay out of the way.
    WebMock.allow_net_connect!
  end

  # Issue a bare GET and return [status, body]. Raw TCP rather than Net::HTTP
  # so nothing intercepts it and the request line is exactly what a browser
  # would send.
  def get(port, target)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n")
    raw = socket.read.to_s
    socket.close
    head, _, body = raw.partition("\r\n\r\n")
    [head.lines.first.to_s.split[1].to_i, body]
  end

  # Fire a request from another thread and return the listener's outcome.
  def redirect_to(listener, target)
    requester = Thread.new do
      # Give wait() a moment to reach the accept loop.
      sleep 0.05
      get(listener.port, target)
    end
    outcome = begin
      listener.wait(timeout: 5)
    rescue AC::Error => e
      e
    end
    [outcome, requester.value]
  end

  def test_binds_a_loopback_port_and_reports_it
    listener = Listener.bind
    assert_operator listener.port, :>, 0
    assert_equal "http://127.0.0.1:#{listener.port}/callback", listener.redirect_uri
  ensure
    listener&.close
  end

  def test_redirect_uri_uses_the_literal_address_not_localhost
    # RFC 8252, and it avoids IPv6-vs-IPv4 resolution surprises.
    listener = Listener.bind
    assert_includes listener.redirect_uri, "127.0.0.1"
    refute_includes listener.redirect_uri, "localhost"
  ensure
    listener&.close
  end

  def test_bind_for_reuses_the_exact_port_and_path_of_a_saved_uri
    # A saved client id is bound to its redirect URI exactly, so a later run
    # has to come back on the same port.
    first = Listener.bind_on(0, "/cb")
    uri = first.redirect_uri
    port = first.port
    first.close

    again = Listener.bind_for(uri)
    assert_equal port, again.port
    assert_equal uri, again.redirect_uri
  ensure
    again&.close
  end

  def test_bind_for_fails_loudly_when_the_port_is_taken
    held = Listener.bind
    # Better a clear failure the caller can answer by re-registering than
    # authorizing against a URI the server will reject.
    error = assert_raises(AC::HttpError) { Listener.bind_for(held.redirect_uri) }
    assert_includes error.message, "cannot bind loopback port"
  ensure
    held&.close
  end

  def test_bind_for_rejects_a_uri_with_no_port
    error = assert_raises(AC::HttpError) { Listener.bind_for("https://example.com/callback") }
    assert_includes error.message, "names no port"
  end

  def test_normalises_a_path_without_a_leading_slash
    listener = Listener.bind_on(0, "cb")
    assert listener.redirect_uri.end_with?("/cb")
  ensure
    listener&.close
  end

  def test_captures_code_and_state_from_the_redirect
    listener = Listener.bind
    outcome, response = redirect_to(listener, "/callback?code=the_code&state=the_state")

    status, body = response
    assert_equal 200, status
    # The user sees an outcome rather than a browser error.
    assert_includes body, "Signed in"

    assert_equal "the_code", outcome.code
    assert_equal "the_state", outcome.state
  end

  def test_ignores_a_favicon_request_and_keeps_waiting
    listener = Listener.bind
    port = listener.port

    requester = Thread.new do
      sleep 0.05
      # A browser asks for this unprompted; treating it as the redirect would
      # abort the flow.
      favicon = get(port, "/favicon.ico")
      sleep 0.05
      [favicon, get(port, "/callback?code=c2&state=s2")]
    end

    redirect = listener.wait(timeout: 5)
    favicon, = requester.value

    assert_equal 404, favicon.first
    assert_equal "c2", redirect.code
  end

  def test_surfaces_a_denial_as_a_typed_error
    listener = Listener.bind
    outcome, = redirect_to(
      listener, "/callback?error=access_denied&error_description=User%20said%20no"
    )

    assert_kind_of AC::DeniedError, outcome
    assert_equal :denied, outcome.kind
    assert_includes outcome.message, "access_denied — User said no"
  end

  def test_rejects_a_redirect_with_neither_an_error_nor_a_code
    listener = Listener.bind
    outcome, response = redirect_to(listener, "/callback")

    assert_equal 400, response.first
    assert_kind_of AC::DiscoveryError, outcome
    assert_includes outcome.message, "neither an error nor a code"
  end

  def test_times_out_when_no_redirect_arrives
    listener = Listener.bind
    error = assert_raises(AC::HttpError) { listener.wait(timeout: 0.2) }
    assert_includes error.message, "timed out"
  end

  def test_decodes_percent_escapes_in_the_code_and_state
    # Codes and state values are opaque and routinely contain characters that
    # must survive a round trip through the query string.
    listener = Listener.bind
    outcome, = redirect_to(listener, "/callback?code=a%2Fb&state=x%20y")

    assert_equal "a/b", outcome.code
    assert_equal "x y", outcome.state
  end

  def test_wait_stops_listening_afterwards
    # One-shot: the port is released once the redirect is captured, so a later
    # run can re-bind it.
    listener = Listener.bind
    port = listener.port
    redirect_to(listener, "/callback?code=c&state=s")

    again = Listener.bind_on(port, "/callback")
    assert_equal port, again.port
  ensure
    again&.close
  end

  def test_a_timeout_also_releases_the_port
    listener = Listener.bind
    port = listener.port
    assert_raises(AC::HttpError) { listener.wait(timeout: 0.2) }

    again = Listener.bind_on(port, "/callback")
    assert_equal port, again.port
  ensure
    again&.close
  end

  def test_close_is_safe_to_call_more_than_once
    listener = Listener.bind
    listener.close
    listener.close
  end
end
