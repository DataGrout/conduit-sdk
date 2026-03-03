defmodule DatagroutConduit.Registration do
  @moduledoc """
  Substrate identity registration with the DataGrout CA.

  Handles the issuance flow — turning a freshly-generated key-pair into a
  DG-CA-signed identity that DataGrout will accept for mTLS.

  ## Flow

  1. Generate an ECDSA P-256 keypair with `generate_keypair/0`.
  2. Send the **public key** to the DataGrout CA via `register_identity/2`
     (authenticated with a bearer token or API key).
  3. Persist the returned identity via `save_identity/4`.
  4. On renewal, call `rotate_identity/3` which presents the existing client
     certificate over mTLS — no API key needed.
  """

  alias DatagroutConduit.Identity

  @dg_ca_url "https://ca.datagrout.ai/ca.pem"
  @dg_substrate_endpoint "https://app.datagrout.ai/api/v1/substrate/identity"

  @doc "Returns the canonical URL for the DataGrout CA certificate."
  @spec dg_ca_url() :: String.t()
  def dg_ca_url, do: @dg_ca_url

  @doc "Returns the default endpoint for Substrate identity registration."
  @spec dg_substrate_endpoint() :: String.t()
  def dg_substrate_endpoint, do: @dg_substrate_endpoint

  defmodule RegistrationResponse do
    @moduledoc "Response from `POST /register` or `/rotate`."
    @type t :: %__MODULE__{
            id: String.t() | nil,
            cert_pem: String.t() | nil,
            ca_cert_pem: String.t() | nil,
            fingerprint: String.t() | nil,
            name: String.t() | nil,
            registered_at: String.t() | nil,
            valid_until: String.t() | nil
          }
    defstruct [:id, :cert_pem, :ca_cert_pem, :fingerprint, :name, :registered_at, :valid_until]
  end

  @doc """
  Generate an ECDSA P-256 keypair.

  Returns `{:ok, {private_key_pem, public_key_pem}}` where both are
  PEM-encoded binaries. The private key never leaves the client.
  """
  @spec generate_keypair() :: {:ok, {binary(), binary()}}
  def generate_keypair do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})

    private_der = :public_key.der_encode(:ECPrivateKey, ec_key)
    private_pem = :public_key.pem_encode([{:ECPrivateKey, private_der, :not_encrypted}])

    pub_point = elem(ec_key, 4)
    public_der = ec_p256_spki_der(pub_point)
    public_pem = :public_key.pem_encode([{:SubjectPublicKeyInfo, public_der, :not_encrypted}])

    {:ok, {private_pem, public_pem}}
  end

  # SubjectPublicKeyInfo DER for EC P-256 is a fixed-layout structure:
  #   SEQUENCE { SEQUENCE { OID(id-ecPublicKey), OID(prime256v1) }, BIT STRING(point) }
  # The header is always 26 bytes for an uncompressed 65-byte EC point.
  @ec_p256_spki_prefix <<0x30, 0x59, 0x30, 0x13,
    0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
    0x03, 0x42, 0x00>>

  defp ec_p256_spki_der(<<0x04, _::binary-size(64)>> = point) do
    @ec_p256_spki_prefix <> point
  end

  @doc """
  Register identity with the DataGrout CA.

  Sends the public key to the registration endpoint, authenticated with a
  bearer token. Returns `{:ok, %RegistrationResponse{}}` on success.

  ## Options

    * `:auth_token` - Bearer token for authentication (required)
    * `:name` - Human-readable label (default: `"conduit-client"`)
    * `:endpoint` - Registration endpoint URL (default: `dg_substrate_endpoint()`)
  """
  @spec register_identity(binary(), keyword()) :: {:ok, RegistrationResponse.t()} | {:error, term()}
  def register_identity(public_key_pem, opts) do
    auth_token = Keyword.fetch!(opts, :auth_token)
    name = Keyword.get(opts, :name, "conduit-client")
    endpoint = Keyword.get(opts, :endpoint, @dg_substrate_endpoint)

    url = String.trim_trailing(endpoint, "/") <> "/register"

    payload = %{
      "public_key_pem" => Base.encode64(public_key_pem),
      "name" => name
    }

    case Req.post(url,
           json: payload,
           headers: [
             {"authorization", "Bearer #{auth_token}"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, parse_registration_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:registration_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  Rotate identity using existing mTLS cert.

  Authenticates with the existing identity's client certificate instead
  of a bearer token. Generates a fresh registration with the new public key.

  ## Options

    * `:name` - Human-readable label (default: `"conduit-client"`)
    * `:endpoint` - Registration endpoint URL (default: `dg_substrate_endpoint()`)
  """
  @spec rotate_identity(binary(), Identity.t(), keyword()) :: {:ok, RegistrationResponse.t()} | {:error, term()}
  def rotate_identity(public_key_pem, %Identity{} = identity, opts \\ []) do
    name = Keyword.get(opts, :name, "conduit-client")
    endpoint = Keyword.get(opts, :endpoint, @dg_substrate_endpoint)

    url = String.trim_trailing(endpoint, "/") <> "/rotate"

    payload = %{
      "public_key_pem" => Base.encode64(public_key_pem),
      "name" => name
    }

    connect_options = build_mtls_connect_options(identity)

    case Req.post(url,
           json: payload,
           headers: [{"content-type", "application/json"}],
           connect_options: connect_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, parse_registration_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:rotation_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  Save identity files to a directory.

  Writes `cert.pem`, `key.pem`, and `ca.pem` to `dir`. Sets file permissions
  to 0o600 on the key file. Creates `dir` if it does not exist.

  Returns `{:ok, %{cert: path, key: path, ca: path}}`.
  """
  @spec save_identity(binary(), binary(), binary() | nil, String.t()) ::
          {:ok, %{cert: String.t(), key: String.t(), ca: String.t() | nil}} | {:error, term()}
  def save_identity(cert_pem, key_pem, ca_pem, dir) do
    dir = Path.expand(dir)

    with :ok <- File.mkdir_p(dir) do
      cert_path = Path.join(dir, "cert.pem")
      key_path = Path.join(dir, "key.pem")

      File.write!(cert_path, cert_pem)
      File.write!(key_path, key_pem)
      File.chmod!(key_path, 0o600)

      ca_path =
        if ca_pem do
          p = Path.join(dir, "ca.pem")
          File.write!(p, ca_pem)
          p
        end

      {:ok, %{cert: cert_path, key: key_path, ca: ca_path}}
    end
  rescue
    e -> {:error, {:save_failed, Exception.message(e)}}
  end

  @doc """
  Fetch the DG CA certificate from `ca.datagrout.ai`.

  Returns `{:ok, pem_string}` on success.
  """
  @spec fetch_ca_cert(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def fetch_ca_cert(url \\ nil) do
    url = url || @dg_ca_url

    case Req.get(url, headers: [{"accept", "application/x-pem-file, text/plain, */*"}]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if String.contains?(body, "-----BEGIN CERTIFICATE-----") do
          {:ok, body}
        else
          {:error, {:invalid_ca_cert, "response does not look like a PEM certificate"}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:ca_fetch_failed, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  Refresh the local CA cert from the DG CA endpoint.

  Fetches the CA cert and writes it to `ca.pem` in the given directory.
  """
  @spec refresh_ca_cert(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def refresh_ca_cert(dir, ca_url \\ nil) do
    with {:ok, pem} <- fetch_ca_cert(ca_url) do
      dir = Path.expand(dir)
      File.mkdir_p!(dir)
      path = Path.join(dir, "ca.pem")
      File.write!(path, pem)
      {:ok, path}
    end
  rescue
    e -> {:error, {:refresh_failed, Exception.message(e)}}
  end

  @doc """
  Returns `~/.conduit/` as the canonical identity directory.
  """
  @spec default_identity_dir() :: String.t() | nil
  def default_identity_dir do
    case System.user_home() do
      nil -> nil
      home -> Path.join(home, ".conduit")
    end
  end

  # --- Internal ---

  defp parse_registration_response(body) when is_map(body) do
    %RegistrationResponse{
      id: body["id"],
      cert_pem: body["cert_pem"],
      ca_cert_pem: body["ca_cert_pem"],
      fingerprint: body["fingerprint"],
      name: body["name"],
      registered_at: body["registered_at"],
      valid_until: body["valid_until"]
    }
  end

  defp parse_registration_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_registration_response(decoded)
      _ -> %RegistrationResponse{}
    end
  end

  defp parse_registration_response(_), do: %RegistrationResponse{}

  defp build_mtls_connect_options(%Identity{} = identity) do
    ssl_opts =
      []
      |> maybe_add(:certfile, identity.cert_path)
      |> maybe_add(:keyfile, identity.key_path)
      |> maybe_add(:cacertfile, identity.ca_path)
      |> maybe_add_pem(:cert, identity.cert_pem)
      |> maybe_add_pem(:key, identity.key_pem)
      |> maybe_add_pem(:cacerts, identity.ca_pem)

    [transport_opts: ssl_opts]
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_pem(opts, _key, nil), do: opts

  defp maybe_add_pem(opts, :cert, pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] -> Keyword.put(opts, :cert, [{:Certificate, der}])
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :key, pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, _} | _] -> Keyword.put(opts, :key, {type, der})
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :cacerts, pem) do
    certs =
      :public_key.pem_decode(pem)
      |> Enum.filter(fn {type, _, _} -> type == :Certificate end)
      |> Enum.map(fn {:Certificate, der, _} -> der end)

    if certs != [], do: Keyword.put(opts, :cacerts, certs), else: opts
  end
end
