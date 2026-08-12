require 'delegate'

module ShippingApp
  # Decorates a TindieOrder or StripeOrder with which store it came from, so
  # views/orders.rhtml can render a store badge/tab and the buy-label form
  # can round-trip enough info (store_type/store_key) for the server to know
  # which API to talk to when a label is purchased.
  class StoreOrder < SimpleDelegator
    attr_reader :store_type, :store_key, :store_display_name

    def initialize(order, store_type:, store_key:, store_display_name:)
      super(order)
      @store_type = store_type
      @store_key = store_key
      @store_display_name = store_display_name
    end
  end
end
