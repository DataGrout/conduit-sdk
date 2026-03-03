# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "openssl"

class RegistrationTest < Minitest::Test
  SUBSTRATE_ENDPOINT = "https://app.datagrout.ai/api/v1/substrate/identity"
  CA_URL = "https://ca.datagrout.ai/ca.pem"
  SERVER_URL = "https://gateway.datagrout.ai/servers/test-uuid/mcp"
  TOKEN_ENDPOINT = "https://gateway.datagrout.ai/servers/test-uuid/oauth/token"

  # Fake PEMs for tests that only check string content, not OpenSSL parsing.
  SAMPLE_CERT = <<~PEM
    -----BEGIN CERTIFICATE-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
    -----END CERTIFICATE-----
  PEM

  SAMPLE_KEY = <<~PEM
    -----BEGIN EC PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEA
    -----END EC PRIVATE KEY-----
  PEM

  SAMPLE_CA = <<~PEM
    -----BEGIN CERTIFICATE-----
    MIIBkDCB+gIJALRiMLAh1kkKMA0GCSqGSIb3DQEBCwUA
    -----END CERTIFICATE-----
  PEM

  # Generate a valid self-signed cert + key for tests that build a full Client
  # (which invokes OpenSSL parsing through the transport layer).
  def self.generate_real_identity
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=test-conduit")
    cert.issuer = cert.subject
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400 * 365
    cert.public_key = key
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    [cert.to_pem, key.to_pem]
  end

  REAL_CERT, REAL_KEY = generate_real_identity

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ================================================================
  # generate_keypair
  # ================================================================

  def test_generate_keypair_returns_two_pem_strings
    private_pem, public_pem = DatagroutConduit::Registration.generate_keypair

    assert private_pem.include?("-----BEGIN EC PRIVATE KEY-----") ||
           private_pem.include?("-----BEGIN PRIVATE KEY-----"),
           "Expected private key PEM header"

    assert public_pem.include?("-----BEGIN PUBLIC KEY-----") ||
           public_pem.include?("-----BEGIN EC PRIVATE KEY-----"),
           "Expected public key PEM header"
  end

  def test_generate_keypair_produces_valid_ec_key
    private_pem, _public_pem = DatagroutConduit::Registration.generate_keypair

    key = OpenSSL::PKey.read(private_pem)
    assert_kind_of OpenSSL::PKey::EC, key
    assert_equal "prime256v1", key.group.curve_name
  end

  def test_generate_keypair_produces_unique_keys
    pair_a = DatagroutConduit::Registration.generate_keypair
    pair_b = DatagroutConduit::Registration.generate_keypair

    refute_equal pair_a[0], pair_b[0], "Two generated keypairs should differ"
  end

  # ================================================================
  # save_identity
  # ================================================================

  def test_save_identity_creates_files
    Dir.mktmpdir do |dir|
      paths = DatagroutConduit::Registration.save_identity(SAMPLE_CERT, SAMPLE_KEY, dir)

      assert File.exist?(paths[:cert])
      assert File.exist?(paths[:key])
      assert_equal SAMPLE_CERT, File.read(paths[:cert])
      assert_equal SAMPLE_KEY, File.read(paths[:key])
      assert_nil paths[:ca]
    end
  end

  def test_save_identity_creates_ca_file
    Dir.mktmpdir do |dir|
      paths = DatagroutConduit::Registration.save_identity(SAMPLE_CERT, SAMPLE_KEY, dir, ca_pem: SAMPLE_CA)

      assert File.exist?(paths[:ca])
      assert_equal SAMPLE_CA, File.read(paths[:ca])
    end
  end

  def test_save_identity_sets_permissions
    Dir.mktmpdir do |dir|
      paths = DatagroutConduit::Registration.save_identity(SAMPLE_CERT, SAMPLE_KEY, dir, ca_pem: SAMPLE_CA)

      assert_equal 0o600, File.stat(paths[:cert]).mode & 0o777
      assert_equal 0o600, File.stat(paths[:key]).mode & 0o777
      assert_equal 0o600, File.stat(paths[:ca]).mode & 0o777
    end
  end

  def test_save_identity_creates_dir_if_missing
    Dir.mktmpdir do |base|
      nested = File.join(base, "a", "b", "c")
      paths = DatagroutConduit::Registration.save_identity(SAMPLE_CERT, SAMPLE_KEY, nested)

      assert File.directory?(nested)
      assert File.exist?(paths[:cert])
    end
  end

  def test_save_identity_uses_standard_filenames
    Dir.mktmpdir do |dir|
      paths = DatagroutConduit::Registration.save_identity(SAMPLE_CERT, SAMPLE_KEY, dir, ca_pem: SAMPLE_CA)

      assert_equal File.join(dir, "identity.pem"), paths[:cert]
      assert_equal File.join(dir, "identity_key.pem"), paths[:key]
      assert_equal File.join(dir, "ca.pem"), paths[:ca]
    end
  end

  # ================================================================
  # fetch_ca_cert
  # ================================================================

  def test_fetch_ca_cert_success
    stub_request(:get, CA_URL)
      .to_return(
        status: 200,
        body: SAMPLE_CA
      )

    pem = DatagroutConduit::Registration.fetch_ca_cert
    assert_equal SAMPLE_CA, pem
  end

  def test_fetch_ca_cert_custom_url
    custom_url = "https://custom-ca.example.com/ca.pem"
    stub_request(:get, custom_url)
      .to_return(status: 200, body: SAMPLE_CA)

    pem = DatagroutConduit::Registration.fetch_ca_cert(ca_url: custom_url)
    assert_equal SAMPLE_CA, pem
  end

  def test_fetch_ca_cert_raises_on_failure
    stub_request(:get, CA_URL).to_return(status: 500, body: "error")

    assert_raises(DatagroutConduit::ConnectionError) do
      DatagroutConduit::Registration.fetch_ca_cert
    end
  end

  def test_fetch_ca_cert_raises_on_invalid_pem
    stub_request(:get, CA_URL).to_return(status: 200, body: "not a cert")

    assert_raises(DatagroutConduit::ConnectionError) do
      DatagroutConduit::Registration.fetch_ca_cert
    end
  end

  # ================================================================
  # refresh_ca_cert
  # ================================================================

  def test_refresh_ca_cert_writes_file
    stub_request(:get, CA_URL).to_return(status: 200, body: SAMPLE_CA)

    Dir.mktmpdir do |dir|
      path = DatagroutConduit::Registration.refresh_ca_cert(dir)

      assert_equal File.join(dir, "ca.pem"), path
      assert_equal SAMPLE_CA, File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  # ================================================================
  # register_identity
  # ================================================================

  def test_register_identity_success
    stub_request(:post, "#{SUBSTRATE_ENDPOINT}/register")
      .with(
        headers: { "Authorization" => "Bearer test-token" }
      )
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(
          "id" => "sub_123",
          "cert_pem" => SAMPLE_CERT,
          "ca_cert_pem" => SAMPLE_CA,
          "fingerprint" => "abc123",
          "name" => "conduit-client",
          "registered_at" => "2026-03-01T00:00:00Z",
          "valid_until" => "2026-03-31T00:00:00Z"
        )
      )

    _private_pem, public_pem = DatagroutConduit::Registration.generate_keypair
    reg = DatagroutConduit::Registration.register_identity(
      public_pem,
      auth_token: "test-token"
    )

    assert_equal "sub_123", reg.id
    assert_equal SAMPLE_CERT, reg.cert_pem
    assert_equal SAMPLE_CA, reg.ca_cert_pem
    assert_equal "abc123", reg.fingerprint
    assert_equal "conduit-client", reg.name
    assert_equal "2026-03-31T00:00:00Z", reg.valid_until
  end

  def test_register_identity_failure
    stub_request(:post, "#{SUBSTRATE_ENDPOINT}/register")
      .to_return(status: 401, body: "Unauthorized")

    assert_raises(DatagroutConduit::AuthError) do
      DatagroutConduit::Registration.register_identity(
        "PUBLIC KEY PEM",
        auth_token: "bad-token"
      )
    end
  end

  # ================================================================
  # default_identity_dir
  # ================================================================

  def test_default_identity_dir
    dir = DatagroutConduit::Registration.default_identity_dir
    refute_nil dir
    assert dir.end_with?(".conduit")
  end

  # ================================================================
  # Constants
  # ================================================================

  def test_constants_accessible_from_module
    assert_equal "https://ca.datagrout.ai/ca.pem", DatagroutConduit::DG_CA_URL
    assert_equal "https://app.datagrout.ai/api/v1/substrate/identity",
                 DatagroutConduit::DG_SUBSTRATE_ENDPOINT
  end

  # ================================================================
  # bootstrap_identity
  # ================================================================

  def test_bootstrap_identity_uses_existing_identity
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "identity.pem"), REAL_CERT)
      File.write(File.join(dir, "identity_key.pem"), REAL_KEY)

      client = DatagroutConduit::Client.bootstrap_identity(
        url: SERVER_URL,
        auth_token: "test-token",
        identity_dir: dir
      )

      assert_kind_of DatagroutConduit::Client, client
    end
  end

  def test_bootstrap_identity_registers_new_identity
    Dir.mktmpdir do |dir|
      stub_request(:post, "#{SUBSTRATE_ENDPOINT}/register")
        .to_return(
          status: 201,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            "id" => "sub_new",
            "cert_pem" => REAL_CERT,
            "ca_cert_pem" => nil,
            "fingerprint" => "xyz789",
            "name" => "conduit-client",
            "registered_at" => "2026-03-01T00:00:00Z",
            "valid_until" => "2026-03-31T00:00:00Z"
          )
        )

      client = DatagroutConduit::Client.bootstrap_identity(
        url: SERVER_URL,
        auth_token: "test-token",
        name: "test-client",
        identity_dir: dir
      )

      assert_kind_of DatagroutConduit::Client, client
      assert File.exist?(File.join(dir, "identity.pem"))
      assert File.exist?(File.join(dir, "identity_key.pem"))
    end
  end

  # ================================================================
  # bootstrap_identity_oauth
  # ================================================================

  def test_bootstrap_identity_oauth_flow
    Dir.mktmpdir do |dir|
      stub_request(:post, TOKEN_ENDPOINT)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            "access_token" => "oauth_jwt_token",
            "token_type" => "bearer",
            "expires_in" => 3600
          )
        )

      stub_request(:post, "#{SUBSTRATE_ENDPOINT}/register")
        .with(headers: { "Authorization" => "Bearer oauth_jwt_token" })
        .to_return(
          status: 201,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            "id" => "sub_oauth",
            "cert_pem" => REAL_CERT,
            "ca_cert_pem" => nil,
            "fingerprint" => "oauth_fp",
            "name" => "conduit-client",
            "registered_at" => "2026-03-01T00:00:00Z",
            "valid_until" => "2026-03-31T00:00:00Z"
          )
        )

      client = DatagroutConduit::Client.bootstrap_identity_oauth(
        url: SERVER_URL,
        client_id: "my_id",
        client_secret: "my_secret",
        identity_dir: dir
      )

      assert_kind_of DatagroutConduit::Client, client
      assert File.exist?(File.join(dir, "identity.pem"))
      assert File.exist?(File.join(dir, "identity_key.pem"))
    end
  end

  def test_bootstrap_identity_oauth_propagates_auth_error
    stub_request(:post, TOKEN_ENDPOINT)
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: '{"error": "invalid_client"}'
      )

    Dir.mktmpdir do |dir|
      assert_raises(DatagroutConduit::AuthError) do
        DatagroutConduit::Client.bootstrap_identity_oauth(
          url: SERVER_URL,
          client_id: "bad_id",
          client_secret: "bad_secret",
          identity_dir: dir
        )
      end
    end
  end

  # ================================================================
  # RegistrationResponse struct
  # ================================================================

  def test_registration_response_struct
    resp = DatagroutConduit::RegistrationResponse.new(
      id: "sub_1",
      cert_pem: SAMPLE_CERT,
      ca_cert_pem: SAMPLE_CA,
      fingerprint: "fp_123",
      name: "test",
      registered_at: "2026-03-01T00:00:00Z",
      valid_until: "2026-03-31T00:00:00Z"
    )

    assert_equal "sub_1", resp.id
    assert_equal SAMPLE_CERT, resp.cert_pem
    assert_equal SAMPLE_CA, resp.ca_cert_pem
    assert_equal "fp_123", resp.fingerprint
    assert_equal "test", resp.name
    assert_equal "2026-03-01T00:00:00Z", resp.registered_at
    assert_equal "2026-03-31T00:00:00Z", resp.valid_until
  end
end
