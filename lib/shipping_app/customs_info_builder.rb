module ShippingApp
  # Builds the draft customs items shown (and made editable) in the
  # international ship panel in views/orders.rhtml, one per product line on
  # the order. These are what eventually become EasyPost customs_items - see
  # ShippingService#build_customs_info - but they're built here, at order
  # render time, so the panel can show/edit them *before* a rate is checked
  # or a label bought.
  #
  # Tindie has no per-product customs fields (see CustomsCatalog), so those
  # items are looked up by SKU/model and flagged `missing: true` when
  # nothing matches, rather than guessing an HS code. Stripe products carry
  # this as native Product metadata (see StripeProduct), so those are
  # rarely missing.
  class CustomsInfoBuilder
    def self.build(order, catalog: CustomsCatalog.instance)
      new(order, catalog).build
    end

    def initialize(order, catalog)
      @order = order
      @catalog = catalog
    end

    def build
      Array(@order.products).map { |product| build_item(product) }
    end

    private

    def build_item(product)
      meta = product_metadata(product)
      hs_tariff_number = meta[:hs_tariff_number].to_s.strip
      origin_country = meta[:origin_country].to_s.strip.upcase
      quantity = [product.qty.to_i, 1].max

      {
        description: meta[:customs_description].to_s.strip.empty? ? product.name.to_s : meta[:customs_description],
        hs_tariff_number: hs_tariff_number,
        origin_country: origin_country,
        quantity: quantity,
        value: total_value(product, meta, quantity).round(2),
        missing: hs_tariff_number.empty? || origin_country.empty?
      }
    end

    # Tindie products (TindieApi::TindieProduct) have no customs_metadata of
    # their own - look them up by SKU (falling back to model number) in the
    # hardcoded catalog. Stripe products (StripeProduct) already resolved
    # their own metadata when the order was fetched.
    def product_metadata(product)
      return product.customs_metadata || {} if product.respond_to?(:customs_metadata)

      @catalog.lookup(sku: product.respond_to?(:sku) ? product.sku : nil,
                       model: product.respond_to?(:model) ? product.model : nil)
    end

    # EasyPost's customs_item.value is the *total* declared value for the
    # whole quantity on that line, not a per-unit price (see
    # https://docs.easypost.com/guides/customs-guide) - so a catalog/
    # metadata override (a per-unit price, since that's what's naturally
    # configured once per SKU) gets multiplied by quantity here. Otherwise
    # this prefers the product's own line total (Tindie's price_total /
    # Stripe's line amount_total are already totals, not unit prices),
    # falling back to unit_price * quantity as a last resort.
    def total_value(product, meta, quantity)
      return meta[:value] * quantity if meta[:value] && meta[:value] > 0
      return product.price.to_f if product.price.to_f > 0

      unit_price = product.respond_to?(:unit_price) ? product.unit_price.to_f : 0
      unit_price * quantity
    end
  end
end
