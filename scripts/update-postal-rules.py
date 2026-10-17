#!/usr/bin/env python3
"""Refresh the offline country-level postal-format snapshot. Never send user data."""
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import urllib.request

BASE = 'https://chromium-i18n.appspot.com/ssl-address/data'
ROOT = Path(__file__).resolve().parents[1]

def get(region):
    raw = urllib.request.urlopen(BASE + '/' + region, timeout=30).read()
    data = json.loads(raw)
    assert data['id'] == 'data/' + region
    return region, {'pattern': data.get('zip'), 'examples': data.get('zipex', ''),
                    'usesPostalCode': '%Z' in data.get('fmt', ''),
                    'sourceSHA256': hashlib.sha256(raw).hexdigest()}

if __name__ == '__main__':
    countries = json.load(urllib.request.urlopen(BASE, timeout=30))['countries'].split('~')
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        regions = dict(pool.map(get, countries))
    assert len(regions) > 200 and regions['JP']['pattern'] and regions['US']['pattern']
    output = {'source': BASE, 'retrieved': datetime.date.today().isoformat(),
              'scope': 'Country-level syntax only; not assigned-code or address verification.',
              'regions': regions}
    target = ROOT / 'Sources/MiledgeApplication/Resources/PostalRules.json'
    target.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    print(f'Saved {len(regions)} regions; {sum(bool(r["pattern"]) for r in regions.values())} patterns')
