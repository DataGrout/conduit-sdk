# frozen_string_literal: true

require_relative "test_helper"

# The cross-language contract, checked against the shared fixture.
#
# Every other test in this suite round-trips a grant through this SDK's own
# serializer, which passes even if a field name is wrong — as long as it is
# consistently wrong. These load testdata/contract.json, the same bytes every
# language checks, so a grant written here is provably readable elsewhere.
#
# See testdata/README.md.
class ContractTest < Minitest::Test
  AC = DatagroutConduit::AuthCode

  CONTRACT = JSON.parse(
    File.read(File.expand_path("../../testdata/contract.json", __dir__))
  ).freeze

  def test_a_grant_written_elsewhere_loads_field_for_field
    # Read explicitly rather than by round-trip: a misnamed field would leave
    # the attribute nil, and a round-trip alone would not notice.
    grant = AC::Grant.from_h(CONTRACT["grant"])

    assert_equal "at_contract_fixture", grant.access_token
    assert_equal "rt_contract_fixture", grant.refresh_token
    assert_equal 1_700_000_000, grant.expires_at
    assert_equal "client_contract_fixture", grant.client_id
    assert_equal "https://gateway.example.com/oauth/token", grant.token_endpoint
    assert_equal "mcp tools", grant.scope
    assert_equal "https://gateway.example.com/connect", grant.resource
  end

  def test_a_grant_written_here_is_byte_identical_to_the_contract
    assert_equal CONTRACT["grant"], AC::Grant.from_h(CONTRACT["grant"]).to_h
  end

  def test_a_minimal_grant_omits_absent_optionals_rather_than_nulling_them
    minimal = CONTRACT["grant_minimal"]
    assert_equal minimal, AC::Grant.from_h(minimal).to_h
  end

  def test_a_registered_client_round_trips_as_one_unit
    client = CONTRACT["registered_client"]
    assert_equal client, AC::RegisteredClient.from_h(client).to_h
  end

  def test_the_default_scope_matches_the_contract
    assert_equal CONTRACT["default_scope"], AC::DEFAULT_SCOPE
  end

  def test_the_error_taxonomy_matches_the_contract
    # Ruby models the taxonomy as classes with no runtime registry, so this
    # list is hand-written: it catches a renamed kind, not an added one.
    # Python and TypeScript enumerate theirs and cover the rest.
    kinds = [
      AC::DiscoveryError.new("x"),
      AC::NoRegistrationEndpointError.new,
      AC::RegistrationRejectedError.new(status: 1, body: ""),
      AC::NoClientIdError.new,
      AC::PkceUnsupportedError.new,
      AC::StateMismatchError.new,
      AC::TokenExchangeError.new(status: 1, body: ""),
      AC::NotRefreshableError.new,
      AC::DeniedError.new(error: "access_denied"),
      AC::HttpError.new("x")
    ].map { |e| e.kind.to_s }

    assert_equal CONTRACT["error_kinds"].sort, kinds.sort
  end
end
