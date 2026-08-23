module ShippingApp
  # A single Etsy shop/store, configured entirely through env vars - see
  # EtsyStoreConfig below for the exact var names.
  #
  # rate_source picks how shipping is priced/bought for this store's
  # orders:
  #   "easypost" - the same EasyPost rate-shop-and-buy flow already used
  #     for Tindie/Stripe orders (see ShippingService). Requires
  #     from_address.
  #   "etsy"     - this store buys its own postage directly on Etsy.com
  #     (Etsy's built-in USPS/UPS pricing). PackPoint shows the shipping
  #     price the buyer already paid instead of quoting/buying a label, and
  #     only offers "Mark as Shipped" (with tracking) so Etsy's own order
  #     status - and this app's unshipped list - stay in sync. No
  #     from_address needed.
  EtsyStore = Struct.new(:key, :name, :api_key, :shared_secret, :shop_id, :access_token,
                         :refresh_token, :from_address, :rate_source, keyword_init: true) do
    def easypost_rates?
      rate_source == 'easypost'
    end
  end

  # Reads N Etsy shop configurations out of the environment so one
  # PackPoint instance can pull orders from multiple Etsy shops, each with
  # its own API credentials - mirrors StripeStoreConfig's multi-store
  # id-grouping convention:
  #
  #   ETSY_STORE_1_NAME=Main Shop
  #   ETSY_STORE_1_SHOP_ID=12345678
  #   ETSY_STORE_1_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxx
  #   ETSY_STORE_1_SHARED_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxx
  #   ETSY_STORE_1_ACCESS_TOKEN=12345678.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  #   ETSY_STORE_1_REFRESH_TOKEN=12345678.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  #   ETSY_STORE_1_RATE_SOURCE=easypost
  #   ETSY_STORE_1_EASYPOST_FROM_ADDRESS=adr_xxxxxxxx
  #
  # API_KEY/SHARED_SECRET come from registering an app at
  # https://www.etsy.com/developers/your-apps. ACCESS_TOKEN/REFRESH_TOKEN
  # come from completing Etsy's OAuth 2.0 (PKCE) authorization once by hand
  # - see README.md's "Etsy setup" section (bin/etsy_oauth automates that
  # handshake). PackPoint only *uses* these tokens, it doesn't run the
  # interactive authorization step itself - and since the access token is
  # short-lived (about an hour) and the refresh token rotates on every use,
  # EtsyClient refreshes automatically and caches whatever pair it's
  # currently using in cache/etsy_tokens/<key>.json, so these ENV values
  # are only the *starting* tokens, not something that has to be kept
  # up to date by hand.
  #
  # Etsy support is entirely optional - if no ETSY_STORE_*_API_KEY vars are
  # set, this simply returns an empty list.
  class EtsyStoreConfig
    STORE_ID_PATTERN = /\AETSY_STORE_(?<id>[A-Za-z0-9]+)_API_KEY\z/
    VALID_RATE_SOURCES = %w[easypost etsy].freeze
    DEFAULT_RATE_SOURCE = 'easypost'.freeze

    class << self
      def stores
        ENV.keys.each_with_object([]) do |env_key, stores|
          match = STORE_ID_PATTERN.match(env_key)
          next unless match

          api_key = ENV[env_key].to_s
          next if api_key.empty?

          store = build_store(match[:id], api_key)
          stores << store if store
        end.sort_by(&:key)
      end

      private

      def build_store(id, api_key)
        shop_id = ENV["ETSY_STORE_#{id}_SHOP_ID"].to_s
        access_token = ENV["ETSY_STORE_#{id}_ACCESS_TOKEN"].to_s
        refresh_token = ENV["ETSY_STORE_#{id}_REFRESH_TOKEN"].to_s

        missing = required_field_names(id, shop_id, access_token, refresh_token)
        if missing.any?
          puts "WARNING: Etsy store '#{id}' is missing #{missing.join(', ')} - skipping"
          return nil
        end

        name = ENV["ETSY_STORE_#{id}_NAME"].to_s
        name = "Etsy Store #{id}" if name.empty?

        rate_source = ENV["ETSY_STORE_#{id}_RATE_SOURCE"].to_s.downcase
        rate_source = DEFAULT_RATE_SOURCE unless VALID_RATE_SOURCES.include?(rate_source)

        EtsyStore.new(
          key: id.downcase,
          name: name,
          api_key: api_key,
          shared_secret: ENV["ETSY_STORE_#{id}_SHARED_SECRET"].to_s,
          shop_id: shop_id,
          access_token: access_token,
          refresh_token: refresh_token,
          from_address: ENV["ETSY_STORE_#{id}_EASYPOST_FROM_ADDRESS"].to_s,
          rate_source: rate_source
        )
      end

      def required_field_names(id, shop_id, access_token, refresh_token)
        missing = []
        missing << "ETSY_STORE_#{id}_SHOP_ID" if shop_id.empty?
        missing << "ETSY_STORE_#{id}_ACCESS_TOKEN" if access_token.empty?
        missing << "ETSY_STORE_#{id}_REFRESH_TOKEN" if refresh_token.empty?
        missing
      end
    end
  end
end
