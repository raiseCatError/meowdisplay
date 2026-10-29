# frozen_string_literal: true

# MeowDisplay's cross-platform release automation (stdlib Ruby only):
# release state, store monitoring and submission, publication order and the
# readiness report. See RELEASE.md § "Cross-platform release automation".
require_relative "meow_release/version"
require_relative "meow_release/state"
require_relative "meow_release/stores"
require_relative "meow_release/config"
require_relative "meow_release/coordinator"
require_relative "meow_release/publisher"
require_relative "meow_release/summary"
require_relative "meow_release/http"
require_relative "meow_release/app_store_connect"
require_relative "meow_release/google_play"
