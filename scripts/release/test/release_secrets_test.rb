# frozen_string_literal: true

require_relative "test_helper"
load File.expand_path("../release-secrets.rb", __dir__)

class ReleaseSecretsTest < Minitest::Test
  PEM = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----\n"

  def test_a_raw_app_store_connect_key_is_stored_base64_encoded
    stored = stored_value("APP_STORE_CONNECT_KEY_CONTENT", PEM)
    assert_equal PEM, stored.unpack1("m0")
    refute_includes stored, "\n"
  end

  def test_an_already_encoded_key_and_other_secrets_are_stored_unchanged
    encoded = [PEM].pack("m0")
    assert_same encoded, stored_value("APP_STORE_CONNECT_KEY_CONTENT", encoded)
    assert_same PEM, stored_value("SPARKLE_PRIVATE_KEY", PEM)
  end
end
