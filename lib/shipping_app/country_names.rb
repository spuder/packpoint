module ShippingApp
  # Stripe only gives us an ISO-3166 country code (no country name), unlike
  # Tindie which provides both. This fills in a display name for the
  # countries we already know how to flag (see App::COUNTRY_FLAGS). Codes
  # outside this list still work fine - they just fall back to showing the
  # raw code instead of a name.
  COUNTRY_NAMES = {
    'US' => 'United States',
    'CA' => 'Canada',
    'GB' => 'United Kingdom',
    'PR' => 'Puerto Rico',
    'AU' => 'Australia',
    'AT' => 'Austria',
    'DE' => 'Germany',
    'ES' => 'Spain',
    'FR' => 'France',
    'PL' => 'Poland',
    'SG' => 'Singapore',
    'SK' => 'Slovakia',
    'SE' => 'Sweden',
  }.freeze
end
