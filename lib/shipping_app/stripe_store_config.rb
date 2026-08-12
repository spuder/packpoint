module ShippingApp
  # A single Stripe account/store, configured entirely through env vars.
  StripeStore = Struct.new(:key, :name, :secret_key, :from_address, keyword_init: true)

  # Reads N Stripe stores out of the environment so one PackPoint instance
  # can pull orders from multiple Stripe accounts. Each store is declared
  # with a couple of env vars sharing an id, e.g.:
  #
  #   STRIPE_STORE_1_NAME=Main Shop
  #   STRIPE_STORE_1_SECRET_KEY=sk_live_xxxxx
  #   STRIPE_STORE_1_EASYPOST_FROM_ADDRESS=adr_xxxxxxxx
  #   STRIPE_STORE_2_NAME=Side Project
  #   STRIPE_STORE_2_SECRET_KEY=sk_live_yyyyy
  #   STRIPE_STORE_2_EASYPOST_FROM_ADDRESS=adr_yyyyyyyy
  #
  # STRIPE_STORE_<id>_EASYPOST_FROM_ADDRESS is the EasyPost address ID that
  # shipping labels for that store's orders should be shipped from. It's
  # required per store - see ShippingApp::ShippingService.
  #
  # Stripe support is entirely optional - if no STRIPE_STORE_*_SECRET_KEY
  # vars are set, this simply returns an empty list.
  class StripeStoreConfig
    STORE_ID_PATTERN = /\ASTRIPE_STORE_(?<id>[A-Za-z0-9]+)_SECRET_KEY\z/

    class << self
      def stores
        ENV.keys.each_with_object([]) do |env_key, stores|
          match = STORE_ID_PATTERN.match(env_key)
          next unless match

          secret_key = ENV[env_key].to_s
          next if secret_key.empty?

          id = match[:id]
          name = ENV["STRIPE_STORE_#{id}_NAME"].to_s
          name = "Stripe Store #{id}" if name.empty?
          from_address = ENV["STRIPE_STORE_#{id}_EASYPOST_FROM_ADDRESS"].to_s

          stores << StripeStore.new(key: id.downcase, name: name, secret_key: secret_key, from_address: from_address)
        end.sort_by(&:key)
      end
    end
  end
end
