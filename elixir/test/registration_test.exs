defmodule DatagroutConduit.RegistrationTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.Registration
  alias DatagroutConduit.Registration.RegistrationResponse

  describe "generate_keypair/0" do
    test "returns {:ok, {private_pem, public_pem}}" do
      assert {:ok, {private_pem, public_pem}} = Registration.generate_keypair()
      assert is_binary(private_pem)
      assert is_binary(public_pem)
    end

    test "private key is valid PEM" do
      {:ok, {private_pem, _}} = Registration.generate_keypair()
      assert String.contains?(private_pem, "-----BEGIN EC PRIVATE KEY-----")
      assert String.contains?(private_pem, "-----END EC PRIVATE KEY-----")

      entries = :public_key.pem_decode(private_pem)
      assert length(entries) == 1
      {type, _der, _} = hd(entries)
      assert type == :ECPrivateKey
    end

    test "public key is valid PEM" do
      {:ok, {_, public_pem}} = Registration.generate_keypair()
      assert String.contains?(public_pem, "-----BEGIN PUBLIC KEY-----")
      assert String.contains?(public_pem, "-----END PUBLIC KEY-----")

      entries = :public_key.pem_decode(public_pem)
      assert length(entries) == 1
      {type, _der, _} = hd(entries)
      assert type == :SubjectPublicKeyInfo
    end

    test "generates unique keypairs each time" do
      {:ok, {priv1, pub1}} = Registration.generate_keypair()
      {:ok, {priv2, pub2}} = Registration.generate_keypair()

      refute priv1 == priv2
      refute pub1 == pub2
    end
  end

  describe "save_identity/4" do
    test "writes cert, key, and ca files to directory" do
      dir = temp_dir()

      {:ok, {private_pem, _}} = Registration.generate_keypair()
      cert_pem = "-----BEGIN CERTIFICATE-----\nfake-cert\n-----END CERTIFICATE-----\n"
      ca_pem = "-----BEGIN CERTIFICATE-----\nfake-ca\n-----END CERTIFICATE-----\n"

      assert {:ok, paths} = Registration.save_identity(cert_pem, private_pem, ca_pem, dir)

      assert File.exists?(paths.cert)
      assert File.exists?(paths.key)
      assert File.exists?(paths.ca)

      assert File.read!(paths.cert) == cert_pem
      assert File.read!(paths.key) == private_pem
      assert File.read!(paths.ca) == ca_pem

      File.rm_rf!(dir)
    end

    test "sets key file permissions to 0o600" do
      dir = temp_dir()

      {:ok, {private_pem, _}} = Registration.generate_keypair()
      cert_pem = "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"

      {:ok, paths} = Registration.save_identity(cert_pem, private_pem, nil, dir)

      {:ok, stat} = File.stat(paths.key)
      assert stat.access == :read_write

      File.rm_rf!(dir)
    end

    test "creates directory if it does not exist" do
      dir = Path.join(System.tmp_dir!(), "conduit_reg_test_nested_#{:rand.uniform(100_000)}/sub/dir")
      refute File.exists?(dir)

      {:ok, {private_pem, _}} = Registration.generate_keypair()
      cert_pem = "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"

      assert {:ok, _} = Registration.save_identity(cert_pem, private_pem, nil, dir)
      assert File.exists?(dir)

      File.rm_rf!(Path.join(System.tmp_dir!(), "conduit_reg_test_nested_#{:rand.uniform(100_000)}"))
      File.rm_rf!(dir)
    end

    test "handles nil ca_pem" do
      dir = temp_dir()

      {:ok, {private_pem, _}} = Registration.generate_keypair()
      cert_pem = "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"

      assert {:ok, paths} = Registration.save_identity(cert_pem, private_pem, nil, dir)
      assert paths.ca == nil
      refute File.exists?(Path.join(dir, "ca.pem"))

      File.rm_rf!(dir)
    end
  end

  describe "constants" do
    test "dg_ca_url/0 returns expected URL" do
      assert Registration.dg_ca_url() == "https://ca.datagrout.ai/ca.pem"
    end

    test "dg_substrate_endpoint/0 returns expected URL" do
      assert Registration.dg_substrate_endpoint() == "https://app.datagrout.ai/api/v1/substrate/identity"
    end
  end

  describe "default_identity_dir/0" do
    test "returns a path under home directory" do
      dir = Registration.default_identity_dir()
      assert is_binary(dir)
      assert String.ends_with?(dir, "/.conduit")
    end
  end

  describe "RegistrationResponse struct" do
    test "has all expected fields" do
      resp = %RegistrationResponse{
        id: "sub-123",
        cert_pem: "cert",
        ca_cert_pem: "ca",
        fingerprint: "abc",
        name: "test",
        registered_at: "2026-01-01T00:00:00Z",
        valid_until: "2026-02-01T00:00:00Z"
      }

      assert resp.id == "sub-123"
      assert resp.cert_pem == "cert"
      assert resp.ca_cert_pem == "ca"
      assert resp.fingerprint == "abc"
      assert resp.name == "test"
    end
  end

  defp temp_dir do
    dir = Path.join(System.tmp_dir!(), "conduit_reg_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    dir
  end
end
