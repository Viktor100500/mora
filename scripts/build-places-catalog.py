"""Build a local merchant index from a general Overture Places extract.

No merchant-specific rules or queries are used. Fetch a complete bounding box
with DuckDB 1.4.3 (optional developer dependency), then compile it offline.
See docs/merchant-categories.md for the dataset and reproduction command.
"""
import argparse
import json
import re
import unicodedata
import zlib
from collections import Counter
from pathlib import Path


def merchant_group(place):
    taxonomy = place.get('taxonomy') or {}
    labels = set(taxonomy.get('hierarchy') or [])
    labels.update(filter(None, [taxonomy.get('primary'), place.get('basic_category')]))
    if labels & {'grocery_store', 'supermarket', 'convenience_store', 'food_market',
                 'food_and_beverage_store', 'specialty_foods_store', 'specialty_food_store', 'produce_store',
                 'delicatessen', 'deli', 'greengrocer', 'butcher', 'fishmonger'}:
        return 'groceries'
    if labels & {'food_and_drink', 'restaurant', 'cafe', 'bakery', 'coffee_shop'}:
        return 'dining'
    if labels & {'pet_store', 'pet_service', 'veterinarian'}:
        return 'pets'
    if labels & {'health_care', 'healthcare', 'pharmacy'}:
        return 'health'
    if labels & {'lodging', 'hotel', 'travel_agency', 'airport'}:
        return 'travel'
    if labels & {'public_transport', 'public_transit', 'gas_station', 'fuel_station', 'parking',
                 'train_station', 'railway_station', 'bus_station', 'taxi', 'car_rental'}:
        return 'transport'
    if labels & {'shopping', 'retail'}:
        return 'shopping'
    if labels & {'education', 'school', 'university'}:
        return 'education'
    if labels & {'arts_and_entertainment', 'cinema', 'museum', 'amusement_park'}:
        return 'entertainment'
    return None


def compile_catalog(rows, region, release, minimum_confidence):
    places, seen = [], set()
    for place in rows:
        if (place.get('confidence') or 0) < minimum_confidence:
            continue
        name = (place.get('name') or '').strip()
        if not name or len(name) > 200 or re.search(r'\S+@\S+\.\S+', name):
            continue
        group = merchant_group(place)
        # Preserve unmapped types as ambiguity blockers, not forced Shopping.
        key = (name, group)
        if key in seen:
            continue
        seen.add(key)
        places.append({'name': name, 'group': group, 'id': place['id'],
                       'category': (place.get('taxonomy') or {}).get('primary')})
    places.sort(key=lambda p: (p['name'].casefold(), p['group'] or '', p['id']))
    # Keep unmapped names only when they can conflict with a classified name.
    # This avoids shipping hundreds of thousands of irrelevant business names.
    def key(name):
        return ''.join(c for c in unicodedata.normalize('NFKD', name.casefold()) if c.isalnum())
    classified = {key(p['name']) for p in places if p['group']}
    places = [p for p in places if p['group'] or key(p['name']) in classified]
    return {'schemaVersion': 1, 'region': region, 'release': release,
            'source': 'https://docs.overturemaps.org/guides/places/',
            'minimumConfidence': minimum_confidence, 'places': places}


def add_nyc_restaurants(catalog, rows):
    """Use the complete public DBA feed, never a query for an expense name.

    Existing names of other types remain in the index and block ambiguous matches.
    Only the public trading name is retained, not inspection findings or contacts.
    """
    seen = {(p['name'].casefold(), p['group']) for p in catalog['places']}
    for row in rows:
        name = (row.get('dba') or '').strip()
        key = (name.casefold(), 'dining')
        if len(name) < 4 or len(name) > 200 or re.search(r'\S+@\S+\.\S+', name) or key in seen:
            continue
        seen.add(key)
        catalog['places'].append({'name': name, 'group': 'dining', 'id': 'nyc-dba:' + name,
                                  'category': 'registered_restaurant'})
    catalog['restaurantSource'] = 'https://data.cityofnewyork.us/resource/43nn-pn8j.json'


def download(args):
    import duckdb
    args.extensions.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(config={'extension_directory': str(args.extensions.resolve()),
                                       'threads': '4', 'memory_limit': '1GB'})
    connection.execute('INSTALL httpfs')
    connection.execute('LOAD httpfs')
    connection.execute("SET s3_region='us-west-2'")
    if not all(c.isdigit() or c in '.-' for c in args.release):
        raise ValueError('Expected a numeric Overture release identifier')
    source = f's3://overturemaps-us-west-2/release/{args.release}/theme=places/type=place/*'
    xmin, ymin, xmax, ymax = args.bbox
    result = connection.execute('''SELECT id, names.primary AS name, basic_category, taxonomy, confidence
        FROM read_parquet(?) WHERE bbox.xmin BETWEEN ? AND ? AND bbox.ymin BETWEEN ? AND ?
        AND names.primary IS NOT NULL AND coalesce(operating_status,'') <> 'permanently_closed' ''',
        [source, xmin, xmax, ymin, ymax])
    columns = [column[0] for column in result.description]
    return [dict(zip(columns, row)) for row in result.fetchall()]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, help='Previously downloaded general Places JSON extract')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--region', required=True)
    parser.add_argument('--release', required=True)
    parser.add_argument('--minimum-confidence', type=float, default=0.8)
    parser.add_argument('--retail-input', type=Path, help='General NYS Retail Food Stores JSON download')
    parser.add_argument('--nyc-restaurants-input', type=Path, help='General NYC restaurant DBA JSON download')
    parser.add_argument('--bbox', type=float, nargs=4, metavar=('WEST', 'SOUTH', 'EAST', 'NORTH'),
                        default=[-74.35, 40.45, -73.65, 41.0])
    parser.add_argument('--extensions', type=Path, default=Path('.build/catalog-tools/extensions'))
    args = parser.parse_args()
    rows = json.loads(args.input.read_text()) if args.input else download(args)
    catalog = compile_catalog(rows, args.region, args.release, args.minimum_confidence)
    if args.retail_input:
        retail = json.loads(args.retail_input.read_text())
        for store in retail:
            name = (store.get('dba_name') or '').strip()
            # A food retail license alone does not turn pharmacies, fuel stations
            # and mixed department stores into grocery merchants.
            if store.get('operation_type') != 'Store' or 'A' not in store.get('estab_type', '').split(','):
                continue
            if re.search(r'\S+@\S+\.\S+', name) or not re.search(r'\b(market|markets|supermarket|supermarkets|grocery|groceries|deli|foods)\b', name, re.I):
                continue
            catalog['places'].append({'name': name, 'group': 'groceries',
                                      'id': 'ny-retail:' + store['license_number'], 'category': 'licensed_food_store'})
        catalog['retailSource'] = 'https://data.ny.gov/resource/9a8c-vfzj.json'
    if args.nyc_restaurants_input:
        add_nyc_restaurants(catalog, json.loads(args.nyc_restaurants_input.read_text()))
    encoded = json.dumps(catalog, ensure_ascii=False, separators=(',', ':')).encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Apple's Compression .zlib decoder uses a raw DEFLATE stream.
    args.output.write_bytes(zlib.compress(encoded, level=9, wbits=-15))
    print(json.dumps({'places': len(catalog['places']), 'groups': dict(Counter(p['group'] for p in catalog['places'])),
                      'bytes': args.output.stat().st_size, 'decodedBytes': len(encoded)}, ensure_ascii=False))
