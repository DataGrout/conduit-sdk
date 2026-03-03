defmodule DatagroutConduit.Identity do
  @moduledoc """
  mTLS client identity for mutual TLS authentication.

  Discovers client certificates from the filesystem or environment variables
  and provides them to the transport layer for HTTPS connections.

  ## Discovery Order

  `try_discover/1` searches in this order:

  1. `override_dir` option (if provided)
  2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables
  3. `CONDUIT_IDENTITY_DIR` environment variable
  4. `~/.conduit/identity.pem` + `identity_key.pem`
  5. `.conduit/` relative to current working directory
  """

  @type t :: %__MODULE__{
          cert_path: String.t() | nil,
          key_path: String.t() | nil,
          ca_path: String.t() | nil,
          cert_pem: binary() | nil,
          key_pem: binary() | nil,
          ca_pem: binary() | nil
        }

  defstruct [:cert_path, :key_path, :ca_path, :cert_pem, :key_pem, :ca_pem]

  @cert_filenames ["identity.pem", "cert.pem", "client.pem"]
  @key_filenames ["identity_key.pem", "key.pem", "client_key.pem"]
  @ca_filenames ["ca.pem", "ca_cert.pem"]

  @doc """
  Attempts to discover mTLS identity from the filesystem and environment.

  Returns `%Identity{}` if found, `nil` otherwise.

  ## Options

    * `:override_dir` - directory to search first (highest priority)
  """
  @spec try_discover(keyword()) :: t() | nil
  def try_discover(opts \\ []) do
    override_dir = opts[:override_dir]

    with nil <- from_override_dir(override_dir),
         nil <- from_env_paths(),
         nil <- from_env_dir(),
         nil <- from_home_dir(),
         nil <- from_cwd() do
      nil
    end
  end

  @doc """
  Creates an identity from explicit file paths.
  """
  @spec from_paths(String.t(), String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def from_paths(cert_path, key_path, ca_path \\ nil) do
    with :ok <- check_file(cert_path),
         :ok <- check_file(key_path),
         :ok <- if(ca_path, do: check_file(ca_path), else: :ok) do
      {:ok,
       %__MODULE__{
         cert_path: Path.expand(cert_path),
         key_path: Path.expand(key_path),
         ca_path: if(ca_path, do: Path.expand(ca_path))
       }}
    end
  end

  @doc """
  Creates an identity from PEM-encoded binaries.
  """
  @spec from_pem(binary(), binary(), binary() | nil) :: {:ok, t()} | {:error, term()}
  def from_pem(cert_pem, key_pem, ca_pem \\ nil) do
    with :ok <- validate_pem(cert_pem, "certificate"),
         :ok <- validate_pem(key_pem, "key") do
      {:ok,
       %__MODULE__{
         cert_pem: cert_pem,
         key_pem: key_pem,
         ca_pem: ca_pem
       }}
    end
  end

  @doc """
  Creates an identity from `CONDUIT_MTLS_CERT` and `CONDUIT_MTLS_KEY`
  environment variables containing PEM data directly.
  """
  @spec from_env() :: {:ok, t()} | {:error, :not_found}
  def from_env do
    cert_pem = System.get_env("CONDUIT_MTLS_CERT")
    key_pem = System.get_env("CONDUIT_MTLS_KEY")

    if cert_pem && key_pem do
      ca_pem = System.get_env("CONDUIT_MTLS_CA")
      from_pem(cert_pem, key_pem, ca_pem)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns `true` if the identity's certificate will expire within the given threshold.

  ## Options

    * `:threshold_days` - number of days before expiry to trigger (default: 30)
  """
  @spec needs_rotation?(t(), keyword()) :: boolean()
  def needs_rotation?(%__MODULE__{} = identity, opts \\ []) do
    threshold_days = opts[:threshold_days] || 30

    pem_data =
      cond do
        identity.cert_pem ->
          identity.cert_pem

        identity.cert_path && File.exists?(identity.cert_path) ->
          File.read!(identity.cert_path)

        true ->
          nil
      end

    case pem_data do
      nil ->
        true

      pem ->
        case extract_not_after(pem) do
          {:ok, not_after} ->
            threshold_secs = threshold_days * 86_400
            now = :os.system_time(:second)
            not_after - now < threshold_secs

          :error ->
            true
        end
    end
  end

  # --- Discovery strategies ---

  defp from_override_dir(nil), do: nil

  defp from_override_dir(dir) do
    find_in_dir(Path.expand(dir))
  end

  defp from_env_paths do
    cert = System.get_env("CONDUIT_MTLS_CERT")
    key = System.get_env("CONDUIT_MTLS_KEY")

    if cert && key && File.exists?(cert) && File.exists?(key) do
      ca = System.get_env("CONDUIT_MTLS_CA")

      %__MODULE__{
        cert_path: Path.expand(cert),
        key_path: Path.expand(key),
        ca_path: if(ca && File.exists?(ca), do: Path.expand(ca))
      }
    end
  end

  defp from_env_dir do
    case System.get_env("CONDUIT_IDENTITY_DIR") do
      nil -> nil
      dir -> find_in_dir(Path.expand(dir))
    end
  end

  defp from_home_dir do
    home = System.user_home()

    if home do
      find_in_dir(Path.join(home, ".conduit"))
    end
  end

  defp from_cwd do
    case File.cwd() do
      {:ok, cwd} -> find_in_dir(Path.join(cwd, ".conduit"))
      _ -> nil
    end
  end

  defp find_in_dir(dir) do
    cert_path = find_file(dir, @cert_filenames)
    key_path = find_file(dir, @key_filenames)

    if cert_path && key_path do
      ca_path = find_file(dir, @ca_filenames)

      %__MODULE__{
        cert_path: cert_path,
        key_path: key_path,
        ca_path: ca_path
      }
    end
  end

  defp find_file(dir, candidates) do
    Enum.find_value(candidates, fn name ->
      path = Path.join(dir, name)
      if File.exists?(path), do: path
    end)
  end

  defp check_file(path) do
    if File.exists?(path), do: :ok, else: {:error, {:file_not_found, path}}
  end

  defp validate_pem(data, label) when is_binary(data) do
    case :public_key.pem_decode(data) do
      [] -> {:error, {:invalid_pem, label}}
      _ -> :ok
    end
  end

  defp validate_pem(_, label), do: {:error, {:invalid_pem, label}}

  defp extract_not_after(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        try do
          cert = :public_key.pkix_decode_cert(der, :otp)

          {:OTPCertificate, {:OTPTBSCertificate, _, _, _, _, {:Validity, _, not_after}, _, _, _, _, _}, _, _} = cert

          secs =
            case not_after do
              {:utcTime, time_charlist} ->
                parse_utc_time(to_string(time_charlist))

              {:generalTime, time_charlist} ->
                parse_general_time(to_string(time_charlist))
            end

          {:ok, secs}
        rescue
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_utc_time(<<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), mi::binary-size(2), ss::binary-size(2), "Z">>) do
    year = String.to_integer(yy)
    year = if year >= 50, do: 1900 + year, else: 2000 + year

    NaiveDateTime.new!(
      year,
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(mi),
      String.to_integer(ss)
    )
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  defp parse_general_time(<<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), mi::binary-size(2), ss::binary-size(2), "Z">>) do
    NaiveDateTime.new!(
      String.to_integer(yyyy),
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(mi),
      String.to_integer(ss)
    )
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end
end
