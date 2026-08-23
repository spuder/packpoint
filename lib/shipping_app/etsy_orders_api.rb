module ShippingApp
  # Converts an Etsy "Money" object ({"amount" => .., "divisor" => ..,
  # "currency_code" => ..}) into a plain float - see
  # https://developers.etsy.com/documentation/essentials/definitions#money
  module EtsyMoney
    def self.to_f(money)
      return 0.0 unless money.is_a?(Hash)

      amount = money['amount'].to_f
      divisor = money['divisor'].to_f
      divisor.zero? ? 0.0 : amount / divisor
    end
  end

  class EtsyProduct
    attr_reader :name, :qty, :price, :options, :unit_price, :sku

    def initialize(transaction)
      @name = transaction['title']
      @qty = [transaction['quantity'].to_i, 1].max
      @unit_price = EtsyMoney.to_f(transaction['price'])
      @price = @unit_price * @qty
      @sku = transaction['sku']
      @options = build_options(transaction['variations'])
    end

    private

    # Variations look like [{"formatted_name" => "Color", "formatted_value" => "Red"}, ...]
    def build_options(variations)
      Array(variations).filter_map do |variation|
        value = variation['formatted_value']
        next if value.to_s.empty?

        name = variation['formatted_name']
        name.to_s.empty? ? value : "#{name}: #{value}"
      end.join(', ')
    end
  end

  # Wraps an Etsy Shop_Receipt so it exposes the same interface as
  # TindieApi::TindieOrder/StripeOrder (order_number, date, products,
  # shipped, address_dict, address_str, recipient_email, recipient_phone) -
  # that way views/orders.rhtml can treat orders from any source
  # identically, same as StripeOrder.
  #
  # Etsy has no per-product customs fields either (like Tindie - see
  # CustomsCatalog), so EtsyProduct exposes `sku` rather than
  # `customs_metadata` and CustomsInfoBuilder falls back to the SKU-keyed
  # catalog for these, same as Tindie products.
  class EtsyOrder
    attr_reader :date, :date_shipped, :products, :shipped, :order_number, :receipt_id,
                :recipient_email, :recipient_phone, :address_dict, :address_str,
                :tracking_code, :tracking_url, :shipping_cost, :payment_intent_id

    def initialize(receipt, country_names: COUNTRY_NAMES)
      @receipt_id = receipt['receipt_id']
      @order_number = @receipt_id.to_s
      @date = Time.at(receipt['create_timestamp'].to_i)
      @products = Array(receipt['transactions']).map { |txn| EtsyProduct.new(txn) }
      @shipped = receipt['is_shipped'] ? true : false
      @shipping_cost = EtsyMoney.to_f(receipt['total_shipping_cost'])
      # Etsy has no PaymentIntent-style handle to write fulfillment back to
      # (see #mark_shipped below, which posts tracking straight to the
      # receipt) - kept here only so views/orders.rhtml's shared hidden
      # form field (order.payment_intent_id, Stripe-only) has something to
      # call that doesn't blow up for an Etsy order.
      @payment_intent_id = nil

      last_shipment = Array(receipt['shipments']).last
      @tracking_code = last_shipment && last_shipment['tracking_code']
      @tracking_url = nil
      shipped_at = last_shipment && last_shipment['shipment_notification_timestamp']
      @date_shipped = shipped_at && Time.at(shipped_at.to_i)

      build_address(receipt, country_names)
      @recipient_email = receipt['buyer_email']
      # Not part of the ShopReceipt schema - Etsy just doesn't expose a
      # recipient phone number. ShippingService falls back to the return
      # address's own phone when this is nil, same as it does for Tindie/
      # Stripe orders that don't have one on file either.
      @recipient_phone = nil
    end

    def has_shipping_address?
      !@address_dict[:street].to_s.empty?
    end

    private

    def build_address(receipt, country_names)
      country_code = receipt['country_iso']
      @address_dict = {
        recipient_name: receipt['name'],
        street: [receipt['first_line'], receipt['second_line']].compact.reject(&:empty?).join(', '),
        city: receipt['city'],
        state: receipt['state'],
        postcode: receipt['zip'],
        country_code: country_code,
        country: country_names[country_code] || country_code,
        instructions: nil,
        service: nil
      }
      @address_str = "#{@address_dict[:recipient_name]}\n#{@address_dict[:street]}\n" \
                     "#{@address_dict[:city]} #{@address_dict[:state]} #{@address_dict[:postcode]}\n" \
                     "#{@address_dict[:country]}"
    end
  end

  class EtsyOrdersAPI
    PAGE_SIZE = 100

    # Carrier family (as used elsewhere in this app - see
    # ShippingService::QUOTED_CARRIERS) -> Etsy's own carrier_name values,
    # used when submitting tracking after buying a label through EasyPost
    # (see #mark_shipped). Anything not in this map - including whatever a
    # person typed into the manual "Mark as Shipped" carrier field - is
    # passed through as-is, since createReceiptShipment accepts arbitrary
    # carrier_name strings (falling back to "other" if it's blank).
    ETSY_CARRIER_NAMES = { 'usps' => 'usps', 'fedex' => 'fedex', 'ups' => 'ups', 'dhl' => 'dhl-express' }.freeze

    def initialize(store)
      @store = store
      @client = EtsyClient.new(store)
    end

    # Mirrors StripeOrdersAPI#get_all_orders / TindieApi::TindieOrdersAPI#get_all_orders.
    # created_after (a Time) bounds the search server-side via min_created -
    # used by the archive view, same as Stripe's created_after.
    def get_all_orders(shipped = false, created_after: nil)
      receipts = fetch_receipts(shipped: shipped, created_after: created_after)
      orders = receipts.map { |receipt| EtsyOrder.new(receipt) }

      with_address = orders.select(&:has_shipping_address?)
      without_address = orders.size - with_address.size

      puts "Etsy[#{@store.name}]: #{receipts.size} receipt(s), " \
           "#{without_address} skipped (no shipping address/digital-only), #{with_address.size} shippable"

      with_address
    end

    # Submits tracking for a receipt - which is also how Etsy marks a
    # receipt shipped, per createReceiptShipment. Etsy requires a
    # carrier_name alongside tracking_code for some shipments (domestic
    # orders over $10, or anything shipping to India); rather than fail the
    # whole request when the caller doesn't have/know one, this falls back
    # to "other", which Etsy accepts for unsupported/unknown carriers.
    def mark_shipped(receipt_id, tracking_code:, carrier_name: nil)
      params = { tracking_code: tracking_code }
      params[:carrier_name] = resolve_carrier_name(carrier_name) unless tracking_code.to_s.empty?

      @client.post("shops/#{@store.shop_id}/receipts/#{receipt_id}/tracking", params)
    end

    private

    def resolve_carrier_name(carrier)
      return 'other' if carrier.to_s.strip.empty?

      ETSY_CARRIER_NAMES[carrier.to_s.downcase] || carrier
    end

    def fetch_receipts(shipped:, created_after: nil)
      results = []
      offset = 0
      total = nil

      loop do
        params = { limit: PAGE_SIZE, offset: offset, was_paid: true }
        params[:was_shipped] = shipped unless shipped.nil?
        params[:min_created] = created_after.to_i if created_after

        page = @client.get("shops/#{@store.shop_id}/receipts", params)
        batch = Array(page['results'])
        results.concat(batch)
        total ||= page['count'].to_i
        offset += batch.size

        break if batch.empty? || offset >= total
      end

      results
    end
  end
end
