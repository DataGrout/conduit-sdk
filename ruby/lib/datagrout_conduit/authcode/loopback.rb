# frozen_string_literal: true

require "socket"
require "uri"

module DatagroutConduit
  module AuthCode
    # What the authorization server sent back to the redirect URI.
    class Redirect
      attr_reader :code, :state

      def initialize(code:, state:)
        @code = code
        @state = state
        freeze
      end
    end

    # Capture the OAuth redirect on +127.0.0.1+.
    #
    # A native app has no web server to redirect to, so it runs one for a few
    # seconds: bind a loopback port, send the user to the consent page, and read
    # the +code+ off the single request the browser makes coming back.
    #
    # This lives in its own file rather than in {AuthCode} so a headless caller
    # can take the flow without a listener it will never bind — the same split
    # every conduit SDK makes, so the surface looks the same in every language.
    # It needs nothing beyond the standard library.
    #
    #   listener = DatagroutConduit::AuthCode::LoopbackListener.bind
    #   flow = DatagroutConduit::AuthCode::Flow.discover(GATEWAY)
    #   flow.register("My App", listener.redirect_uri)
    #
    #   url, pending = flow.authorize_url
    #   puts "Open: #{url}"
    #
    #   redirect = listener.wait(timeout: 300)
    #   grant = flow.exchange(pending, redirect.code, redirect.state)
    class LoopbackListener
      # Most bytes read from a redirect request. A URL longer than this is not a
      # redirect we can use.
      MAX_REQUEST_BYTES = 8192

      attr_reader :port

      def initialize(server, port, path)
        @server = server
        @port = port
        @path = path
      end

      # Bind an OS-assigned port on +127.0.0.1+.
      #
      # Letting the OS choose avoids fighting whatever else owns a fixed port —
      # and because registration happens after binding, the real port is already
      # known by the time the redirect URI is registered.
      def self.bind
        bind_on(0, "/callback")
      end

      # Bind a specific port and path.
      #
      # Use when the client was registered out of band against a fixed redirect
      # URI and the authorization server will accept no other.
      def self.bind_on(port, path)
        server = begin
          TCPServer.new("127.0.0.1", port)
        rescue SystemCallError => e
          raise HttpError, "cannot bind loopback port: #{e.message}"
        end

        normalized = path.to_s.start_with?("/") ? path.to_s : "/#{path}"
        new(server, server.addr[1], normalized)
      end

      # Re-bind the exact port and path of a previously registered redirect URI.
      #
      # Needed whenever a saved {RegisteredClient} is reused: the authorization
      # server matches the redirect URI exactly, so the listener has to come
      # back on the same port it registered.
      #
      # Raises if that port is occupied. The right recovery is to {bind} a fresh
      # port and register a new client — not to retry, and not to authorize
      # against a URI the server will reject.
      def self.bind_for(redirect_uri)
        parsed = begin
          URI.parse(redirect_uri.to_s)
        rescue URI::InvalidURIError => e
          raise HttpError, "bad redirect_uri #{redirect_uri}: #{e.message}"
        end

        raise HttpError, "bad redirect_uri #{redirect_uri}" unless parsed.scheme && parsed.host

        # URI fills in the scheme's default port, so `parsed.port` cannot tell
        # an explicit one from an absent one. The authority is what decides.
        unless redirect_uri.to_s.include?("#{parsed.host}:#{parsed.port}")
          raise HttpError, "redirect_uri #{redirect_uri} names no port"
        end

        bind_on(parsed.port, parsed.path.empty? ? "/" : parsed.path)
      end

      # The redirect URI to register and to send in the authorize request.
      #
      # Uses +127.0.0.1+ rather than +localhost+: RFC 8252 recommends the
      # literal address, and it sidesteps hosts where +localhost+ resolves to
      # IPv6 first while the listener is bound to IPv4.
      def redirect_uri
        "http://127.0.0.1:#{@port}#{@path}"
      end

      # Wait for the browser's redirect, up to +timeout+ seconds.
      #
      # Serves a small page either way so the user sees an outcome rather than a
      # browser error, then stops listening. Requests to other paths are
      # answered 404 and ignored — browsers routinely ask for +/favicon.ico+,
      # and treating that as the redirect would abort the flow.
      def wait(timeout: 300)
        # A monotonic clock, because this measures an interval. Grant expiry is
        # the opposite case and uses Unix seconds, so it survives being written
        # down.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0 || IO.select([@server], nil, nil, remaining).nil?
            raise HttpError,
                  "timed out after #{timeout.round}s waiting for the authorization redirect"
          end

          outcome = handle(@server.accept)
          next if outcome.nil?

          raise outcome if outcome.is_a?(StandardError)

          return outcome
        end
      ensure
        close
      end

      # Stop listening. Safe to call more than once.
      def close
        @server.close unless @server.closed?
      rescue IOError
        nil
      end

      private

      # Serve one request. Returns a {Redirect} on success, an exception to
      # raise, or nil when the request was not the redirect and we should keep
      # waiting.
      def handle(socket)
        target = request_target(socket.readpartial(MAX_REQUEST_BYTES))
        return nil if target.nil?

        path, _, query = target.partition("?")

        unless path == @path
          respond(socket, 404, "Not found")
          return nil
        end

        params = parse_query(query)

        if params.key?("error")
          respond(socket, 200, "Authorization was denied. You can close this window.")
          return DeniedError.new(error: params["error"],
                                 description: params["error_description"])
        end

        if params.key?("code") && params.key?("state")
          respond(socket, 200, "Signed in. You can close this window and return to the app.")
          return Redirect.new(code: params["code"], state: params["state"])
        end

        respond(socket, 400, "Missing code or state.")
        DiscoveryError.new("redirect carried neither an error nor a code/state pair")
      rescue EOFError
        nil
      ensure
        begin
          socket.close
        rescue IOError
          nil
        end
      end

      # The request target from a raw HTTP request line.
      def request_target(request)
        first = request.to_s.split(/\r?\n/, 2).first.to_s
        parts = first.split
        parts.length >= 2 ? parts[1] : nil
      end

      # Decode a query string.
      #
      # Authorization codes and state values are opaque and routinely contain
      # characters that must survive a round trip through the query string, so
      # +%XX+ escapes and +++ are decoded.
      def parse_query(query)
        query.to_s.split("&").each_with_object({}) do |pair, out|
          key, sep, value = pair.partition("=")
          next if sep.empty?

          out[unescape(key)] = unescape(value)
        end
      end

      def unescape(value)
        value.tr("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }
             .force_encoding(Encoding::UTF_8)
      end

      def respond(socket, status, message)
        body = <<~HTML
          <!DOCTYPE html><html><head><meta charset="utf-8"><title>DataGrout</title>
          <style>body{font:15px/1.5 system-ui,sans-serif;margin:16vh auto;max-width:26rem;text-align:center;color-scheme:light dark}</style></head>
          <body><p>#{message}</p></body></html>
        HTML

        socket.write(
          "HTTP/1.1 #{status} OK\r\n" \
          "content-type: text/html; charset=utf-8\r\n" \
          "content-length: #{body.bytesize}\r\n" \
          "connection: close\r\n\r\n#{body}"
        )
        socket.flush
      rescue IOError, SystemCallError
        # The browser may have closed already; the outcome is what matters.
        nil
      end
    end
  end
end
