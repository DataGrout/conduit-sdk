defmodule DatagroutConduit.BootstrapTest do
  use ExUnit.Case, async: true

  alias DatagroutConduit.{Client, Registration}

  describe "bootstrap_identity/1" do
    test "uses existing identity when found and not near expiry" do
      dir = create_identity_dir_with_valid_cert()

      {:ok, client} =
        Client.bootstrap_identity(
          url: "https://example.com/mcp",
          identity_dir: dir,
          threshold_days: 0
        )

      assert is_pid(client)
      state = :sys.get_state(client)
      assert state.identity != nil

      GenServer.stop(client)
      File.rm_rf!(dir)
    end

    test "returns error when no auth_token and no existing identity" do
      dir = Path.join(System.tmp_dir!(), "conduit_bootstrap_empty_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      result =
        Client.bootstrap_identity(
          url: "https://example.com/mcp",
          identity_dir: dir,
          threshold_days: 0
        )

      assert {:error, :auth_token_required} = result

      File.rm_rf!(dir)
    end
  end

  describe "do_register (internal, via bootstrap)" do
    test "generate_keypair produces valid keys for registration" do
      {:ok, {priv, pub}} = Registration.generate_keypair()
      assert is_binary(priv)
      assert is_binary(pub)
      assert String.contains?(priv, "BEGIN EC PRIVATE KEY")
      assert String.contains?(pub, "BEGIN PUBLIC KEY")
    end
  end

  describe "constants accessible from main module" do
    test "dg_ca_url" do
      assert DatagroutConduit.dg_ca_url() == "https://ca.datagrout.ai/ca.pem"
    end

    test "dg_substrate_endpoint" do
      assert DatagroutConduit.dg_substrate_endpoint() ==
               "https://app.datagrout.ai/api/v1/substrate/identity"
    end
  end

  defp create_identity_dir_with_valid_cert do
    dir = Path.join(System.tmp_dir!(), "conduit_bootstrap_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)

    key_path = Path.join(dir, "identity_key.pem")
    cert_path = Path.join(dir, "identity.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req", "-x509", "-newkey", "ec",
          "-pkeyopt", "ec_paramgen_curve:prime256v1",
          "-nodes",
          "-keyout", key_path,
          "-out", cert_path,
          "-days", "365",
          "-subj", "/CN=conduit-test"
        ],
        stderr_to_stdout: true
      )

    dir
  end
end
