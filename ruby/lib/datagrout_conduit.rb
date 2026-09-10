# frozen_string_literal: true

require "json"

require_relative "datagrout_conduit/version"
require_relative "datagrout_conduit/errors"
require_relative "datagrout_conduit/types"
require_relative "datagrout_conduit/identity"
require_relative "datagrout_conduit/oauth"
require_relative "datagrout_conduit/authcode"
# The loopback listener lives in its own file so a headless caller can take the
# flow without one, but it is required here — the same surface every conduit SDK
# presents — and it needs nothing beyond the standard library.
require_relative "datagrout_conduit/authcode/loopback"
# RFC 8693 delegation. Loaded after both grants, since a delegated token's
# subject and actor can come from either of them.
require_relative "datagrout_conduit/delegation"
require_relative "datagrout_conduit/registration"
require_relative "datagrout_conduit/onramp"
require_relative "datagrout_conduit/transport/base"
require_relative "datagrout_conduit/transport/mcp"
require_relative "datagrout_conduit/transport/jsonrpc"
require_relative "datagrout_conduit/transport/ws"
require_relative "datagrout_conduit/namespaces/prism"
require_relative "datagrout_conduit/namespaces/logic"
require_relative "datagrout_conduit/namespaces/warden"
require_relative "datagrout_conduit/namespaces/deliverables"
require_relative "datagrout_conduit/namespaces/ephemerals"
require_relative "datagrout_conduit/namespaces/flow"
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

end
