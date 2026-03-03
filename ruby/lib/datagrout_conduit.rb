# frozen_string_literal: true

require "json"

require_relative "datagrout_conduit/version"
require_relative "datagrout_conduit/errors"
require_relative "datagrout_conduit/types"
require_relative "datagrout_conduit/identity"
require_relative "datagrout_conduit/oauth"
require_relative "datagrout_conduit/registration"
require_relative "datagrout_conduit/transport/base"
require_relative "datagrout_conduit/transport/mcp"
require_relative "datagrout_conduit/transport/jsonrpc"
require_relative "datagrout_conduit/client"

module DatagroutConduit
  DG_CA_URL = Registration::DG_CA_URL
  DG_SUBSTRATE_ENDPOINT = Registration::DG_SUBSTRATE_ENDPOINT

  # Returns true when +url+ points at a DataGrout-managed endpoint.
  #
  # Used to decide whether to auto-enable mTLS discovery and the intelligent
  # interface, and whether to warn when DG-specific methods are called against
  # a non-DG server.
  def self.dg_url?(url)
    url.to_s.include?("datagrout.ai") ||
      url.to_s.include?("datagrout.dev") ||
      ENV.key?("CONDUIT_IS_DG")
  end

  # Extract the DataGrout metadata block from a tool-call result.
  #
  # Checks +_meta.datagrout+ first (current format), then +_datagrout+,
  # then falls back to +_meta+ for backward compatibility with older
  # gateway responses.
  #
  # Returns nil when the result contains neither key (e.g. upstream servers
  # that don't go through the DG gateway).
  #
  #   meta = DatagroutConduit.extract_meta(result)
  #   meta.receipt.net_credits  #=> 1.5
  #   meta.receipt.receipt_id   #=> "rcp_abc123"
  def self.extract_meta(result)
    return nil unless result.is_a?(Hash)

    raw = result.dig("_meta", "datagrout") || result.dig(:_meta, :datagrout) ||
          result["_datagrout"] || result[:_datagrout] ||
          result["_meta"] || result[:_meta]
    return nil if raw.nil?

    ToolMeta.from_hash(raw)
  end
end
