#!/usr/bin/env python3
"""Regression checks for publication safety; only synthetic bytes and temp Git."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publication', Path(__file__).with_name('check-publication.py'))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class PublicationTests(unittest.TestCase):
    def inspect(self, path, data=b'public text', mode='100644'):
        with contextlib.redirect_stdout(io.StringIO()):
            return checks.inspect([(path, mode, data)])

    def testRejectsFinancialFilesAndMachinePaths(self):
        self.assertTrue(self.inspect('outputs/ledger.json'))
        self.assertTrue(self.inspect('Sources/notification-history.json'))
        self.assertTrue(self.inspect('mcp/client-config.json'))
        self.assertTrue(self.inspect('Sources/link', mode='120000'))
        private_path = b'/' + b'Users/' + b'example-person/file'
        self.assertTrue(self.inspect('README.md', private_path))

    def testRejectsCredentialsAndLiveCloudProjects(self):
        secret = b'ghp_' + b'A' * 32
        project = b'https://' + b'a' * 20 + b'.supabase.co'
        self.assertTrue(self.inspect('README.md', secret))
        self.assertTrue(self.inspect('README.md', project))
        self.assertTrue(self.inspect('README.md', b'person' + b'@' + b'private.invalid'))
        self.assertFalse(self.inspect('README.md', b'test@example.test'))
        self.assertFalse(self.inspect('scripts/GenerateIcon.swift', b'icon_128x128@2x.png'))

    def testPublicSupportContactIsAllowedOnlyInItsUISourceAndAppBinary(self):
        address = checks.PUBLIC_SUPPORT_EMAIL.encode()
        self.assertFalse(self.inspect('Sources/Mora/Support.swift', address))
        self.assertTrue(self.inspect('README.md', address))
        self.assertTrue(self.inspect('Sources/Mora/Support.swift', b'private' + b'@' + b'private.invalid'))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(checks.inspect([('Contents/MacOS/Mora', '100755', address)], bundle=True))
            self.assertTrue(checks.inspect([('Contents/Resources/private.txt', '100644', address)], bundle=True))

    def testExistingRemoteHistoryIsExcludedButAllOutgoingCommitsAreInspected(self):
        previous = checks.ROOT
        try:
            with tempfile.TemporaryDirectory(prefix='mora-publication-history-') as directory:
                checks.ROOT = Path(directory)
                def git(*args):
                    return subprocess.check_output(['git', '-C', directory, *args])
                git('init', '-q')
                git('config', 'user.name', 'Publication Test')
                git('config', 'user.email', 'test@example.test')
                file = checks.ROOT / 'README.md'
                def commit(data):
                    file.write_bytes(data)
                    git('add', 'README.md')
                    git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Synthetic fixture')
                    return git('rev-parse', 'HEAD').decode().strip()
                secret = b'ghp_' + b'A' * 32
                commit(secret)
                published = commit(b'public example')
                commit(b'new public example')
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertFalse(checks.inspect(checks.history_files('HEAD', published)))
                    self.assertTrue(checks.inspect(checks.history_files('HEAD')))
                # A secret added and then removed in the outgoing history still blocks upload.
                commit(secret)
                commit(b'public again')
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertTrue(checks.inspect(checks.history_files('HEAD', published)))
        finally:
            checks.ROOT = previous

    def testChecksGitIndexRatherThanUnstagedWorkingCopy(self):
        previous = checks.ROOT
        try:
            with tempfile.TemporaryDirectory(prefix='mora-publication-test-') as directory:
                checks.ROOT = Path(directory)
                subprocess.run(['git', 'init', '-q', directory], check=True)
                file = checks.ROOT / 'README.md'
                file.write_text('public example\n')
                subprocess.run(['git', '-C', directory, 'add', 'README.md'], check=True)
                file.write_bytes(b'ghp_' + b'A' * 32)
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(checks.inspect(checks.tracked(None)), [])
                subprocess.run(['git', '-C', directory, 'add', 'README.md'], check=True)
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertTrue(checks.inspect(checks.tracked(None)))
        finally:
            checks.ROOT = previous


if __name__ == '__main__':
    unittest.main()
