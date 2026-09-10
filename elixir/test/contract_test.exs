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
  alias DatagroutConduit.Delegation
  alias DatagroutConduit.Delegation.{Token, TokenType}

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

  describe "delegation (RFC 8693)" do
    @delegation @contract["delegation"]

    test "the grant type matches the contract" do
      assert Delegation.grant_type() == @delegation["grant_type"]
    end

    test "the token-type URNs match the contract" do
      urns = @delegation["token_types"]
      assert map_size(urns) == map_size(TokenType.urns())

      for {name, urn} <- urns do
        atom = String.to_existing_atom(name)
        assert TokenType.to_urn(atom) == urn, name
        assert TokenType.from_urn(urn) == atom, name
      end
    end

    test "the fixture request produces exactly the fixture form" do
      # The request fixture is what a port builds; `request_form` is the body it
      # must post, field for field and in order.
      r = @delegation["request"]

      request =
        Delegation.new(r["token_endpoint"], r["client_id"])
        |> Delegation.client_secret(r["client_secret"])
        |> Delegation.subject_token(
          r["subject_token"],
          TokenType.from_urn(r["subject_token_type"])
        )
        |> Delegation.actor_token(r["actor_token"], TokenType.from_urn(r["actor_token_type"]))
        |> Delegation.audience(r["audience"])
        |> Delegation.resource(r["resource"])
        |> Delegation.scope(r["scope"])
        |> Delegation.requested_token_type(TokenType.from_urn(r["requested_token_type"]))

      expected = Enum.map(@delegation["request_form"], fn [key, value] -> {key, value} end)

      assert Delegation.form_params(request) == {:ok, expected}
    end

    test "a delegated token written elsewhere loads field for field" do
      token = Token.from_map(@delegation["token"])

      assert token.access_token == "delegated_contract_fixture"
      assert token.issued_token_type == :access_token
      assert token.token_type == "Bearer"
      assert token.expires_at == 1_700_000_000
      assert token.scope == "mcp tools"
    end

    test "a delegated token written here is byte-identical to the contract" do
      expected = @delegation["token"]
      assert expected |> Token.from_map() |> Token.to_map() == expected
    end

    test "a minimal delegated token omits absent optionals rather than nulling them" do
      minimal = @delegation["token_minimal"]
      token = Token.from_map(minimal)

      assert token.expires_at == nil
      refute Token.expired?(token)
      assert Token.to_map(token) == minimal
    end

    test "the wire response converts expires_in into an absolute expires_at" do
      # Everything else copies across unchanged.
      wire = @delegation["wire_response"]
      expected = Token.from_map(@delegation["token"])

      before = System.os_time(:second)

      Req.Test.stub(Delegation, fn conn -> Req.Test.json(conn, wire) end)

      request =
        Delegation.new("https://gateway.example.com/oauth/token", "agent_client")
        |> Delegation.subject_token("user_at", :access_token)
        |> Delegation.actor_token("agent_at", :access_token)

      assert {:ok, token} = Delegation.exchange(request)

      assert token.access_token == expected.access_token
      assert token.issued_token_type == expected.issued_token_type
      assert token.token_type == expected.token_type
      assert token.scope == expected.scope
      assert token.expires_at >= before + wire["expires_in"]
      assert token.expires_at <= System.os_time(:second) + wire["expires_in"]
    end

    test "the delegation error taxonomy matches the contract" do
      # Hand-written for the same reason as the authorization-code list above:
      # Elixir models the taxonomy as atoms with no runtime registry.
      kinds =
        [
          Delegation.Error.missing_subject(),
          Delegation.Error.missing_actor(),
          Delegation.Error.http("x"),
          Delegation.Error.server(400, "invalid_request"),
          Delegation.Error.invalid_response("x")
        ]
        |> Enum.map(&Atom.to_string(&1.kind))
        |> Enum.sort()

      assert kinds == Enum.sort(@delegation["error_kinds"])
    end

    test "the server error codes match the contract" do
      assert Enum.sort(Delegation.server_error_codes()) ==
               Enum.sort(@delegation["server_error_codes"])
    end
  end
end
