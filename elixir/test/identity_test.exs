defmodule DatagroutConduit.IdentityTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.Identity

  describe "try_discover/1" do
    test "returns nil when no identity files exist" do
      result = Identity.try_discover(override_dir: "/nonexistent/path")
      assert result == nil
    end

    test "finds identity in override dir" do
      dir = create_temp_identity_dir()

      result = Identity.try_discover(override_dir: dir)
      assert %Identity{} = result
      assert result.cert_path =~ "identity.pem"
      assert result.key_path =~ "identity_key.pem"

      cleanup_temp_dir(dir)
    end

    test "finds CA cert if present" do
      dir = create_temp_identity_dir(with_ca: true)

      result = Identity.try_discover(override_dir: dir)
      assert %Identity{} = result
      assert result.ca_path =~ "ca.pem"

      cleanup_temp_dir(dir)
    end
  end

  describe "from_paths/3" do
    test "succeeds with valid paths" do
      dir = create_temp_identity_dir()
      cert = Path.join(dir, "identity.pem")
      key = Path.join(dir, "identity_key.pem")

      assert {:ok, %Identity{} = id} = Identity.from_paths(cert, key)
      assert id.cert_path == cert
      assert id.key_path == key
      assert id.ca_path == nil

      cleanup_temp_dir(dir)
    end

    test "fails with missing cert" do
      assert {:error, {:file_not_found, _}} = Identity.from_paths("/nonexistent/cert.pem", "/nonexistent/key.pem")
    end
  end

  describe "from_pem/3" do
    test "succeeds with valid PEM data" do
      {cert_pem, key_pem} = generate_test_pems()

      assert {:ok, %Identity{} = id} = Identity.from_pem(cert_pem, key_pem)
      assert id.cert_pem == cert_pem
      assert id.key_pem == key_pem
    end

    test "fails with invalid PEM data" do
      assert {:error, {:invalid_pem, "certificate"}} = Identity.from_pem("not-pem", "not-pem")
    end
  end

  describe "needs_rotation?/2" do
    test "returns true when no cert data available" do
      identity = %Identity{}
      assert Identity.needs_rotation?(identity)
    end

    test "accepts threshold_days option" do
      identity = %Identity{}
      assert Identity.needs_rotation?(identity, threshold_days: 90)
    end
  end

  # --- Test Helpers ---

  defp create_temp_identity_dir(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "conduit_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "identity.pem"), "placeholder-cert")
    File.write!(Path.join(dir, "identity_key.pem"), "placeholder-key")

    if opts[:with_ca] do
      File.write!(Path.join(dir, "ca.pem"), "placeholder-ca")
    end

    dir
  end

  defp cleanup_temp_dir(dir) do
    File.rm_rf!(dir)
  end

  defp generate_test_pems do
    dir = Path.join(System.tmp_dir!(), "conduit_pem_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "key.pem")
    cert_path = Path.join(dir, "cert.pem")

    {_, 0} = System.cmd("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key_path, "-out", cert_path,
      "-days", "365", "-subj", "/CN=conduit-test"
    ], stderr_to_stdout: true)

    cert_pem = File.read!(cert_path)
    key_pem = File.read!(key_path)

    File.rm_rf!(dir)

    {cert_pem, key_pem}
  end
end
