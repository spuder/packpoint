module ShippingApp
  # Reads one store's shipping-provider choice, plus that provider's
  # per-store return address, off environment variables sharing a prefix -
  # e.g. "TINDIE" or "STRIPE_STORE_1". Shared by the single Tindie store
  # (app.rb) and every configured Stripe store (StripeStoreConfig), so
  # pointing a store at a different carrier platform - or a future one
  # beyond EasyPost/ShipStation - is purely an env var change; see
  # ShippingApp::ShippingProviders.build for where this actually turns into
  # a provider instance.
  #
  # <prefix>_SHIPPING_PROVIDER selects the provider ("easypost" (default) or
  # "shipstation"); only the matching provider's address vars need to be
  # set. EasyPost accounts store addresses server-side (an "adr_..." id
  # created once in the EasyPost dashboard/API), so <prefix>_EASYPOST_FROM_ADDRESS
  # is just that id. ShipStation has no equivalent for an account with no
  # warehouses configured, so its address is given inline via
  # <prefix>_SHIPSTATION_FROM_* vars instead.
  class StoreShippingConfig
    PROVIDERS = %w[easypost shipstation].freeze
    DEFAULT_PROVIDER = 'easypost'.freeze

    attr_reader :provider, :easypost_from_address, :shipstation_ship_from

    def initialize(env_prefix)
      @env_prefix = env_prefix
      @provider = ENV["#{env_prefix}_SHIPPING_PROVIDER"].to_s.strip.downcase
      @provider = DEFAULT_PROVIDER if @provider.empty?

      @easypost_from_address = ENV["#{env_prefix}_EASYPOST_FROM_ADDRESS"].to_s

      country = ENV["#{env_prefix}_SHIPSTATION_FROM_COUNTRY"].to_s
      @shipstation_ship_from = {
        name: ENV["#{env_prefix}_SHIPSTATION_FROM_NAME"].to_s,
        company: ENV["#{env_prefix}_SHIPSTATION_FROM_COMPANY"].to_s,
        phone: ENV["#{env_prefix}_SHIPSTATION_FROM_PHONE"].to_s,
        street1: ENV["#{env_prefix}_SHIPSTATION_FROM_STREET1"].to_s,
        street2: ENV["#{env_prefix}_SHIPSTATION_FROM_STREET2"].to_s,
        city: ENV["#{env_prefix}_SHIPSTATION_FROM_CITY"].to_s,
        state: ENV["#{env_prefix}_SHIPSTATION_FROM_STATE"].to_s,
        zip: ENV["#{env_prefix}_SHIPSTATION_FROM_POSTAL_CODE"].to_s,
        country: country.empty? ? 'US' : country
      }
    end

    # Whichever address value ShippingProviders.build's chosen provider
    # actually needs - an EasyPost address id (String) or a ShipStation
    # ship-from address (Hash). Providers treat this as opaque to them via
    # their own constructor; nothing outside StoreShippingConfig/
    # ShippingProviders.build needs to know which shape it is.
    def ship_from
      provider == 'shipstation' ? shipstation_ship_from : easypost_from_address
    end

    # False when the selected provider's address vars aren't fully set -
    # used at boot to warn (not fail - mirrors the pre-ShipStation
    # behavior) that buying a label for this store will fail until fixed.
    def configured?
      provider == 'shipstation' ? shipstation_configured? : !easypost_from_address.empty?
    end

    # Human-readable hint for the boot-time warning - which env vars to go
    # set.
    def missing_config_hint
      if provider == 'shipstation'
        "#{@env_prefix}_SHIPSTATION_FROM_NAME/STREET1/CITY/STATE/POSTAL_CODE"
      else
        "#{@env_prefix}_EASYPOST_FROM_ADDRESS"
      end
    end

    private

    def shipstation_configured?
      %i[name street1 city state zip].all? { |key| !shipstation_ship_from[key].to_s.empty? }
    end
  end
end
