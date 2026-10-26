"""Measure a nationwide catalog using Mora's existing extraction rules.

Consumes a general Overture Parquet extract (names, types, confidence, IDs).
Uses a temporary on-disk table instead of retaining millions of source rows
in memory. Writes the same JSON/DEFLATE schema as build-places-catalog.py.
The input download and generated artifacts belong outside tracked source.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import runpy
import sqlite3
import time
import unicodedata
import zlib


def normalized_key(name):
    return ''.join(c for c in unicodedata.normalize('NFKD', name.casefold()) if c.isalnum())


def measure(args):
    import duckdb
    started = time.monotonic()
    rules = runpy.run_path(str(Path(__file__).with_name('build-places-catalog.py')))
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    working = output / 'deduplication.sqlite'
    if working.exists():
        raise ValueError('Choose an empty output directory; existing artifacts are never replaced')
    db = sqlite3.connect(working)
    db.execute('PRAGMA journal_mode=OFF')
    db.execute('PRAGMA synchronous=OFF')
    db.execute('PRAGMA cache_size=-65536')
    db.execute('''CREATE TABLE places(name TEXT NOT NULL, kind TEXT NOT NULL,
        id TEXT NOT NULL, category TEXT, sort_name TEXT NOT NULL, normalized TEXT NOT NULL,
        PRIMARY KEY(name,kind)) WITHOUT ROWID''')
    source = duckdb.connect(config={'threads': '2', 'memory_limit': '512MB'})
    result = source.execute('SELECT id,name,basic_category,taxonomy,confidence FROM read_parquet(?)', [str(args.input)])
    rows_seen = 0
    while rows := result.fetchmany(20_000):
        batch = []
        for identity, name, basic, taxonomy, confidence in rows:
            rows_seen += 1
            if (confidence or 0) < args.minimum_confidence:
                continue
            name = (name or '').strip()
            if not name or len(name) > 200 or re.search(r'\S+@\S+\.\S+', name):
                continue
            group = rules['merchant_group']({'taxonomy': taxonomy, 'basic_category': basic})
            batch.append((name, group or '', identity, (taxonomy or {}).get('primary'), name.casefold(), normalized_key(name)))
        db.executemany('INSERT OR IGNORE INTO places VALUES (?,?,?,?,?,?)', batch)
        db.commit()
        if rows_seen % 200_000 == 0:
            print(f'Processed {rows_seen:,} source rows', flush=True)
    print('Resolving ambiguous names', flush=True)
    db.execute('CREATE INDEX places_normalized_kind ON places(normalized,kind)')
    db.execute("DELETE FROM places WHERE kind='' AND NOT EXISTS(SELECT 1 FROM places AS other WHERE other.normalized=places.normalized AND other.kind<>'')")
    db.execute('CREATE INDEX places_order ON places(sort_name,kind,id)')
    db.commit()
    groups = Counter()
    destination = output / 'MerchantPlaces-US.deflate'
    compressor = zlib.compressobj(level=9, wbits=-15)
    plain_hash = hashlib.sha256()
    raw_bytes = 0
    compact_raw_bytes = 0
    compact_compressor = zlib.compressobj(level=9, wbits=-15)
    compact_hash = hashlib.sha256()
    compact_destination = output / 'MerchantPlaces-US-compact.deflate'
    count = 0
    header = {'schemaVersion': 1, 'region': args.region, 'release': args.release,
              'source': 'https://docs.overturemaps.org/guides/places/',
              'minimumConfidence': args.minimum_confidence}
    with destination.open('wb') as compressed, (output / 'MerchantPlaces-US.json').open('wb') as plain, compact_destination.open('wb') as compact_compressed, (output / 'MerchantPlaces-US-compact.json').open('wb') as compact_plain:
        def emit(value, compact_value=None):
            nonlocal raw_bytes, compact_raw_bytes
            payload = value.encode('utf-8')
            raw_bytes += len(payload)
            plain_hash.update(payload)
            plain.write(payload)
            compressed.write(compressor.compress(payload))
            compact_payload = payload if compact_value is None else compact_value.encode('utf-8')
            compact_raw_bytes += len(compact_payload)
            compact_hash.update(compact_payload)
            compact_plain.write(compact_payload)
            compact_compressed.write(compact_compressor.compress(compact_payload))
        emit(json.dumps(header, ensure_ascii=False, separators=(',', ':'))[:-1] + ',"places":[')
        def place(name, group, identity, category):
            nonlocal count
            if count:
                emit(',')
            emit(json.dumps({'name': name, 'group': group, 'id': identity, 'category': category}, ensure_ascii=False, separators=(',', ':')),
                 json.dumps({'name': name, 'group': group}, ensure_ascii=False, separators=(',', ':')))
            count += 1
            groups[group] += 1
        for name, kind, identity, category in db.execute('SELECT name,kind,id,category FROM places ORDER BY sort_name,kind,id'):
            place(name, kind or None, identity, category)
        overture_count = count
        if args.retail_input:
            for store in json.loads(args.retail_input.read_text()):
                name = (store.get('dba_name') or '').strip()
                if store.get('operation_type') != 'Store' or 'A' not in store.get('estab_type', '').split(','):
                    continue
                if re.search(r'\S+@\S+\.\S+', name) or not re.search(r'\b(market|markets|supermarket|supermarkets|grocery|groceries|deli|foods)\b', name, re.I):
                    continue
                place(name, 'groceries', 'ny-retail:' + store['license_number'], 'licensed_food_store')
        emit(']')
        if args.retail_input:
            emit(',"retailSource":"https://data.ny.gov/resource/9a8c-vfzj.json"')
        emit('}')
        compressed.write(compressor.flush())
        compact_compressed.write(compact_compressor.flush())
    db.close()
    source.close()
    metadata = {'release': args.release, 'region': args.region, 'minimumConfidence': args.minimum_confidence,
                'sourceRows': rows_seen, 'overtureRecords': overture_count, 'retailRecords': count-overture_count,
                'totalRecords': count, 'groups': {str(k): v for k, v in groups.items()},
                'jsonBytes': raw_bytes, 'deflateBytes': destination.stat().st_size,
                'jsonSHA256': plain_hash.hexdigest(),
                'compactJsonBytes': compact_raw_bytes, 'compactDeflateBytes': compact_destination.stat().st_size,
                'compactJsonSHA256': compact_hash.hexdigest(), 'seconds': time.monotonic()-started}
    (output / 'measurement.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--retail-input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--region', default='United States')
    parser.add_argument('--release', required=True)
    parser.add_argument('--minimum-confidence', type=float, default=0.8)
    measure(parser.parse_args())
