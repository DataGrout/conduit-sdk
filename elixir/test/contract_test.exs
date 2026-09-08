defmodule DatagroutConduit.ContractTest do
  @moduledoc """
  The cross-language contract, checked against the shared fixture.

  Every other test in this suite round-trips a grant through this SDK's own
  serializer, which passes even if a field name is wrong — as long as it is
  consistently wrong. These load `testdata/contract.json`, the same bytes every
  language checks, so a grant written here is provably readable elsewhere.

  See `testdata/README.md`.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.AuthCode
  alias DatagroutConduit.AuthCode.{Error, Grant, RegisteredClient}

  @contract __DIR__
            |> Path.join("../../testdata/contract.json")
            |> Path.expand()
            |> File.read!()
            |> Jason.decode!()

  test "a grant written elsewhere loads field for field" do
    # Read explicitly rather than by round-trip: a misnamed field would leave
    # the key nil, and a round-trip alone would not notice.
    grant = Grant.from_map(@contract["grant"])

    assert grant.access_token == "at_contract_fixture"
    assert grant.refresh_token == "rt_contract_fixture"
    assert grant.expires_at == 1_700_000_000
    assert grant.client_id == "client_contract_fixture"
    assert grant.token_endpoint == "https://gateway.example.com/oauth/token"
    assert grant.scope == "mcp tools"
    assert grant.resource == "https://gateway.example.com/connect"
  end

  test "a grant written here is byte-identical to the contract" do
    assert @contract["grant"] |> Grant.from_map() |> Grant.to_map() == @contract["grant"]
  end

  test "a minimal grant omits absent optionals rather than nulling them" do
    minimal = @contract["grant_minimal"]
    assert minimal |> Grant.from_map() |> Grant.to_map() == minimal
  end

  test "a registered client round-trips as one unit" do
    client = @contract["registered_client"]
    assert client |> RegisteredClient.from_map() |> RegisteredClient.to_map() == client
  end

  test "the default scope matches the contract" do
    assert AuthCode.default_scope() == @contract["default_scope"]
  end

  test "the error taxonomy matches the contract" do
    # Elixir models the taxonomy as atoms with no runtime registry, so this
    # list is hand-written: it catches a renamed kind, not an added one.
    # Python and TypeScript enumerate theirs and cover the rest.
    kinds =
      [
        Error.discovery("x"),
        Error.no_registration_endpoint(),
        Error.registration_rejected(1, ""),
        Error.no_client_id(),
        Error.pkce_unsupported(),
        Error.state_mismatch(),
        Error.token_exchange(1, ""),
        Error.not_refreshable(),
        Error.denied("access_denied"),
        Error.http("x")
      ]
      |> Enum.map(&Atom.to_string(&1.kind))
      |> Enum.sort()

    assert kinds == Enum.sort(@contract["error_kinds"])
  end
end
