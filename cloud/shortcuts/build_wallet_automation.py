#!/usr/bin/env python3
"""Builds the Mora Apple Pay automation for iOS 27.

iOS 27 keeps an automation's trigger inside the shortcut (`WFWorkflowTriggers`)
and lets actions read the trigger's output directly. The file holds the Wallet
"Transaction" trigger with no cards chosen, then Mora's Start Wallet Payment and
Finish Wallet Payment wired to Merchant, Name, Card or Pass and Amount. It holds
no key or personal data, so one signed file serves every user.

    zsh scripts/sign-wallet-automation.sh

The script builds the file, signs it with `shortcuts sign --mode anyone` and
checks the result with `--verify`. Sign it on macOS 27 with the Mora service
Apple ID, not a personal one: the signature carries the signer's share record.
macOS 26 drops `WFWorkflowTriggers` when signing (checked 8 Nov 2026), and
`--verify` rejects such a file. A signature lasts about a year; re-sign before
it expires. iOS imports the automation switched off.
"""

import argparse
import plistlib
import struct
import subprocess
import tempfile
import uuid
from pathlib import Path

BUNDLE = 'com.mora.finance.ios'
TRIGGER = 'WFWalletTransactionTrigger'


def trigger_property(name, user_info=None):
    """A text field holding one property of the Wallet trigger's output."""
    aggrandizement = {'Type': 'WFPropertyVariableAggrandizement', 'PropertyName': name}
    if user_info:
        aggrandizement['PropertyUserInfo'] = user_info
    return {'Value': {'string': '￼', 'attachmentsByRange': {'{0, 1}': {
        'Type': 'TriggerOutput', 'TriggerIdentifier': TRIGGER, 'Aggrandizements': [aggrandizement]}}},
        'WFSerializationType': 'WFTextTokenString'}


def mora_action(intent, team, **parameters):
    return {'WFWorkflowActionIdentifier': f'{BUNDLE}.{intent}',
            'WFWorkflowActionParameters': {
                'AppIntentDescriptor': {'TeamIdentifier': team, 'BundleIdentifier': BUNDLE,
                                        'Name': 'Mora', 'AppIntentIdentifier': intent},
                'UUID': str(uuid.uuid5(uuid.NAMESPACE_URL, f'mora-wallet-automation/{intent}')).upper(),
                **parameters}}


def workflow(team):
    return {
        'WFWorkflowClientVersion': '5114.0.8.3',
        'WFWorkflowMinimumClientVersion': 900,
        'WFWorkflowMinimumClientVersionString': '900',
        'WFWorkflowIcon': {'WFWorkflowIconStartColor': -12365313, 'WFWorkflowIconGlyphNumber': 61440},
        'WFWorkflowTriggers': [{'WFTriggerIdentifier': TRIGGER,
                                'WFTriggerUUID': str(uuid.uuid5(uuid.NAMESPACE_URL, 'mora-wallet-automation/trigger')).upper(),
                                'WFTriggerSerializedParameters': {}}],
        'WFWorkflowActions': [
            mora_action('StartWalletPaymentIntent', team,
                        merchant=trigger_property('Merchant'),
                        name=trigger_property('Name', 'WFItemName'),
                        card=trigger_property('Card or Pass')),
            mora_action('AddWalletAmountIntent', team, amount=trigger_property('Amount')),
        ],
        'WFWorkflowInputContentItemClasses': [],
        'WFWorkflowOutputContentItemClasses': [],
        'WFWorkflowHasOutputFallback': False,
        'WFWorkflowHasShortcutInputVariables': True,
        'WFWorkflowImportQuestions': [],
        'WFQuickActionSurfaces': [],
        'WFWorkflowTypes': [],
    }


def verify(path):
    """Opens a signed file and checks that the trigger and both actions survived signing."""
    data = path.read_bytes()
    if data[:4] != b'AEA1':
        raise SystemExit(f'{path}: not a signed shortcut')
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
        content = plistlib.loads((work / 'payload' / 'Shortcut.wflow').read_bytes())
    triggers = [t.get('WFTriggerIdentifier') for t in content.get('WFWorkflowTriggers', [])]
    actions = [a['WFWorkflowActionIdentifier'] for a in content.get('WFWorkflowActions', [])]
    expected = [f'{BUNDLE}.StartWalletPaymentIntent', f'{BUNDLE}.AddWalletAmountIntent']
    if triggers != [TRIGGER]:
        raise SystemExit(f'{path}: the Transaction trigger is missing ({triggers}); sign on iOS 27 or macOS 27')
    if actions != expected:
        raise SystemExit(f'{path}: unexpected actions {actions}')
    print(signer.strip())
    print(f'{path}: trigger and both Mora actions are present')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--verify', type=Path, help='check a signed file instead of building one')
    # The Apple developer team that signs Mora: Shortcuts matches App Intents by bundle and team.
    parser.add_argument('--team', default='KZDJV245WR')
    args = parser.parse_args()
    if args.verify:
        verify(args.verify)
        return
    if not args.output:
        parser.error('--output is required')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(workflow(args.team), fmt=plistlib.FMT_BINARY))
    print(args.output)


if __name__ == '__main__':
    main()
