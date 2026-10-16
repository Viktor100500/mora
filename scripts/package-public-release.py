#!/usr/bin/env python3
"""Create a release ZIP with no Finder metadata, plus a checksum."""
import hashlib
from pathlib import Path
import platform
import plistlib
import sys
import zipfile

bundle, output = map(Path, sys.argv[1:])
version = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
architecture = platform.machine()
output.mkdir(parents=True, exist_ok=True)
archive = output / f'Mora-{version}-macOS-{architecture}.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as target:
    for file in sorted(bundle.rglob('*')):
        if file.is_symlink():
            raise SystemExit('A release may not include symbolic links.')
        if file.is_file():
            target.write(file, file.relative_to(bundle.parent).as_posix())
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
checksum = archive.with_suffix('.zip.sha256')
checksum.write_text(f'{digest}  {archive.name}\n')
print(f'Release: {archive}')
print(f'SHA-256: {digest}')
