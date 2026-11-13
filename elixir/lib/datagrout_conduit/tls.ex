defmodule DatagroutConduit.TLS do
  @moduledoc false

  # The client side of an mTLS identity as `:ssl` options, shared by every
  # transport: WebSockex's `:ssl_options` and Finch/Mint's `transport_opts`.
  #
  # Trust is the public roots plus the identity's CA. `:cacerts` and
  # `:cacertfile` each *replace* the default store, so naming the identity's CA
  # alone stops every publicly-issued server certificate from verifying — and a
  # DataGrout-issued identity carries the DataGrout CA while the gateway itself
  # presents a public certificate. Rust's `build_connector` is the reference:
  # webpki roots plus the identity's CA. The public roots here are CAStore's
  # bundle, which is what Mint verifies against when no trust store is named.

  alias DatagroutConduit.Identity

  @doc false
  @spec identity_opts(Identity.t() | nil) :: keyword()
  def identity_opts(%Identity{} = identity), do: client_cert(identity) ++ trust(identity)
  def identity_opts(_no_identity), do: []

  # PEM material wins over a path; a struct only ever carries one of the two.
  defp client_cert(identity) do
    cert =
      case certificates(identity.cert_pem) do
        [der] -> [cert: der]
        [_ | _] = chain -> [cert: chain]
        [] -> path_opt(:certfile, identity.cert_path)
      end

    key =
      case private_key(identity.key_pem) do
        nil -> path_opt(:keyfile, identity.key_path)
        key -> [key: key]
      end

    cert ++ key
  end

  # No identity CA means no trust option at all, leaving each transport on its
  # default store (CAStore for both Mint and, explicitly, the WS connection).
  defp trust(identity) do
    case identity_cas(identity) do
      [] -> []
      cas -> [cacerts: public_roots() ++ cas]
    end
  end

  defp identity_cas(%{ca_pem: pem}) when is_binary(pem), do: certificates(pem)
  defp identity_cas(%{ca_path: path}) when is_binary(path), do: certificates(File.read!(path))
  defp identity_cas(_identity), do: []

  defp public_roots do
    case :persistent_term.get({__MODULE__, :public_roots}, nil) do
      nil ->
        roots = certificates(File.read!(CAStore.file_path()))
        :persistent_term.put({__MODULE__, :public_roots}, roots)
        roots

      roots ->
        roots
    end
  end

  defp certificates(pem) when is_binary(pem) do
    for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
  end

  defp certificates(_none), do: []

  defp private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, :not_encrypted} | _] -> {type, der}
      _ -> nil
    end
  end

  defp private_key(_none), do: nil

  defp path_opt(_key, nil), do: []
  defp path_opt(key, path), do: [{key, path}]
end
