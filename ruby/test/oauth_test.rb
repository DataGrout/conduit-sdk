# frozen_string_literal: true

require_relative "test_helper"

class OAuthTest < Minitest::Test
  TOKEN_ENDPOINT = "https://app.datagrout.ai/servers/abc/oauth/token"

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def test_derive_token_endpoint_from_mcp_url
    url = "https://app.datagrout.ai/servers/abc/mcp"
    expected = "https://app.datagrout.ai/servers/abc/oauth/token"
    assert_equal expected, DatagroutConduit::OAuth::TokenProvider.derive_token_endpoint(url)
  end

  def test_derive_token_endpoint_strips_mcp_subpath
    url = "https://app.datagrout.ai/servers/abc/mcp/extra"
    expected = "https://app.datagrout.ai/servers/abc/oauth/token"
    assert_equal expected, DatagroutConduit::OAuth::TokenProvider.derive_token_endpoint(url)
  end

  def test_derive_token_endpoint_without_mcp
    url = "https://app.datagrout.ai/servers/abc/"
    expected = "https://app.datagrout.ai/servers/abc/oauth/token"
    assert_equal expected, DatagroutConduit::OAuth::TokenProvider.derive_token_endpoint(url)
  end

  def test_get_token_fetches_and_caches
    stub_request(:post, TOKEN_ENDPOINT)
      .with(
        body: hash_including(
          "grant_type" => "client_credentials",
          "client_id" => "my_id",
          "client_secret" => "my_secret"
        )
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "access_token" => "jwt_token_123",
          "token_type" => "bearer",
          "expires_in" => 3600
        })
      )

    provider = DatagroutConduit::OAuth::TokenProvider.new(
      client_id: "my_id",
      client_secret: "my_secret",
      token_endpoint: TOKEN_ENDPOINT
    )

    token = provider.get_token
    assert_equal "jwt_token_123", token

    # Second call should use cache (WebMock would error on extra request)
    token2 = provider.get_token
    assert_equal "jwt_token_123", token2

    assert_requested :post, TOKEN_ENDPOINT, times: 1
  end

  def test_get_token_with_scope
    stub_request(:post, TOKEN_ENDPOINT)
      .with(
        body: hash_including(
          "grant_type" => "client_credentials",
          "client_id" => "my_id",
          "client_secret" => "my_secret",
          "scope" => "read write"
        )
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "access_token" => "scoped_token",
          "token_type" => "bearer",
          "expires_in" => 3600
        })
      )

    provider = DatagroutConduit::OAuth::TokenProvider.new(
      client_id: "my_id",
      client_secret: "my_secret",
      token_endpoint: TOKEN_ENDPOINT,
      scope: "read write"
    )

    assert_equal "scoped_token", provider.get_token
  end

  def test_invalidate_clears_cache
    stub_request(:post, TOKEN_ENDPOINT)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "access_token" => "first_token",
          "token_type" => "bearer",
          "expires_in" => 3600
        })
      ).then
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate({
          "access_token" => "second_token",
          "token_type" => "bearer",
          "expires_in" => 3600
        })
      )

    provider = DatagroutConduit::OAuth::TokenProvider.new(
      client_id: "my_id",
      client_secret: "my_secret",
      token_endpoint: TOKEN_ENDPOINT
    )

    assert_equal "first_token", provider.get_token

    provider.invalidate!
    assert_equal "second_token", provider.get_token

    assert_requested :post, TOKEN_ENDPOINT, times: 2
  end

  def test_auth_error_on_failure
    stub_request(:post, TOKEN_ENDPOINT)
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: '{"error": "invalid_client"}'
      )

    provider = DatagroutConduit::OAuth::TokenProvider.new(
      client_id: "bad_id",
      client_secret: "bad_secret",
      token_endpoint: TOKEN_ENDPOINT
    )

    assert_raises(DatagroutConduit::AuthError) { provider.get_token }
  end

  def test_provider_attributes
    provider = DatagroutConduit::OAuth::TokenProvider.new(
      client_id: "my_id",
      client_secret: "my_secret",
      token_endpoint: TOKEN_ENDPOINT
    )

    assert_equal "my_id", provider.client_id
    assert_equal TOKEN_ENDPOINT, provider.token_endpoint
  end
end
