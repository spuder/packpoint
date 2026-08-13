module ShippingApp
  class StripeProduct
    attr_reader :name, :qty, :price, :options

    def initialize(line_item)
      @name = line_item.description
      @qty = line_item.quantity
      @price = line_item.amount_total.to_f / 100
      @options = nil
    end
  end

  # Wraps a paid Stripe Checkout Session so it exposes the same interface
  # as TindieApi::TindieOrder (order_number, date, products, shipped,
  # address_dict, address_str, recipient_email, recipient_phone) - that way
  # views/orders.rhtml can treat orders from either source identically.
  #
  # Stripe has no built-in "shipped" status, so fulfillment is tracked via
  # a `fulfillment_status` metadata key on the PaymentIntent, per Stripe's
  # own guidance (https://docs.stripe.com/metadata/use-cases). This used to
  # live on the Checkout Session instead, because the restricted API key
  # got a "secret_key_required" error writing to the PaymentIntent - that
  # turned out to just be a missing "Payment Intents: Write" permission on
  # the key, not a hard restricted-key wall, so once granted the
  # PaymentIntent write went through fine.
  class StripeOrder
    attr_reader :json_parsed, :date, :date_shipped, :products, :shipped, :order_number,
                :recipient_email, :recipient_phone, :address_dict, :address_str,
                :payment_intent_id, :tracking_code, :tracking_url

    # How many trailing characters of the session id to show when there's
    # no shorter identifier to fall back on (see #short_order_number).
    ID_SUFFIX_LENGTH = 8

    def initialize(session, country_names: COUNTRY_NAMES)
      @json_parsed = session
      @order_number = session.id
      @client_reference_id = session.respond_to?(:client_reference_id) ? session.client_reference_id : nil
      @date = Time.at(session.created)
      @products = Array(session.line_items&.data).map { |item| StripeProduct.new(item) }

      # fetch_paid_sessions expands payment_intent, so this is the full
      # object (with metadata) rather than just an id.
      payment_intent = session.payment_intent
      @payment_intent_id = payment_intent.respond_to?(:id) ? payment_intent.id : payment_intent

      metadata = (payment_intent.respond_to?(:metadata) && payment_intent.metadata) || {}
      @shipped = metadata['fulfillment_status'] == 'shipped'
      @tracking_code = metadata['tracking_code']
      @tracking_url = metadata['tracking_url']
      @date_shipped = metadata['shipped_at'] && Time.parse(metadata['shipped_at'])

      build_address(session, country_names)

      @recipient_email = session.customer_details&.email
      @recipient_phone = session.customer_details&.phone
    end

    def has_shipping_address?
      !@address_dict[:street].to_s.empty?
    end

    # Checkout Session ids (order_number) are long random strings - great
    # as a unique key, unusable in a narrow table column. Stripe doesn't
    # generate a short order number of its own, so prefer client_reference_id
    # (a short id the merchant's own checkout flow can optionally set,
    # https://docs.stripe.com/api/checkout/sessions/object#checkout_session_object-client_reference_id)
    # and otherwise fall back to a truncated session id, similar to a git
    # short SHA.
    def short_order_number
      return @client_reference_id unless @client_reference_id.to_s.empty?

      "…#{@order_number[-ID_SUFFIX_LENGTH..]}"
    end

    private

    def build_address(session, country_names)
      shipping = shipping_details(session)
      address = shipping&.address
      country_code = address&.country

      @address_dict = {
        recipient_name: shipping&.name || session.customer_details&.name,
        street: [address&.line1, address&.line2].compact.reject(&:empty?).join(', '),
        city: address&.city,
        state: address&.state,
        postcode: address&.postal_code,
        country_code: country_code,
        country: country_names[country_code] || country_code,
        instructions: nil,
        service: nil
      }
      @address_str = "#{@address_dict[:recipient_name]}\n#{@address_dict[:street]}\n" \
                     "#{@address_dict[:city]} #{@address_dict[:state]} #{@address_dict[:postcode]}\n" \
                     "#{@address_dict[:country]}"
    end

    # The `shipping_details` field moved from the top level of a Checkout
    # Session to `collected_information.shipping_details` in the 2025-03-31
    # "basil" API version. Support both so this works regardless of which
    # API version the Stripe account/key is pinned to.
    def shipping_details(session)
      if session.respond_to?(:collected_information) && session.collected_information
        session.collected_information.shipping_details
      elsif session.respond_to?(:shipping_details)
        session.shipping_details
      end
    end
  end

  class StripeOrdersAPI
    PAGE_SIZE = 100

    def initialize(store_key, store_name, secret_key)
      @store_key = store_key
      @store_name = store_name
      @client = Stripe::StripeClient.new(secret_key)
    end

    # Mirrors TindieApi::TindieOrdersAPI#get_all_orders. Only returns paid
    # sessions that collected a shipping address (digital-only purchases
    # have nothing for PackPoint to ship). Pass created_after (a Time) to
    # bound the search server-side - used by the archive view so it doesn't
    # have to page through a store's entire order history to find recently
    # shipped ones.
    def get_all_orders(shipped = false, created_after: nil)
      sessions = fetch_paid_sessions(created_after: created_after)
      orders = sessions.map { |session| StripeOrder.new(session) }

      with_address = orders.select(&:has_shipping_address?)
      without_address = orders.size - with_address.size

      result = shipped.nil? ? with_address : with_address.select { |order| order.shipped == shipped }

      puts "Stripe[#{@store_name}]: #{sessions.size} paid session(s), " \
           "#{without_address} skipped (no shipping address), " \
           "#{with_address.size} shippable, #{result.size} matching shipped=#{shipped.inspect}"

      result
    end

    # payment_intent_id here is StripeOrder#payment_intent_id, not the
    # Checkout Session id - see the StripeOrder class comment.
    def mark_shipped(payment_intent_id, tracking_code:, label_url: nil, tracking_url: nil, carrier: nil)
      return unless payment_intent_id

      metadata = {
        fulfillment_status: 'shipped',
        tracking_code: tracking_code,
        tracking_url: tracking_url,
        label_url: label_url,
        carrier: carrier,
        shipped_at: Time.now.utc.iso8601
      }.compact

      @client.v1.payment_intents.update(payment_intent_id, { metadata: metadata })
    end

    private

    def fetch_paid_sessions(created_after: nil)
      results = []
      total_complete = 0
      starting_after = nil

      loop do
        params = {
          status: 'complete',
          limit: PAGE_SIZE,
          expand: ['data.line_items', 'data.payment_intent']
        }
        params[:created] = { gte: created_after.to_i } if created_after
        params[:starting_after] = starting_after if starting_after

        page = @client.v1.checkout.sessions.list(params)
        total_complete += page.data.size
        results.concat(page.data.select { |session| session.payment_status == 'paid' })

        break unless page.has_more
        starting_after = page.data.last.id
      end

      puts "Stripe[#{@store_name}]: #{total_complete} complete session(s), #{results.size} paid"

      results
    end
  end
end
