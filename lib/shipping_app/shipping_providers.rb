module ShippingApp
  # Namespace for the pluggable shipping providers a store can ship
  # through - currently ShippingProviders::EasyPostProvider and
  # ShippingProviders::ShipStationProvider (see those files). Every
  # provider implements the same duck-typed contract so app.rb and
  # views/orders.rhtml don't need to know or care which one a given store
  # is using:
  #
  #   #get_rates(order_number, order_data, parcel_override = nil, customs_items: nil)
  #     -> { shipment_id:, rates: [{ carrier:, service:, rate:, currency: }, ...] }
  #     Quotes (without buying) each of CARRIER_FAMILIES that has a rate for
  #     this shipment. shipment_id is opaque outside the provider that
  #     issued it - callers only ever pass it back to that same provider's
  #     #create_label, never inspect it.
  #
  #   #create_label(order_number, order_data, parcel_override = nil, shipment_id: nil, carrier: 'usps', customs_items: nil)
  #     -> { tracking_code:, label_url: }
  #     Buys a label for `carrier` (one of CARRIER_FAMILIES). If shipment_id
  #     is given (from a prior #get_rates call), that exact quote is bought
  #     instead of quoting again, so the price charged matches the price
  #     already shown to the user.
  #
  #   #verify_address(order_data)
  #     -> { verified:, messages:, normalized_address: }
  #     Best-effort, informational address check - see each provider for
  #     details on how strict this is.
  #
  # A provider's constructor takes just that store's ship-from address (see
  # StoreShippingConfig#ship_from) - account-wide credentials
  # (EASYPOST_API_KEY, SHIPSTATION_API_KEY) come straight from ENV, since
  # this app only ever talks to one account per provider, shared across
  # every store that uses it.
  module ShippingProviders
    # Carrier "families" the buy window quotes/buys from, and the shared
    # vocabulary every provider normalizes its own carrier
    # ids/codes/names onto (see each provider's own mapping) - this is what
    # lets views/orders.rhtml render carrier icons/labels
    # (CARRIER_LABELS/CARRIER_MONOGRAMS there) the same way regardless of
    # which provider actually quoted the rate. Order matters: USPS is
    # first/default. DHL only has rates internationally in practice, but is
    # left in this one list rather than split out - both providers already
    # tolerate a carrier having no rate for a given shipment, so a domestic
    # quote just quietly won't include it.
    CARRIER_FAMILIES = %w[usps fedex ups dhl].freeze

    # Raised when a provider's own API rejects a well-formed request (bad
    # credentials, carrier declined the shipment, etc.) - the ShipStation
    # equivalent of EasyPost::Errors::EasyPostError, so app.rb can rescue
    # both the same way without needing to know which provider is in use
    # for a given store. See ShipStationProvider.
    class CarrierError < StandardError; end

    # Raised by .build itself when a store's <prefix>_SHIPPING_PROVIDER
    # isn't one of StoreShippingConfig::PROVIDERS.
    class UnknownProviderError < StandardError; end

    # store_shipping: a StoreShippingConfig - see that class for how a
    # store picks its provider and where its ship-from address comes from.
    def self.build(store_shipping)
      case store_shipping.provider
      when 'easypost'
        EasyPostProvider.new(store_shipping.easypost_from_address)
      when 'shipstation'
        ShipStationProvider.new(store_shipping.shipstation_ship_from)
      else
        raise UnknownProviderError,
              "Unknown shipping provider '#{store_shipping.provider}' - expected one of: #{StoreShippingConfig::PROVIDERS.join(', ')}"
      end
    end
  end
end
