# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "stores"

module MeowRelease
  # Minimal JSON-over-HTTPS transport shared by the store clients. 429 and
  # 5xx answers and network timeouts are TransientError (retried by
  # Retry.with_backoff); every other non-2xx answer is a permanent Error
  # carrying the service's own message, which ends up as a blocker.
  class HTTPTransport
    TRANSIENT = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError,
                 SocketError, OpenSSL::SSL::SSLError].freeze

    def call(method, url, headers: {}, body: nil, raw_body: nil)
      uri = URI(url)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |key, value| request[key] = value }
      if raw_body
        request.body_stream = raw_body
        request["Content-Length"] = raw_body.size.to_s
      elsif body
        request["Content-Type"] ||= "application/json"
        request.body = body.is_a?(String) ? body : JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 300) do |http|
        http.request(request)
      end
      [response.code.to_i, response.body.to_s]
    rescue *TRANSIENT => e
      raise TransientError, "#{method.upcase} #{uri.host}#{uri.path}: #{e.class}"
    end
  end

  module HTTPResult
    module_function

    def parse(status, body, what)
      if status == 429 || status >= 500
        raise TransientError, "#{what}: HTTP #{status}"
      end
      raise Error, "#{what}: HTTP #{status}: #{service_message(body)}" unless (200..299).cover?(status)

      body.to_s.strip.empty? ? {} : JSON.parse(body)
    end

    # App Store Connect: {"errors":[{"title","detail"}]}; Google:
    # {"error":{"message"}}. Never echoes request headers or tokens.
    def service_message(body)
      data = JSON.parse(body.to_s)
      errors = Array(data["errors"]).map { |e| [e["title"], e["detail"]].compact.join(": ") }
      errors << data.dig("error", "message") if data.dig("error", "message")
      errors.empty? ? body.to_s[0, 300] : errors.join("; ")
    rescue JSON::ParserError
      body.to_s[0, 300]
    end
  end
end
