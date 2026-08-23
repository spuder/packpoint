module ShippingApp
  # Raised for our own request-shape problems (e.g. an international buy
  # with no customs items) - as opposed to a shipping provider's own error
  # (EasyPost::Errors::EasyPostError, ShippingApp::ShippingProviders::CarrierError)
  # which covers the carrier/provider API rejecting a well-formed request.
  # app.rb maps this to a 422, same as a provider error.
  class ValidationError < StandardError; end
end
