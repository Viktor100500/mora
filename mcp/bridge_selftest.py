"""Check the no-MCP import path with only the Python standard library and disposable data."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

BRIDGE = Path(__file__).resolve().parent.parent / '.build/debug/MoraBridge'


class NativeImportTests(unittest.TestCase):
    def testFirstRunSelectedRowsRetryAndAtomicFailure(self):
        with tempfile.TemporaryDirectory(prefix="mora-bridge-test ' ") as directory:
            def call(command, arguments=None, *, ok=True):
                process = subprocess.run([str(BRIDGE), '--data-dir', directory],
                                         input=json.dumps({'command': command, 'arguments': arguments or {}}),
                                         text=True, capture_output=True, timeout=30)
                response = json.loads(process.stdout)
                self.assertEqual(response['ok'], ok, response)
                self.assertEqual(process.returncode, 0 if ok else 1)
                return response.get('result', response)

            context = call('context')
            self.assertEqual(context['accounts'], [])
            self.assertFalse((Path(directory) / 'ledger.json').exists())
            account = {'name': 'Test account', 'currency': 'USD', 'opening_balance': '100', 'kind': 'checking'}
            self.assertEqual(call('create_account', account)['status'], 'created')
            self.assertEqual(call('create_account', account)['status'], 'already_exists')
            source = [{'date': context['today'], 'merchant': f'Test purchase {i}', 'amount': amount,
                       'currency': 'USD', 'account': 'Test account', 'category': 'Кафе и рестораны', 'type': 'expense'}
                      for i, amount in enumerate(['-3.20', '-9.99', '-6.30'], 1)]
            batch = {'request_id': 'selected-first-and-third', 'entries': [source[0], source[2]]}
            preview = call('preview_entries', batch)
            self.assertFalse(preview['saved'])
            self.assertEqual(preview['imported'], 2)
            self.assertEqual(call('list_entries')['total'], 0)
            written = call('add_entries', batch)
            self.assertTrue(written['saved'])
            self.assertEqual(written['imported'], 2)
            retry = call('add_entries', batch)
            self.assertEqual((retry['imported'], retry['duplicates']), (0, 2))
            entries = call('list_entries')['entries']
            self.assertEqual({e['merchant'] for e in entries}, {'Test purchase 1', 'Test purchase 3'})
            self.assertEqual(call('context')['accounts'][0]['balance'], '90.5')
            self.assertEqual(len(call('context')['import_history']), 1)
            invalid = dict(source[1], account='Missing account')
            call('add_entries', {'request_id': 'invalid', 'entries': [source[1], invalid]}, ok=False)
            self.assertEqual(call('list_entries')['total'], 2)
            call('add_entries', dict(batch, entries=[dict(source[0], amount='-50')]), ok=False)
            self.assertEqual(call('list_entries')['total'], 2)


if __name__ == '__main__':
    unittest.main()
