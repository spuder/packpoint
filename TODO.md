# TODO

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
