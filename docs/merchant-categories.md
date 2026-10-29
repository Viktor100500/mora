# Merchant categories

Mora uses explicit rules and the user's previous category choices first. With automatic categories enabled, it also matches names locally against public reference data. It does not send purchase descriptions to a search or AI service.

The built-in brand vocabulary also recognizes `WHOLEFDS` as a Whole Foods grocery descriptor, followed by a branch code or store number. This abbreviation is documented in [Caltech's Data Logic Guide – Providers](https://www.imss.caltech.edu/documents/6555/Data_Logic_Guide-Providers.pdf), page 11. It matches a complete word rather than arbitrary substrings and is available immediately in Wallet booking and category suggestions on both Mac and iPhone. Existing uncategorized purchases on Mac are handled by the background categorizer; manual categories, rules and Undo choices retain priority.

## Regional places directory

Version 1.6.0 bundles 187,072 name/type records: 163,423 from the Overture Places release `2026-10-21.0`, 8,226 from the New York State Retail Food Stores open dataset downloaded on 2026-10-24, and 15,423 additional names from the complete NYC restaurant DBA feed downloaded on 2026-10-25 (24,588 names before cross-source deduplication). Repeated names/types are deduplicated; contact addresses accidentally used as business names are omitted. These are reference records, not a count of unique recognized merchants or a coverage guarantee.

- [Overture Places](https://docs.overturemaps.org/guides/places/) supplies business types, names and source identifiers. The extraction covers longitude -74.35 to -73.65 and latitude 40.45 to 41.0: New York City and nearby New Jersey communities. Permanently closed records are excluded; the existence-confidence floor is 0.8. Confidence measures whether the place exists, not whether its name matches a purchase.
- [NYS Retail Food Stores](https://data.ny.gov/Economic-Development/Retail-Food-Stores/9a8c-vfzj) supplies licensed grocery/deli/market names statewide. The subset requires operation type Store and establishment type A, and a grocery/deli/market descriptor in the registered trading name. A food retail license by itself does not cause pharmacies or mixed department stores to be classified as groceries.
- [NYC Restaurant Inspection Results](https://data.cityofnewyork.us/Health/DOHMH-New-York-City-Restaurant-Inspection-Results/43nn-pn8j) supplies public restaurant trading names, including branch names such as THISBOWL NOHO. Only names are retained; inspection findings, grades and contacts are excluded. A conflicting type in another source still blocks automatic assignment. Inclusion does not assert that an establishment remains open.
- Overture types are mapped to existing expense groups. Unmapped names that conflict with mapped names are retained as ambiguity blockers. The packaged index contains no dates, amounts, account names, locations from a user's device, or personal financial records.
- Source-derived type suffixes and bank processor prefixes are normalized. A one-word abbreviated name is accepted exactly, or with a numeric street address; it is not treated as an arbitrary prefix. Different mapped groups for the same name cause an abstention.

The first directory load runs during background category preparation. Existing uncategorized purchases are eligible automatically; manually assigned categories and explicit Undo choices are preserved. The automatic-categories toggle controls these lookups. The settings card states the region covered and links to the sources.

The regional directory is a bundled snapshot. It is updated by rebuilding the resource, not by downloading the world dataset on the user's Mac. Outside its region, the existing global brand catalogs and user history remain available; there is no claim of worldwide local-business coverage.

## Rebuilding the directory

Use Python 3.12 and the optional developer dependency `duckdb==1.4.3`. The application itself does not require Python, DuckDB, API keys, a subscription or a developer service account.

Download the general Retail Food Stores JSON endpoint with a limit covering the complete dataset, save it outside tracked source, then run:

```sh
python3 scripts/build-places-catalog.py \
  --retail-input /path/to/general-retail-stores.json \
  --nyc-restaurants-input /path/to/nyc-restaurant-names.json \
  --output Sources/FinanceCore/Resources/MerchantPlaces.deflate \
  --region 'New York metropolitan area' \
  --release 2026-10-21.0 \
  --bbox -74.35 40.45 -73.65 41.0
```

The public endpoint is `https://data.ny.gov/resource/9a8c-vfzj.json?$limit=50000`. Check the row count against the dataset metadata; paginate if it grows beyond the requested limit. The script fetches a complete geographic Overture slice and performs type mapping locally. `--input` accepts a previously downloaded general Overture JSON slice to avoid repeating the download. No query contains an individual merchant or an expense.

Fetch the restaurant names with `https://data.cityofnewyork.us/resource/43nn-pn8j.json?$select=distinct%20dba&$where=dba%20IS%20NOT%20NULL&$limit=50000&$order=dba`; check completeness before rebuilding. This is a general feed, not an expense lookup. NYC data terms: https://opendata.cityofnewyork.us/overview/#termsofuse.

`MerchantAliases.json` separately records a small set of source-backed spelling aliases. Each has public evidence; exact-only aliases cannot match arbitrary longer names. The Perk House coffee shop's compact spelling is one such exception, sourced from its official website. These aliases are distinct from the generated public directory.

The output is JSON compressed as raw DEFLATE, decoded using Foundation's `.zlib` algorithm. Source IDs and source taxonomy labels are kept for verification. For another region, change the bounds/region, regenerate the resource, and update the settings description and coverage documentation. Update `PlacesAttribution.txt` if sources or terms change.

The Overture data is under CDLA Permissive 2.0 and Apache 2.0 as applicable; Foursquare attribution and required license texts are included in `Sources/FinanceCore/Resources/PlacesAttribution.txt` and copied into the app's resource bundle. The NYS data is available under [Open NY Terms of Use](https://data.ny.gov/dataset/OPEN-NY-Terms-Of-Use/77gx-ii52).

## Brand and transit feeds

Merchant Studio and NSI are downloaded as general files. Each validated feed is cached separately for seven days in the user's Caches/Mora/MerchantCatalogs directory. On a failed or malformed refresh, the previous valid feed remains usable and refresh retries back off for 15 minutes. An outage never overwrites a valid cache with an error page. NSI includes transit network/operator names as well as brands; short network names are exact-only, with transit-specific payment suffix handling.

The categorizer shows whether sources are unavailable, a merchant is absent, or the ledger has no corresponding expense category. Misses are suppressed for one day in the current process, while new user history and category changes remain eligible immediately.

## Validation

All automated tests are offline and use temporary ledgers, synthetic purchases and public catalog fixtures. Public-source regression examples verify Chapel Deli, Wildberry, Laghman Express, 7th Street Burger and NetCost, plus NSI transit and ambiguity behavior. No test contacts a bank, a live ledger or the cloud database.
