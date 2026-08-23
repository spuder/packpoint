# TODO

## ShipStation (Jurassic Stacks) follow-ups

- [ ] Register a production `SHIPSTATION_API_KEY` secret in Dockhand (the
      key used while building this integration was the sandbox/test key
      from the DEV 1Password item - don't reuse it in production) plus the
      `STRIPE_STORE_1_SHIPSTATION_FROM_*` return-address secrets - see
      compose.yaml and README.md's "Shipping providers" section.
- [ ] Connect Jurassic Stacks' real carrier accounts (USPS/FedEx/UPS/DHL)
      in the ShipStation dashboard if they aren't already - PackPoint
      quotes/buys through whichever carriers are connected to the
      ShipStation account automatically (`GET /v2/carriers`), no separate
      config needed.
- [ ] Double check `ShippingApp::ShippingProviders::ShipStationProvider::CARRIER_CODE_FAMILIES`
      against Jurassic Stacks' actual connected carriers once known (it was
      built/verified against a sandbox account's `stamps_com`/`ups`/`fedex`
      carrier_codes) - a carrier connected under a `carrier_code` not in
      that table just won't show up in quotes until the table's extended.

## International shipping follow-ups

- [ ] Fill in `config/customs_catalog.yml` with real Tindie SKUs (HS tariff
      number, origin country, customs description, optional value) - it
      ships empty, so every Tindie product currently shows up with blank,
      required customs fields in the international ship panel.
- [ ] Add `hs_tariff_number` / `customs_origin_country` / `customs_description`
      (and optionally `customs_value`) metadata to Stripe Products, for any
      that don't have it yet - see README.md's "International shipping"
      section for the exact keys.
- [ ] Connect a DHL Express carrier account in EasyPost if you want DHL
      rates to show up alongside USPS/FedEx/UPS in the Check Price picker.
- [ ] Optionally set `CUSTOMS_SIGNER_NAME` in `.env` - defaults to the
      shipping store's return address name if unset.
