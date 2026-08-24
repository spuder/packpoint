require 'uri'

module ShippingApp
  # Direct carrier tracking pages, keyed by ShippingService::QUOTED_CARRIERS'
  # family names - used instead of EasyPost's own tracker.public_url (which
  # redirects through an easypost.com-branded page) so a customer clicking
  # "Track your package" lands on USPS/FedEx/UPS/DHL's own site.
  #
  # Shared by ShippingService#buy_shipment (right after a label is bought,
  # so it always has a real carrier + tracking code) and App's
  # /confirm_shipped route when called from the Archive tab's "Resend
  # Shipped Email" (see views/_archived_orders.rhtml) - an order shipped
  # before this app tracked carrier/tracking_url only has a carrier + code
  # typed in by hand to work from, so this fills in the URL either way.
  module CarrierTrackingUrl
    TEMPLATES = {
      'usps' => 'https://tools.usps.com/go/TrackConfirmAction?tLabels=%s',
      'fedex' => 'https://www.fedex.com/fedextrack/?trknbr=%s',
      'ups' => 'https://www.ups.com/track?tracknum=%s',
      'dhl' => 'https://www.dhl.com/us-en/home/tracking.html?tracking-id=%s'
    }.freeze

    def self.build(carrier, tracking_code)
      template = TEMPLATES[carrier.to_s.downcase]
      return nil if template.nil? || tracking_code.to_s.empty?

      format(template, URI.encode_www_form_component(tracking_code))
    end
  end
end
