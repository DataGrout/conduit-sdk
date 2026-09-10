# frozen_string_literal: true

require_relative "test_helper"

# The delegation half of the cross-language contract.
#
# The other delegation tests round-trip through this SDK's own serializer, which
# passes even if a field name is wrong — as long as it is consistently wrong.
# These load testdata/contract.json, the same bytes every language checks, so a
# request built here is provably the one the other ports post.
#
# See testdata/README.md.
class DelegationContractTest < Minitest::Test
  D = DatagroutConduit::Delegation

  CONTRACT = JSON.parse(
    File.read(File.expand_path("../../testdata/contract.json", __dir__))
  ).fetch("delegation").freeze

  def test_the_grant_type_matches_the_contract
    assert_equal CONTRACT["grant_type"], D::GRANT_TYPE
  end

  def test_the_token_type_urns_match_the_contract
    urns = CONTRACT["token_types"]
    assert_equal urns.length, D::TokenType::NAMED.length

    urns.each do |name, urn|
      assert_equal urn, D::TokenType::NAMED.fetch(name.to_sym), name
      assert_equal name.to_sym, D::TokenType.from_urn(urn).name
    end
  end

  def test_the_fixture_request_produces_exactly_the_fixture_form
    # The request fixture is what a port builds; request_form is the body it
    # must post, field for field and in order.
    fixture = CONTRACT["request"]

    request = D::Request.new(
      token_endpoint: fixture["token_endpoint"],
      client_id: fixture["client_id"],
      client_secret: fixture["client_secret"],
      subject_token: fixture["subject_token"],
      subject_token_type: D::TokenType.from_urn(fixture["subject_token_type"]),
      actor_token: fixture["actor_token"],
      actor_token_type: D::TokenType.from_urn(fixture["actor_token_type"]),
      audience: fixture["audience"],
      resource: fixture["resource"],
      scope: fixture["scope"],
      requested_token_type: D::TokenType.from_urn(fixture["requested_token_type"])
    )

    assert_equal CONTRACT["request_form"], request.form_params
  end

  def test_the_fixture_token_loads_field_for_field
    # Read explicitly rather than by round-trip: a misnamed field would leave
    # the attribute nil, and a round-trip alone would not notice.
    token = D::Token.from_h(CONTRACT["token"])

    assert_equal "delegated_contract_fixture", token.access_token
    assert_equal D::TokenType::ACCESS_TOKEN, token.issued_token_type
    assert_equal "Bearer", token.token_type
    assert_equal 1_700_000_000, token.expires_at
    assert_equal "mcp tools", token.scope
  end

  def test_a_token_written_here_is_identical_to_the_contract
    assert_equal CONTRACT["token"], D::Token.from_h(CONTRACT["token"]).to_h
  end

  def test_a_minimal_token_omits_absent_optionals_rather_than_nulling_them
    minimal = CONTRACT["token_minimal"]
    token = D::Token.from_h(minimal)

    assert_nil token.expires_at
    refute_predicate token, :expired?
    assert_equal minimal, token.to_h
  end

  def test_the_fixture_wire_response_parses_to_the_fixture_token
    # The server's relative expires_in becomes an absolute expires_at, in Unix
    # seconds. Everything else copies across unchanged.
    expected = D::Token.from_h(CONTRACT["token"])

    before = Time.now.to_i
    parsed = D::Token.from_wire(CONTRACT["wire_response"])
    after = Time.now.to_i

    assert_equal expected.access_token, parsed.access_token
    assert_equal expected.issued_token_type, parsed.issued_token_type
    assert_equal expected.token_type, parsed.token_type
    assert_equal expected.scope, parsed.scope
    assert_operator parsed.expires_at, :>=, before + 900
    assert_operator parsed.expires_at, :<=, after + 900
  end

  def test_the_error_taxonomy_matches_the_contract
    # Ruby models the taxonomy as classes with no runtime registry, so this
    # list is hand-written: it catches a renamed kind, not an added one.
    kinds = [
      D::MissingSubjectError.new,
      D::MissingActorError.new,
      D::HttpError.new("x"),
      D::ServerError.new(status: 400, error: ""),
      D::InvalidResponseError.new("x")
    ].map { |error| error.kind.to_s }

    assert_equal CONTRACT["error_kinds"].sort, kinds.sort
  end

  def test_the_server_error_codes_match_the_contract
    assert_equal CONTRACT["server_error_codes"].sort, D::Codes::ALL.sort
  end
end
