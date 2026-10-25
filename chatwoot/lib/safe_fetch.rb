require 'ssrf_filter'

module SafeFetch
  DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/ video/].freeze
  DEFAULT_ALLOWED_CONTENT_TYPES = [].freeze
  DEFAULT_SENSITIVE_HEADERS = %w[authorization cookie proxy-authorization].freeze
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_READ_TIMEOUT = 20
  DEFAULT_MAX_BYTES_FALLBACK_MB = 40

  Result = Data.define(:tempfile, :filename, :content_type) do
    def original_filename
      filename
    end
  end

  class Error < StandardError; end
  class InvalidUrlError < Error; end
  class UnsafeUrlError < Error; end
  class FetchError < Error; end
  class HttpError < Error; end
  class FileTooLargeError < Error; end
  class UnsupportedContentTypeError < Error; end
  class UnsupportedMethodError < Error; end

  def self.fetch(url, **, &)
    raise ArgumentError, 'block required' unless block_given?

    SafeFetch::Fetcher.new(SafeFetch::RequestOptions.new(url: url, **)).fetch(&)
  rescue SsrfFilter::InvalidUriScheme, URI::InvalidURIError => e
    raise InvalidUrlError, e.message
  rescue SsrfFilter::Error, Resolv::ResolvError => e
    raise UnsafeUrlError, e.message
  end

  # LUAR: o 4.17 bloqueia qualquer webhook para IP privado, mas o Agent Bot fala com o bridge na rede interna.
  # Em vez de liberar a rede toda (SAFE_FETCH_ALLOW_PRIVATE_NETWORK), libera so os hosts da lista
  # SAFE_FETCH_PRIVATE_HOST_ALLOWLIST (ex.: chatwoot-bridge), comparados pelo nome exato do host.
  def self.allow_private_network?(host = nil)
    return true if ActiveModel::Type::Boolean.new.cast(ENV.fetch('SAFE_FETCH_ALLOW_PRIVATE_NETWORK', false))

    allowlisted_private_host?(host)
  end

  def self.allowlisted_private_host?(host)
    return false if host.blank?

    ENV.fetch('SAFE_FETCH_PRIVATE_HOST_ALLOWLIST', '').split(',').map { |h| h.strip.downcase }.compact_blank.include?(host.to_s.downcase)
  end
end
