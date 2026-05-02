# frozen_string_literal: true

require "websocket/driver"
require "socket"
require "openssl"
require "uri"
require "thread"
require "json"
require "securerandom"
require "base64"
require "timeout"

module DatagroutConduit
  module Transport
    # WebSocket transport for datagrout-jsonrpc.v1.
    #
    # Manages a single wss:// connection with concurrent JSON-RPC request
    # multiplexing and server-push subscriptions. Uses a background thread
    # for frame reading; callers block on Thread::Queue for responses.
    #
    # Usage:
    #   ws = DatagroutConduit::Transport::Ws.new(
    #     url: "wss://gateway.datagrout.ai/servers/<uuid>/ws",
    #     auth: { bearer: "token" }
    #   )
    #   ws.connect
    #   result = ws.send_request("tools/list")
    #   sub    = ws.subscribe("agents.my-agent.events")
    #   event  = sub.recv
    #   ws.unsubscribe(sub)
    #   ws.disconnect
    class Ws
      SUBPROTOCOL = "datagrout-jsonrpc.v1"

      # ── Subscription ─────────────────────────────────────────────────────────

      # Per-subscription event stream delivered via a thread-safe Queue.
      # Call recv to block until the next event, or iterate with each.
      class Subscription
        attr_reader :sub_id, :topic

        def initialize(sub_id, topic)
          @sub_id = sub_id
          @topic  = topic
          @queue  = ::Thread::Queue.new
          @closed = false
        end

        # Block until the next event arrives.
        # Returns nil and raises StopIteration on close when iterating via each.
        # @param timeout [Numeric, nil] optional timeout in seconds; returns nil on expiry
        def recv(timeout: nil)
          event =
            if timeout
              Timeout.timeout(timeout) { @queue.pop }
            else
              @queue.pop
            end

          raise StopIteration if event.nil?

          event
        rescue Timeout::Error
          nil
        end

        # Iterate over events until the subscription is closed.
        def each(&block)
          loop do
            event = @queue.pop
            break if event.nil?
            block.call(event)
          end
        end

        include Enumerable

        def closed?
          @closed
        end

        # @api private
        def _enqueue(event)
          @queue.push(event) unless @closed
        end

        # @api private
        def _close
          return if @closed

          @closed = true
          @queue.push(nil)
        end
      end

      # Value object for a push notification delivered to a subscription.
      SubscriptionEvent = Struct.new(:subscription, :event, :data, keyword_init: true)

      # ── Construction ─────────────────────────────────────────────────────────

      def initialize(url:, auth: {}, identity: nil)
        @url      = url
        @auth     = normalize_auth(auth)
        @identity = identity
        @mutex    = Mutex.new
        @write_mutex = Mutex.new

        @pending           = {}  # id => RequestFuture
        @pending_subscribe = {}  # id => { topic:, future: }
        @subscriptions     = {}  # sub_id => [Subscription, ...]
        @next_id           = 0

        @io          = nil
        @driver      = nil
        @read_thread = nil
        @connected   = false
      end

      # ── Public API ────────────────────────────────────────────────────────────

      # Establish the WebSocket connection.
      # Blocks until the server-side handshake completes (up to 10 s).
      def connect
        uri = URI.parse(@url)
        @io = open_socket(uri)

        adapter = SocketAdapter.new(@url, @io)
        @driver = WebSocket::Driver.client(adapter, protocols: [SUBPROTOCOL])

        build_upgrade_headers.each { |k, v| @driver.set_header(k, v) }

        handshake_q = ::Thread::Queue.new

        @driver.on(:open)    { handshake_q.push(nil) unless @connected }
        @driver.on(:message) { |e| handle_message(e.data) }
        @driver.on(:close)   { handle_disconnect }
        @driver.on(:error)   { |e| handshake_q.push(e.message) unless @connected }

        @driver.start
        @read_thread = Thread.new { read_loop }
        @read_thread.abort_on_exception = false
        @read_thread.name = "conduit-ws-reader"

        err = Timeout.timeout(10) { handshake_q.pop }
        raise ConnectionError, "WebSocket handshake failed: #{err}" if err

        @connected = true
        self
      rescue Timeout::Error
        cleanup_socket
        raise ConnectionError, "WebSocket connection timed out"
      rescue ConnectionError
        raise
      rescue => e
        cleanup_socket
        raise ConnectionError, "WebSocket connect error: #{e.message}"
      end

      # Close the connection and fail all pending requests.
      def disconnect
        @mutex.synchronize { @connected = false }
        fail_all_pending(:disconnected)
        cleanup_socket
        self
      end

      def connected?
        @connected
      end

      # Send a JSON-RPC request and block until the response arrives.
      # Pass id: nil to fire a notification (no response expected).
      # Returns the result value, or raises McpError on RPC-level error.
      def send_request(method, params = nil, id: :auto)
        ensure_connected!

        # id: nil means fire-and-forget notification (no id field, no response wait)
        if id.nil?
          frame = { "jsonrpc" => "2.0", "method" => method }
          frame["params"] = params if params
          write_frame(frame)
          return { "result" => {} }
        end

        req_id = mint_id
        future = RequestFuture.new
        @mutex.synchronize { @pending[req_id] = future }

        write_frame(build_request(req_id, method, params))

        result, value = future.wait
        if result == :ok
          { "result" => value }
        else
          raise McpError.new(code: -1, message: value.to_s, data: nil)
        end
      end

      # Subscribe to a dotted-namespace topic.
      # Returns a Subscription that delivers events via recv / each.
      def subscribe(topic)
        ensure_connected!

        req_id = mint_id
        future = RequestFuture.new
        @mutex.synchronize { @pending_subscribe[req_id] = { topic: topic, future: future } }

        write_frame(build_request(req_id, "subscribe", { "topic" => topic }))

        result, value = future.wait
        if result == :ok
          sub_id = value.is_a?(Hash) ? (value["subscription"] || req_id) : req_id
          sub = Subscription.new(sub_id, topic)
          @mutex.synchronize do
            @subscriptions[sub_id] ||= []
            @subscriptions[sub_id] << sub
          end
          sub
        else
          raise McpError.new(code: -1, message: value.to_s, data: nil)
        end
      end

      # Cancel a push subscription locally and notify the server.
      # Accepts a Subscription object or a subscription ID string.
      def unsubscribe(subscription)
        sub_id = subscription.is_a?(Subscription) ? subscription.sub_id : subscription.to_s

        subs = @mutex.synchronize { @subscriptions.delete(sub_id) || [] }
        subs.each(&:_close)

        if @connected
          req_id = mint_id
          write_frame(build_request(req_id, "unsubscribe", { "subscription" => sub_id }))
        end

        :ok
      end

      private

      # ── Socket adapter for websocket-driver ──────────────────────────────────

      class SocketAdapter
        attr_reader :url

        def initialize(url, io)
          @url = url
          @io  = io
        end

        def write(data)
          @io.write(data)
          data.bytesize
        end
      end

      # ── Request future ────────────────────────────────────────────────────────

      class RequestFuture
        def initialize
          @queue = ::Thread::Queue.new
        end

        def wait(timeout: 30)
          Timeout.timeout(timeout) { @queue.pop }
        rescue Timeout::Error
          [:error, "Request timed out after #{timeout}s"]
        end

        def resolve(value)
          @queue.push([:ok, value])
        end

        def reject(reason)
          @queue.push([:error, reason])
        end
      end

      # ── Socket creation ───────────────────────────────────────────────────────

      def open_socket(uri)
        host = uri.host
        port = uri.port || (uri.scheme == "wss" ? 443 : 80)

        tcp = TCPSocket.new(host, port)
        tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

        if uri.scheme == "wss"
          ctx = build_ssl_context
          ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
          ssl.hostname = host
          ssl.sync_close = true
          ssl.connect
          ssl
        else
          tcp
        end
      end

      def build_ssl_context
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)

        if @identity
          ctx.cert = @identity.openssl_cert
          ctx.key  = @identity.openssl_key
          if @identity.ca_pem
            store = OpenSSL::X509::Store.new
            store.add_cert(@identity.openssl_ca)
            ctx.cert_store = store
          end
        end

        ctx
      end

      # ── Upgrade headers ───────────────────────────────────────────────────────

      def build_upgrade_headers
        headers = {}

        case @auth[:type]
        when :bearer
          headers["Authorization"] = "Bearer #{@auth[:token]}"
        when :api_key
          headers["X-API-Key"] = @auth[:key]
        when :basic
          encoded = Base64.strict_encode64("#{@auth[:username]}:#{@auth[:password]}")
          headers["Authorization"] = "Basic #{encoded}"
        when :oauth
          token = @auth[:provider].get_token
          headers["Authorization"] = "Bearer #{token}"
        end

        headers
      end

      # ── Read loop ─────────────────────────────────────────────────────────────

      def read_loop
        loop do
          data = @io.readpartial(4096)
          @driver.parse(data)
        rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
          handle_disconnect
          break
        rescue StandardError
          handle_disconnect
          break
        end
      end

      # ── Message routing ───────────────────────────────────────────────────────

      def handle_message(raw)
        msg = JSON.parse(raw)

        str_id = msg["id"]&.to_s

        if str_id && (entry = @mutex.synchronize { @pending_subscribe.delete(str_id) })
          future = entry[:future]
          if msg["error"]
            future.reject(msg.dig("error", "message") || "Subscribe failed")
          else
            future.resolve(msg["result"] || {})
          end

        elsif str_id && (future = @mutex.synchronize { @pending.delete(str_id) })
          if msg["error"]
            future.reject(msg.dig("error", "message") || "RPC error")
          else
            future.resolve(msg["result"])
          end

        elsif msg["method"] == "notification"
          route_notification(msg["params"] || {})
        end
      rescue JSON::ParserError
        # Silently discard malformed frames
      end

      def route_notification(params)
        sub_id = params["subscription"]
        return unless sub_id.is_a?(String)

        subs = @mutex.synchronize { @subscriptions[sub_id] }
        return unless subs

        event = SubscriptionEvent.new(
          subscription: sub_id,
          event: params["event"] || "",
          data: params["data"]
        )

        subs.each { |sub| sub._enqueue(event) }
      end

      def handle_disconnect
        was_connected = @mutex.synchronize do
          old = @connected
          @connected = false
          old
        end

        fail_all_pending(:disconnected) if was_connected
      end

      def fail_all_pending(reason)
        pending, pending_sub, subs = @mutex.synchronize do
          p  = @pending.dup
          ps = @pending_subscribe.dup
          s  = @subscriptions.dup
          @pending.clear
          @pending_subscribe.clear
          @subscriptions.clear
          [p, ps, s]
        end

        pending.each_value     { |f| f.reject(reason) }
        pending_sub.each_value { |entry| entry[:future].reject(reason) }
        subs.each_value        { |list| list.each(&:_close) }
      end

      def cleanup_socket
        @write_mutex.synchronize do
          @driver = nil
        end
        @read_thread&.kill
        @read_thread = nil
        @io&.close rescue nil
        @io = nil
      end

      # ── Helpers ───────────────────────────────────────────────────────────────

      def ensure_connected!
        raise NotInitializedError, "WebSocket not connected. Call connect() first." unless @connected
      end

      def mint_id
        @mutex.synchronize do
          @next_id += 1
          "ws-#{@next_id}"
        end
      end

      def build_request(id, method, params)
        body = { "jsonrpc" => "2.0", "id" => id, "method" => method }
        body["params"] = params if params
        body
      end

      def write_frame(data)
        json = JSON.generate(data)
        @write_mutex.synchronize { @driver&.text(json) }
      end

      def normalize_auth(auth)
        return { type: :none } if auth.nil? || auth.empty?

        auth = auth.transform_keys(&:to_sym) if auth.is_a?(Hash)

        if auth[:bearer]
          { type: :bearer, token: auth[:bearer] }
        elsif auth[:api_key]
          { type: :api_key, key: auth[:api_key] }
        elsif auth[:basic]
          { type: :basic, username: auth[:basic][:username], password: auth[:basic][:password] }
        elsif auth[:oauth] || auth[:provider]
          { type: :oauth, provider: auth[:oauth] || auth[:provider] }
        else
          { type: :none }
        end
      end
    end
  end
end
