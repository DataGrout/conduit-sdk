# frozen_string_literal: true

require_relative "lib/datagrout_conduit/version"

Gem::Specification.new do |spec|
  spec.name          = "datagrout-conduit"
  spec.version       = DatagroutConduit::VERSION
  spec.authors       = ["DataGrout"]
  spec.email         = ["hello@datagrout.ai"]

  spec.summary       = "Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery"
  spec.description   = "Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery. " \
                        "Connect to remote MCP and JSONRPC servers, invoke tools, discover capabilities " \
                        "with natural language, and track costs — all with enterprise-grade security."
  spec.homepage      = "https://github.com/DataGrout/conduit-sdk"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/DataGrout/conduit-sdk/tree/main/ruby"
  spec.metadata["changelog_uri"]   = "https://github.com/DataGrout/conduit-sdk/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/DataGrout/conduit-sdk/issues"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "README.md", "LICENSE"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "base64"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
