# frozen_string_literal: true

require "openssl"

module DatagroutConduit
  # mTLS client identity for Conduit connections.
  #
  # Holds the client certificate and private key presented during every TLS
  # handshake. The server verifies the caller's identity without any
  # application-layer token.
  #
  # == Auto-discovery order (try_discover)
  #
  # 1. +override_dir+ (if provided)
  # 2. +CONDUIT_MTLS_CERT+ / +CONDUIT_MTLS_KEY+ env vars (PEM strings)
  # 3. +CONDUIT_IDENTITY_DIR+ env var → directory with identity.pem + identity_key.pem
  # 4. +~/.conduit/identity.pem+ + +identity_key.pem+
  # 5. +.conduit/+ relative to cwd
  class Identity
    attr_reader :cert_pem, :key_pem, :ca_pem, :expires_at

    def initialize(cert_pem:, key_pem:, ca_pem: nil, expires_at: nil)
      validate_cert!(cert_pem)
      validate_key!(key_pem)
      @cert_pem = cert_pem
      @key_pem = key_pem
      @ca_pem = ca_pem
      @expires_at = expires_at
    end

    # Build from PEM strings already in memory.
    def self.from_pem(cert_pem, key_pem, ca_pem: nil)
      new(cert_pem: cert_pem, key_pem: key_pem, ca_pem: ca_pem)
    end

    # Build by reading PEM files from disk.
    def self.from_paths(cert_path, key_path, ca_path: nil)
      cert_pem = File.read(cert_path)
      key_pem = File.read(key_path)
      ca_pem = ca_path ? File.read(ca_path) : nil
      new(cert_pem: cert_pem, key_pem: key_pem, ca_pem: ca_pem)
    rescue Errno::ENOENT => e
      raise ConfigError, "Cannot read identity file: #{e.message}"
    end

    # Build from environment variables.
    #
    # Variables:
    # - CONDUIT_MTLS_CERT — PEM string for the client certificate
    # - CONDUIT_MTLS_KEY  — PEM string for the private key
    # - CONDUIT_MTLS_CA   — PEM string for the CA (optional)
    #
    # Returns nil if CONDUIT_MTLS_CERT is not set.
    def self.from_env
      cert = ENV["CONDUIT_MTLS_CERT"]
      return nil if cert.nil? || cert.empty?

      key = ENV["CONDUIT_MTLS_KEY"]
      raise ConfigError, "CONDUIT_MTLS_CERT is set but CONDUIT_MTLS_KEY is missing" if key.nil? || key.empty?

      ca = ENV["CONDUIT_MTLS_CA"]
      ca = nil if ca && ca.empty?

      new(cert_pem: cert, key_pem: key, ca_pem: ca)
    end

    # Walk the auto-discovery chain and return the first identity found,
    # or nil if nothing is available.
    def self.try_discover(override_dir: nil)
      # 1. Override directory
      if override_dir
        id = try_load_from_dir(override_dir)
        return id if id
      end

      # 2. Environment variables (individual cert/key PEMs)
      id = from_env
      return id if id

      # 3. CONDUIT_IDENTITY_DIR env var
      identity_dir = ENV["CONDUIT_IDENTITY_DIR"]
      if identity_dir && !identity_dir.empty?
        id = try_load_from_dir(identity_dir)
        return id if id
      end

      # 4. ~/.conduit/
      home = ENV["HOME"] || ENV["USERPROFILE"]
      if home
        id = try_load_from_dir(File.join(home, ".conduit"))
        return id if id
      end

      # 5. .conduit/ relative to cwd
      id = try_load_from_dir(File.join(Dir.pwd, ".conduit"))
      return id if id

      nil
    rescue ConfigError
      nil
    end

    def with_expiry(expires_at)
      dup.tap { |i| i.instance_variable_set(:@expires_at, expires_at) }
    end

    # Returns true if the certificate expires within +threshold_days+.
    # Returns false when no expiry is known.
    def needs_rotation?(threshold_days: 30)
      return false if @expires_at.nil?

      deadline = Time.now + (threshold_days * 86_400)
      deadline > @expires_at
    end

    # Return an OpenSSL::X509::Certificate for use with Faraday SSL config.
    def openssl_cert
      OpenSSL::X509::Certificate.new(@cert_pem)
    end

    # Return an OpenSSL::PKey for use with Faraday SSL config.
    def openssl_key
      OpenSSL::PKey.read(@key_pem)
    end

    # Return an OpenSSL::X509::Certificate for the CA, if present.
    def openssl_ca
      @ca_pem ? OpenSSL::X509::Certificate.new(@ca_pem) : nil
    end

    # Configure Faraday SSL options with this identity's mTLS credentials.
    def configure_ssl(ssl)
      ssl.client_cert = openssl_cert
      ssl.client_key = openssl_key
      if @ca_pem
        store = OpenSSL::X509::Store.new
        store.add_cert(openssl_ca)
        ssl.cert_store = store
      end
    end

    class << self
      private

      def try_load_from_dir(dir)
        cert_path = File.join(dir, "identity.pem")
        key_path = File.join(dir, "identity_key.pem")
        return nil unless File.exist?(cert_path) && File.exist?(key_path)

        ca_path = File.join(dir, "ca.pem")
        ca = File.exist?(ca_path) ? ca_path : nil

        from_paths(cert_path, key_path, ca_path: ca)
      rescue ConfigError
        nil
      end
    end

    private

    def validate_cert!(pem)
      unless pem.include?("-----BEGIN CERTIFICATE-----")
        raise ConfigError, "cert_pem does not appear to contain a PEM certificate"
      end
    end

    def validate_key!(pem)
      valid = pem.include?("-----BEGIN PRIVATE KEY-----") ||
              pem.include?("-----BEGIN RSA PRIVATE KEY-----") ||
              pem.include?("-----BEGIN EC PRIVATE KEY-----") ||
              pem.include?("-----BEGIN ENCRYPTED PRIVATE KEY-----")
      raise ConfigError, "key_pem does not appear to contain a PEM private key" unless valid
    end
  end
end
