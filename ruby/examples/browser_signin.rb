#!/usr/bin/env ruby
# frozen_string_literal: true

# Browser-consent sign-in with OAuth 2.1 authorization code + PKCE.
#
# Run once and it prints a consent URL, captures the redirect on 127.0.0.1, and
# writes the grant to disk. Run again and it reuses what it saved.
#
#   ruby -Ilib examples/browser_signin.rb
#
# Two things this example exists to demonstrate, both of which are easy to get
# wrong and only fail later:
#
#  1. The registered client id is persisted *with its redirect URI*, and the
#     listener re-binds that exact port on the next run. Authorization servers
#     match redirect URIs exactly, with no loopback-port exemption.
#  2. DataGrout rotates refresh tokens, so a refreshed grant is written back. A
#     grant that is refreshed and not persisted leaves a consumed token on disk,
#     and the next run fails with `invalid_grant`.

require "datagrout_conduit"
require "fileutils"
require "json"

AC = DatagroutConduit::AuthCode

GATEWAY = "https://gateway.datagrout.ai/connect"

# Where this example keeps its credentials.
#
# A file, and deliberately called out as such: it holds a refresh token, which
# is a long-lived credential. A real application should prefer the OS keychain.
# The SDK does not choose for you.
STORE = File.join(Dir.home, ".config", "conduit-example", "signin.json")

def load_saved
  saved = JSON.parse(File.read(STORE))
  [AC::RegisteredClient.from_h(saved["registered"]), AC::Grant.from_h(saved["grant"])]
rescue Errno::ENOENT, JSON::ParserError
  nil
end

def save(registered, grant)
  FileUtils.mkdir_p(File.dirname(STORE))
  File.write(STORE, JSON.pretty_generate(
                      "registered" => registered.to_h, "grant" => grant.to_h
                    ))
  File.chmod(0o600, STORE)
end

# Run the full consent flow and return something worth persisting.
def sign_in(existing = nil)
  # Bind first: the real port has to be known before the redirect URI is
  # registered. Reusing a saved registration means re-binding its exact port.
  listener =
    if existing
      begin
        AC::LoopbackListener.bind_for(existing.redirect_uri)
      rescue AC::Error
        warn "port for #{existing.redirect_uri} is taken — registering a fresh client"
        AC::LoopbackListener.bind
      end
    else
      AC::LoopbackListener.bind
    end

  flow = AC::Flow.discover(GATEWAY)

  # A saved registration is only reusable if the listener came back on its
  # port; otherwise register anew rather than authorize against a URI the
  # server will reject.
  registered =
    if existing && listener.redirect_uri == existing.redirect_uri
      flow.with_registered_client(existing)
      existing
    else
      flow.register("Conduit Example", listener.redirect_uri)
    end

  url, pending = flow.authorize_url
  puts "\nOpen this URL to sign in:\n\n  #{url}\n"

  redirect = listener.wait(timeout: 300)
  [registered, flow.exchange(pending, redirect.code, redirect.state)]
end

saved = load_saved

if saved
  puts "using the saved sign-in"
  registered, grant = saved
else
  registered, grant = sign_in
  save(registered, grant)
  puts "signed in; credentials written to #{STORE}"
end

# Own the provider so a rotated refresh token can be written back.
provider = AC::Provider.new(grant)

client = DatagroutConduit::Client.new(url: GATEWAY, auth: { authorization_code: provider })
client.connect

begin
  tools = client.list_tools
  puts "\n#{tools.length} tools available on this server:"
  tools.first(5).each { |tool| puts "  - #{tool['name']}" }
ensure
  rotated = provider.take_if_dirty
  if rotated
    save(registered, rotated)
    puts "\n(the grant was refreshed and re-saved)"
  end
  client.disconnect
end
