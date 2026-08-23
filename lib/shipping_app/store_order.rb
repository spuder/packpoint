require 'delegate'

module ShippingApp
  # Decorates a TindieOrder or StripeOrder with which store it came from, so
  # views/orders.rhtml can render a store badge/tab and the buy-label form
  # can round-trip enough info (store_type/store_key) for the server to know
  # which API to talk to when a label is purchased.
  class StoreOrder < SimpleDelegator
    attr_reader :store_type, :store_key, :store_display_name, :rate_source

    # rate_source is only meaningful for Etsy stores (see EtsyStoreConfig) -
    # nil for Tindie/Stripe orders, which only ever ship via EasyPost.
    def initialize(order, store_type:, store_key:, store_display_name:, rate_source: nil)
      super(order)
      @store_type = store_type
      @store_key = store_key
      @store_display_name = store_display_name
      @rate_source = rate_source
    end
  end
end
