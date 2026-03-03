# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "datagrout_conduit"
require "minitest/autorun"
require "webmock/minitest"
require "json"
