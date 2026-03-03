# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class IdentityTest < Minitest::Test
  SAMPLE_CERT = <<~PEM
    -----BEGIN CERTIFICATE-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
    -----END CERTIFICATE-----
  PEM

  SAMPLE_KEY = <<~PEM
    -----BEGIN PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEA
    -----END PRIVATE KEY-----
  PEM

  def test_from_pem_validates_cert
    err = assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Identity.from_pem("not a cert", SAMPLE_KEY)
    end
    assert_includes err.message, "certificate"
  end

  def test_from_pem_validates_key
    err = assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Identity.from_pem(SAMPLE_CERT, "not a key")
    end
    assert_includes err.message, "private key"
  end

  def test_from_pem_accepts_valid_pems
    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, SAMPLE_KEY)
    assert_equal SAMPLE_CERT, id.cert_pem
    assert_equal SAMPLE_KEY, id.key_pem
    assert_nil id.ca_pem
  end

  def test_from_pem_with_ca
    ca_pem = SAMPLE_CERT
    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, SAMPLE_KEY, ca_pem: ca_pem)
    refute_nil id.ca_pem
  end

  def test_from_paths
    Dir.mktmpdir do |dir|
      cert_path = File.join(dir, "cert.pem")
      key_path = File.join(dir, "key.pem")
      File.write(cert_path, SAMPLE_CERT)
      File.write(key_path, SAMPLE_KEY)

      id = DatagroutConduit::Identity.from_paths(cert_path, key_path)
      assert_equal SAMPLE_CERT, id.cert_pem
    end
  end

  def test_from_paths_with_ca
    Dir.mktmpdir do |dir|
      cert_path = File.join(dir, "cert.pem")
      key_path = File.join(dir, "key.pem")
      ca_path = File.join(dir, "ca.pem")
      File.write(cert_path, SAMPLE_CERT)
      File.write(key_path, SAMPLE_KEY)
      File.write(ca_path, SAMPLE_CERT)

      id = DatagroutConduit::Identity.from_paths(cert_path, key_path, ca_path: ca_path)
      refute_nil id.ca_pem
    end
  end

  def test_from_paths_raises_on_missing_file
    assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Identity.from_paths("/nonexistent/cert.pem", "/nonexistent/key.pem")
    end
  end

  def test_from_env_returns_nil_when_unset
    ENV.delete("CONDUIT_MTLS_CERT")
    ENV.delete("CONDUIT_MTLS_KEY")
    assert_nil DatagroutConduit::Identity.from_env
  end

  def test_from_env_with_cert_and_key
    ENV["CONDUIT_MTLS_CERT"] = SAMPLE_CERT
    ENV["CONDUIT_MTLS_KEY"] = SAMPLE_KEY

    id = DatagroutConduit::Identity.from_env
    refute_nil id
    assert_equal SAMPLE_CERT, id.cert_pem
  ensure
    ENV.delete("CONDUIT_MTLS_CERT")
    ENV.delete("CONDUIT_MTLS_KEY")
  end

  def test_from_env_raises_when_cert_without_key
    ENV["CONDUIT_MTLS_CERT"] = SAMPLE_CERT
    ENV.delete("CONDUIT_MTLS_KEY")

    assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Identity.from_env
    end
  ensure
    ENV.delete("CONDUIT_MTLS_CERT")
  end

  def test_needs_rotation_false_when_no_expiry
    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, SAMPLE_KEY)
    refute id.needs_rotation?(threshold_days: 30)
  end

  def test_needs_rotation_true_when_expired
    id = DatagroutConduit::Identity.new(
      cert_pem: SAMPLE_CERT,
      key_pem: SAMPLE_KEY,
      expires_at: Time.now - 86_400
    )
    assert id.needs_rotation?(threshold_days: 0)
  end

  def test_needs_rotation_false_when_far_future
    id = DatagroutConduit::Identity.new(
      cert_pem: SAMPLE_CERT,
      key_pem: SAMPLE_KEY,
      expires_at: Time.now + (365 * 10 * 86_400)
    )
    refute id.needs_rotation?(threshold_days: 30)
  end

  def test_try_discover_from_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "identity.pem"), SAMPLE_CERT)
      File.write(File.join(dir, "identity_key.pem"), SAMPLE_KEY)

      id = DatagroutConduit::Identity.try_discover(override_dir: dir)
      refute_nil id
      assert_equal SAMPLE_CERT, id.cert_pem
    end
  end

  def test_try_discover_returns_nil_when_nothing_found
    Dir.mktmpdir do |dir|
      id = DatagroutConduit::Identity.try_discover(override_dir: dir)
      assert_nil id
    end
  end

  def test_try_discover_from_identity_dir_env
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "identity.pem"), SAMPLE_CERT)
      File.write(File.join(dir, "identity_key.pem"), SAMPLE_KEY)

      ENV["CONDUIT_IDENTITY_DIR"] = dir
      ENV.delete("CONDUIT_MTLS_CERT")
      ENV.delete("CONDUIT_MTLS_KEY")

      id = DatagroutConduit::Identity.try_discover
      refute_nil id
    end
  ensure
    ENV.delete("CONDUIT_IDENTITY_DIR")
  end

  def test_accepts_rsa_private_key
    rsa_key = <<~PEM
      -----BEGIN RSA PRIVATE KEY-----
      MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEA
      -----END RSA PRIVATE KEY-----
    PEM

    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, rsa_key)
    assert_equal rsa_key, id.key_pem
  end

  def test_accepts_ec_private_key
    ec_key = <<~PEM
      -----BEGIN EC PRIVATE KEY-----
      MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEA
      -----END EC PRIVATE KEY-----
    PEM

    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, ec_key)
    assert_equal ec_key, id.key_pem
  end

  def test_with_expiry_returns_new_identity
    id = DatagroutConduit::Identity.from_pem(SAMPLE_CERT, SAMPLE_KEY)
    assert_nil id.expires_at

    future = Time.now + (365 * 86_400)
    id2 = id.with_expiry(future)

    assert_nil id.expires_at
    assert_equal future, id2.expires_at
    assert_equal id.cert_pem, id2.cert_pem
    assert_equal id.key_pem, id2.key_pem
  end
end
