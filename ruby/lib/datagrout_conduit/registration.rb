# frozen_string_literal: true

require "openssl"
require "base64"
require "fileutils"
require "faraday"
require "json"

module DatagroutConduit
  # Substrate identity registration with the DataGrout CA.
  #
  # Handles the issuance flow — turning a freshly-generated keypair into a
  # DG-CA-signed Identity that DataGrout will accept for mTLS.
  #
  # == Flow
  #
  # 1. Generate an ECDSA P-256 keypair with {.generate_keypair}.
  #    The private key never leaves the client.
  # 2. Send the *public key* to the DataGrout CA via {.register_identity}
  #    (authenticated with a bearer token — user access token or API key).
  # 3. Persist the returned identity to +~/.conduit/+ via {.save_identity}
  #    for auto-discovery by future sessions.
  # 4. On renewal (cert near expiry), call {.rotate_identity} which presents
  #    the *existing* client certificate over mTLS — no API key needed.
  class Registration
    DG_CA_URL = "https://ca.datagrout.ai/ca.pem"
    DG_SUBSTRATE_ENDPOINT = "https://app.datagrout.ai/api/v1/substrate/identity"

    # Generate an ECDSA P-256 keypair.
    #
    # @return [Array(String, String)] +[private_key_pem, public_key_pem]+
    def self.generate_keypair
      key = OpenSSL::PKey::EC.generate("prime256v1")
      private_pem = key.to_pem

      public_pem = if key.respond_to?(:public_to_pem)
                     key.public_to_pem
                   else
                     pub = OpenSSL::PKey::EC.new(key.group)
                     pub.public_key = key.public_key
                     pub.to_pem
                   end

      [private_pem, public_pem]
    end

    # Register identity with the DataGrout CA.
    #
    # Sends only the public key. The private key never leaves the client.
    # Authenticated with a bearer token (user access token or API key).
    #
    # @param public_key_pem [String] PEM-encoded public key
    # @param auth_token [String] bearer token for authentication
    # @param name [String] human-readable label for the substrate instance
    # @param substrate_endpoint [String] registration endpoint URL
    # @return [RegistrationResponse]
    def self.register_identity(public_key_pem, auth_token:, name: "conduit-client",
                               substrate_endpoint: DG_SUBSTRATE_ENDPOINT)
      conn = Faraday.new(url: substrate_endpoint) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end

      response = conn.post do |req|
        req.url "register"
        req.headers["Authorization"] = "Bearer #{auth_token}"
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(
          name: name,
          public_key_pem: public_key_pem
        )
      end

      unless response.success?
        raise AuthError, "Registration failed (HTTP #{response.status}): #{response.body}"
      end

      body = response.body
      body = JSON.parse(body) if body.is_a?(String)

      RegistrationResponse.new(
        id: body["id"],
        cert_pem: body["cert_pem"],
        ca_cert_pem: body["ca_cert_pem"],
        fingerprint: body["fingerprint"],
        name: body["name"],
        registered_at: body["registered_at"],
        valid_until: body["valid_until"]
      )
    end

    # Rotate identity using existing mTLS cert.
    #
    # Generates a new public key, sends it to the +/rotate+ endpoint
    # authenticated by the *current* cert over mTLS (no API key needed),
    # and returns a fresh DG-CA-signed certificate.
    #
    # @param identity [Identity] current mTLS identity for authentication
    # @param new_public_key_pem [String] PEM-encoded new public key
    # @param name [String] human-readable label
    # @param substrate_endpoint [String] registration endpoint URL
    # @return [RegistrationResponse]
    def self.rotate_identity(identity, new_public_key_pem, name: "conduit-client",
                             substrate_endpoint: DG_SUBSTRATE_ENDPOINT)
      conn = Faraday.new(url: substrate_endpoint) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
        identity.configure_ssl(f.ssl)
      end

      response = conn.post do |req|
        req.url "rotate"
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(
          name: name,
          public_key_pem: new_public_key_pem
        )
      end

      unless response.success?
        raise ConnectionError, "Rotation failed (HTTP #{response.status}): #{response.body}"
      end

      body = response.body
      body = JSON.parse(body) if body.is_a?(String)

      RegistrationResponse.new(
        id: body["id"],
        cert_pem: body["cert_pem"],
        ca_cert_pem: body["ca_cert_pem"],
        fingerprint: body["fingerprint"],
        name: body["name"],
        registered_at: body["registered_at"],
        valid_until: body["valid_until"]
      )
    end

    # Save identity files to a directory with secure permissions (0600).
    #
    # @param cert_pem [String] DG-signed certificate PEM
    # @param key_pem [String] private key PEM
    # @param dir [String] directory path
    # @param ca_pem [String, nil] CA certificate PEM
    # @return [Hash] paths to written files (+:cert+, +:key+, +:ca+)
    def self.save_identity(cert_pem, key_pem, dir, ca_pem: nil)
      FileUtils.mkdir_p(dir)

      cert_path = File.join(dir, "identity.pem")
      key_path = File.join(dir, "identity_key.pem")

      File.write(cert_path, cert_pem)
      File.write(key_path, key_pem)
      File.chmod(0o600, cert_path)
      File.chmod(0o600, key_path)

      paths = { cert: cert_path, key: key_path }

      if ca_pem
        ca_path = File.join(dir, "ca.pem")
        File.write(ca_path, ca_pem)
        File.chmod(0o600, ca_path)
        paths[:ca] = ca_path
      end

      paths
    end

    # Fetch the DataGrout CA certificate from +ca.datagrout.ai+.
    #
    # Uses the system trust store for TLS (not the DG CA itself), so there
    # is no circularity.
    #
    # @param ca_url [String] URL to fetch the CA cert from
    # @return [String] PEM-encoded CA certificate
    def self.fetch_ca_cert(ca_url: DG_CA_URL)
      response = Faraday.get(ca_url)

      unless response.success?
        raise ConnectionError, "Failed to fetch CA cert (HTTP #{response.status})"
      end

      pem = response.body
      unless pem.include?("-----BEGIN CERTIFICATE-----")
        raise ConnectionError, "Response from #{ca_url} does not look like a PEM certificate"
      end

      pem
    end

    # Refresh CA cert in the given directory.
    #
    # @param dir [String] directory to write +ca.pem+ into
    # @param ca_url [String] URL to fetch the CA cert from
    # @return [String] path to the written +ca.pem+ file
    def self.refresh_ca_cert(dir, ca_url: DG_CA_URL)
      ca_pem = fetch_ca_cert(ca_url: ca_url)
      FileUtils.mkdir_p(dir)
      ca_path = File.join(dir, "ca.pem")
      File.write(ca_path, ca_pem)
      File.chmod(0o600, ca_path)
      ca_path
    end

    # Returns +~/.conduit/+ as the canonical identity directory.
    #
    # @return [String, nil]
    def self.default_identity_dir
      home = ENV["HOME"] || ENV["USERPROFILE"]
      home ? File.join(home, ".conduit") : nil
    end
  end

  RegistrationResponse = Struct.new(
    :id, :cert_pem, :ca_cert_pem, :fingerprint,
    :name, :registered_at, :valid_until,
    keyword_init: true
  )
end
