#!/usr/bin/env python3
"""Checks a signed iOS 27 automation before it is bundled with the iPhone app.

    python3 cloud/shortcuts/check_automation_file.py "Mora Bank SMS.shortcut"

The file name says which automation it is. The check opens the signature, prints
the signer and the trigger, and fails when the file is unsigned, lost its trigger
while signing, or has no Mora action of that automation. See READY-AUTOMATIONS.md.
"""

import plistlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLE = 'com.mora.finance.ios'
# File name → Mora App Intents the automation must contain.
EXPECTED = {
    'Mora Apple Pay': ['StartWalletPaymentIntent', 'AddWalletAmountIntent'],
    'Mora Wallet Notification': ['LogWalletNotificationIntent'],
    'Mora Bank SMS': ['LogBankMessageIntent'],
    'Mora Bank Notification': ['LogBankNotificationIntent'],
}


def contents(path):
    data = path.read_bytes()
    if data[:4] != b'AEA1':
        raise SystemExit(f'{path.name}: not a signed shortcut. Share it from Shortcuts or sign it with `shortcuts sign --mode anyone`.')
    size = struct.unpack('<I', data[8:12])[0]
    chain = plistlib.loads(data[12:12 + size])['SigningCertificateChain']
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        (work / 'leaf.der').write_bytes(chain[0])
        run = lambda *command: subprocess.run(command, check=True, capture_output=True, text=True).stdout
        (work / 'key.pem').write_text(run('openssl', 'x509', '-inform', 'der', '-in', str(work / 'leaf.der'), '-pubkey', '-noout'))
        signer = run('openssl', 'x509', '-inform', 'der', '-in', str(work / 'leaf.der'), '-noout', '-subject', '-enddate')
        run('aea', 'decrypt', '-i', str(path), '-o', str(work / 'payload.aar'), '-sign-pub', str(work / 'key.pem'))
        (work / 'payload').mkdir()
        run('aa', 'extract', '-i', str(work / 'payload.aar'), '-d', str(work / 'payload'))
        return signer.strip(), plistlib.loads((work / 'payload' / 'Shortcut.wflow').read_bytes())


def check(path):
    expected = EXPECTED.get(path.stem)
    if expected is None:
        raise SystemExit(f'{path.name}: unknown name, expected one of: ' + ', '.join(f'"{name}.shortcut"' for name in EXPECTED))
    signer, workflow = contents(path)
    triggers = [t.get('WFTriggerIdentifier') for t in workflow.get('WFWorkflowTriggers', [])]
    actions = [a.get('WFWorkflowActionIdentifier', '') for a in workflow.get('WFWorkflowActions', [])]
    mora = [a.removeprefix(BUNDLE + '.') for a in actions if a.startswith(BUNDLE + '.')]
    print(signer)
    print(f'{path.name}: triggers {triggers}, Mora actions {mora}')
    if not triggers:
        raise SystemExit(f'{path.name}: no automation trigger inside. Share it from an iPhone with iOS 27 or sign on macOS 27.')
    if mora != expected:
        raise SystemExit(f'{path.name}: expected Mora actions {expected}')
    print(f'{path.name}: OK')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for argument in sys.argv[1:]:
        check(Path(argument))
