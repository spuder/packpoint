require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

module ShippingApp
  # Raised for anything wrong with an Etsy API call - a bad/expired
  # refresh token, a rejected request, a network failure. Callers rescue
  # this the same way StripeOrdersAPI callers rescue Stripe::StripeError -
  # see app.rb's fetch_etsy_orders/mark_etsy_order_shipped.
  class EtsyApiError < StandardError; end

  # Thin HTTP client for one Etsy shop/store - handles the x-api-key
  # header, the OAuth bearer token, and refreshing that token when it's
  # expired.
  #
  # Etsy access tokens are short-lived (about an hour) and refresh tokens
  # rotate on every use, so this caches whatever pair it's currently using
  # in cache/etsy_tokens/<store_key>.json (the same cache/ directory
  # /print_label already writes downloaded labels to - see app.rb). That
  # means a refresh doesn't have to touch ENV/.env to keep working, and a
  # process restart picks up the most recently rotated tokens instead of
  # whatever was last typed into .env. EtsyStoreConfig's ACCESS_TOKEN/
  # REFRESH_TOKEN are only the *starting* values, used the first time (or
  # if the cache file is ever deleted).
  class EtsyClient
    BASE_URL = 'https://openapi.etsy.com/v3/application'.freeze
    TOKEN_URL = 'https://api.etsy.com/v3/public/oauth/token'.freeze
    CACHE_DIR = File.join(Dir.pwd, 'cache', 'etsy_tokens')

    def initialize(store)
      @store = store
      @access_token, @refresh_token = load_tokens(store)
    end

    def get(path, params = {})
      request(:get, path, params: params)
    end

    def post(path, params = {})
      request(:post, path, form: params.compact)
    end

    private

    # Prefers whatever's cached on disk (may be more recent than ENV, since
    # refresh tokens rotate) and falls back to the store's configured
    # starting tokens the first time this store is ever used.
    def load_tokens(store)
      cached = read_cache(store.key)
      return [cached['access_token'], cached['refresh_token']] if cached && cached['access_token']

      [store.access_token, store.refresh_token]
    end

    def request(method, path, params: {}, form: nil, retried: false)
      uri = build_uri(path, params)
      response = perform(uri, build_request(method, uri, form))

      if response.code.to_i == 401 && !retried
        refresh!
        return request(method, path, params: params, form: form, retried: true)
      end

      parse!(response)
    end

    def build_uri(path, params)
      uri = URI.join("#{BASE_URL}/", path.sub(%r{\A/}, ''))
      uri.query = URI.encode_www_form(params) unless params.empty?
      uri
    end

    def build_request(method, uri, form)
      request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = request_class.new(uri)
      req['x-api-key'] = @store.api_key
      req['Authorization'] = "Bearer #{@access_token}"
      req['Accept'] = 'application/json'
      req.form_data = form if form
      req
    end

    def perform(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    rescue StandardError => e
      raise EtsyApiError, "#{@store.name}: request to #{uri.path} failed: #{e.class} - #{e.message}"
    end

    def parse!(response)
      body = response.body.to_s.strip.empty? ? {} : JSON.parse(response.body)
      return body if response.is_a?(Net::HTTPSuccess)

      message = body.is_a?(Hash) ? (body['error_description'] || body['error'] || body['message']) : nil
      raise EtsyApiError, "#{@store.name}: HTTP #{response.code}#{message ? " - #{message}" : ''}"
    rescue JSON::ParserError
      raise EtsyApiError, "#{@store.name}: HTTP #{response.code} - #{response.body}"
    end

    # https://developers.etsy.com/documentation/essentials/authentication -
    # PKCE authorization code flow, so client_secret is only sent if this
    # store's app was registered with one; most public/PKCE-only apps don't
    # need it for the refresh step.
    def refresh!
      if @refresh_token.to_s.empty?
        raise EtsyApiError,
              "#{@store.name}: no refresh token available - re-run bin/etsy_oauth"
      end

      uri = URI(TOKEN_URL)
      req = Net::HTTP::Post.new(uri)
      req.form_data = {
        grant_type: 'refresh_token',
        client_id: @store.api_key,
        client_secret: @store.shared_secret.to_s.empty? ? nil : @store.shared_secret,
        refresh_token: @refresh_token
      }.compact

      data = parse!(perform(uri, req))
      @access_token = data['access_token']
      @refresh_token = data['refresh_token'] || @refresh_token
      write_cache(@store.key, @access_token, @refresh_token)
      puts "Etsy[#{@store.name}]: refreshed access token"
    end

    def read_cache(key)
      path = cache_path(key)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError => e
      puts "WARNING: Etsy[#{key}]: failed to read cached tokens, falling back to .env: #{e.class} - #{e.message}"
      nil
    end

    def write_cache(key, access_token, refresh_token)
      FileUtils.mkdir_p(CACHE_DIR)
      File.write(cache_path(key), { access_token: access_token, refresh_token: refresh_token }.to_json)
    rescue StandardError => e
      puts "WARNING: Etsy[#{key}]: failed to cache refreshed tokens (will refresh again next " \
           "restart): #{e.class} - #{e.message}"
    end

    def cache_path(key)
      File.join(CACHE_DIR, "#{key}.json")
    end
  end
end
