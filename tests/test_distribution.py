"""Offline regression tests. Run: python3 -m unittest discover -s tests -v.

All Apple tools are mocked. No real credentials, keychains, builds or uploads
are used. A real macOS/Xcode build is still required before distribution.
"""

import base64
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, signal, stat, sys
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
home = pathlib.Path(os.environ['HOME'])
temp = pathlib.Path(os.environ['RUNNER_TEMP'])
with open(os.environ['MOCK_LOG'], 'a') as log:
    log.write(json.dumps([tool, args]) + '\n')
stage = args[0] if args else ''
if tool == 'uuidgen':
    print('test-keychain-password')
elif tool == 'security':
    if stage == 'list-keychains' and '-s' not in args:
        if not os.environ.get('EMPTY_KEYCHAINS'):
            print('    "' + str(home / 'login keychain-db') + '"')
    if stage == 'create-keychain':
        pathlib.Path(args[-1]).touch()
    if stage == 'import':
        cert = pathlib.Path(args[1])
        assert stat.S_IMODE(cert.stat().st_mode) == 0o600
        assert stat.S_IMODE(cert.parent.stat().st_mode) == 0o700
        assert '-A' not in args
        assert args.count('-T') == 2
        assert '/usr/bin/codesign' in args and '/usr/bin/security' in args
    if stage == 'delete-keychain':
        pathlib.Path(args[-1]).unlink(missing_ok=True)
elif tool == 'xcodebuild':
    assert all(s not in os.environ for s in
               ['P12_BASE64', 'P12_PASSWORD', 'PROFILE_BASE64'])
    profile = home / 'Library/MobileDevice/Provisioning Profiles/nanpure.mobileprovision'
    assert profile.read_bytes() == b'fake profile'
    assert stat.S_IMODE(profile.stat().st_mode) == 0o600
    assert not list(temp.glob('nanpure-signing.*/cert.p12'))
    if stage == 'archive':
        assert args[args.index('-configuration') + 1] == 'Release'
        assert args[args.index('-scheme') + 1] == 'Nanpure'
        assert 'CURRENT_PROJECT_VERSION=42' in args
    if stage == '-exportArchive':
        options = plistlib.loads(pathlib.Path(args[args.index('-exportOptionsPlist') + 1]).read_bytes())
        assert options == {'method': 'app-store', 'teamID': '4QLQBKXV72',
                           'signingStyle': 'manual', 'provisioningProfiles':
                           {'io.github.tsekimoto.nanpure': 'nanpure distribution'}}
        export = pathlib.Path(args[args.index('-exportPath') + 1])
        export.mkdir()
        for i in range(int(os.environ.get('IPA_COUNT', '1'))):
            (export / ('Nanpure %s.ipa' % i)).write_bytes(b'fake ipa')
elif tool == 'xcrun':
    key = home / '.appstoreconnect/private_keys/AuthKey_ABC123.p8'
    assert key.read_text() == 'fake api key\n'
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert 'ASC_API_KEY_P8' not in os.environ
    assert args[args.index('-f') + 1] == str(temp / 'nanpure.ipa')
    assert args[args.index('--apiKey') + 1] == 'ABC123'
if os.environ.get('MOCK_FAIL') == tool + ':' + stage:
    sys.exit(23)
if os.environ.get('MOCK_TERM') == tool + ':' + stage:
    os.kill(os.getppid(), signal.SIGTERM)
'''


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nanpure tests ')
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.home, self.runner, self.bin = (root / name for name in ('home', 'runner', 'bin'))
        for path in (self.home, self.runner, self.bin):
            path.mkdir()
        self.log = root / 'commands.jsonl'
        for tool in ('security', 'uuidgen', 'xcodebuild', 'xcrun'):
            path = self.bin / tool
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), RUNNER_TEMP=str(self.runner),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        MOCK_LOG=str(self.log), GITHUB_RUN_NUMBER='42',
                        P12_BASE64=base64.b64encode(b'fake certificate').decode(),
                        P12_PASSWORD='fake password',
                        PROFILE_BASE64=base64.b64encode(b'fake profile').decode(),
                        ASC_KEY_ID='ABC123', ASC_ISSUER_ID='fake issuer',
                        ASC_API_KEY_P8='fake api key')
        for name in ('MOCK_FAIL', 'MOCK_TERM', 'EMPTY_KEYCHAINS', 'IPA_COUNT'):
            self.env.pop(name, None)
        self.profile = self.home / 'Library/MobileDevice/Provisioning Profiles/nanpure.mobileprovision'
        self.key = self.home / '.appstoreconnect/private_keys/AuthKey_ABC123.p8'

    def run_script(self, name):
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts' / name)],
                                cwd=ROOT, env=self.env, text=True, capture_output=True)
        for secret in ('fake password', 'fake api key', 'test-keychain-password'):
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_clean(self, restored=False):
        self.assertFalse(list(self.runner.glob('nanpure-signing.*')))
        self.assertFalse(self.profile.exists())
        if restored:
            lists = [args for tool, args in self.commands() if tool == 'security' and args[0] == 'list-keychains' and '-s' in args]
            expected = [] if self.env.get('EMPTY_KEYCHAINS') else [str(self.home / 'login keychain-db')]
            self.assertEqual(lists[-1], ['list-keychains', '-d', 'user', '-s'] + expected)

    def test_archive_success(self):
        result = self.run_script('archive-app.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runner / 'nanpure.ipa').read_bytes(), b'fake ipa')
        self.assert_clean(restored=True)
        self.assertFalse(any(tool == 'xcrun' for tool, _ in self.commands()))

    def test_empty_original_keychain_list(self):
        self.env['EMPTY_KEYCHAINS'] = '1'
        result = self.run_script('archive-app.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean(restored=True)

    def test_archive_failures_cleanup(self):
        for stage in ('security:create-keychain', 'security:set-keychain-settings',
                      'security:unlock-keychain', 'security:import',
                      'security:set-key-partition-list', 'xcodebuild:archive',
                      'xcodebuild:-exportArchive'):
            with self.subTest(stage=stage):
                self.env['MOCK_FAIL'] = stage
                result = self.run_script('archive-app.sh')
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertFalse((self.runner / 'nanpure.ipa').exists())
                self.assert_clean(restored=stage.startswith('xcodebuild:'))

    def test_keychain_cleanup_failure_is_not_success(self):
        self.env['MOCK_FAIL'] = 'security:delete-keychain'
        result = self.run_script('archive-app.sh')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Signing cleanup failed', result.stderr)
        self.assert_clean(restored=True)

    def test_cancellation_cleanup(self):
        self.env['MOCK_TERM'] = 'xcodebuild:archive'
        result = self.run_script('archive-app.sh')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assert_clean(restored=True)

    def test_invalid_base64_cleanup(self):
        for name in ('P12_BASE64', 'PROFILE_BASE64'):
            with self.subTest(name=name):
                original = self.env[name]
                self.env[name] = '!not-base64!'
                self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
                self.assert_clean()
                self.env[name] = original

    def test_missing_signing_secret(self):
        del self.env['P12_PASSWORD']
        self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_wrong_ipa_count(self):
        for count in ('0', '2'):
            with self.subTest(count=count):
                self.env['IPA_COUNT'] = count
                self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
                self.assertFalse((self.runner / 'nanpure.ipa').exists())
                self.assert_clean(restored=True)

    def test_existing_profile_not_overwritten(self):
        self.profile.parent.mkdir(parents=True)
        self.profile.write_text('existing profile')
        self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
        self.assertEqual(self.profile.read_text(), 'existing profile')
        self.assertFalse(list(self.runner.glob('nanpure-signing.*')))

    def test_profile_symlink_rejected(self):
        self.profile.parent.mkdir(parents=True)
        target = self.home / 'must not create'
        self.profile.symlink_to(target)
        self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
        self.assertTrue(self.profile.is_symlink())
        self.assertFalse(target.exists())

    def test_stale_ipa_not_reused(self):
        path = self.runner / 'nanpure.ipa'
        path.write_text('old ipa')
        self.assertNotEqual(self.run_script('archive-app.sh').returncode, 0)
        self.assertEqual(path.read_text(), 'old ipa')
        self.assertEqual(self.commands(), [])

    def test_upload_success_failure_and_cancellation_remove_key(self):
        (self.runner / 'nanpure.ipa').write_bytes(b'fake ipa')
        for env, expected in (({}, 0), ({'MOCK_FAIL': 'xcrun:altool'}, 23),
                              ({'MOCK_TERM': 'xcrun:altool'}, 143)):
            with self.subTest(env=env):
                self.env.pop('MOCK_FAIL', None)
                self.env.pop('MOCK_TERM', None)
                self.env.update(env)
                result = self.run_script('upload-app.sh')
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertFalse(self.key.exists())

    def test_upload_rejects_missing_ipa(self):
        self.assertNotEqual(self.run_script('upload-app.sh').returncode, 0)
        self.assertFalse(self.key.exists())
        self.assertEqual(self.commands(), [])

    def test_upload_rejects_invalid_key_id(self):
        (self.runner / 'nanpure.ipa').touch()
        self.env['ASC_KEY_ID'] = '../unsafe'
        self.assertNotEqual(self.run_script('upload-app.sh').returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_upload_preserves_existing_key(self):
        (self.runner / 'nanpure.ipa').touch()
        self.key.parent.mkdir(parents=True)
        self.key.write_text('existing key')
        self.assertNotEqual(self.run_script('upload-app.sh').returncode, 0)
        self.assertEqual(self.key.read_text(), 'existing key')
        self.assertEqual(self.commands(), [])

    def test_upload_rejects_key_symlink(self):
        (self.runner / 'nanpure.ipa').touch()
        self.key.parent.mkdir(parents=True)
        target = self.home / 'must not create'
        self.key.symlink_to(target)
        self.assertNotEqual(self.run_script('upload-app.sh').returncode, 0)
        self.assertTrue(self.key.is_symlink())
        self.assertFalse(target.exists())
        self.assertEqual(self.commands(), [])

    def test_inspector_only_enabled_inside_debug(self):
        source = (ROOT / 'src/ナンプレ/WebView.swift').read_text()
        assignments = re.findall(r'webView\.isInspectable\s*=\s*true', source)
        self.assertEqual(len(assignments), 1)
        self.assertRegex(source, r'#if DEBUG\s+if #available\(iOS 16\.4, macOS 13\.3, \*\) \{\s+webView\.isInspectable = true\s+\}\s+#endif')


if __name__ == '__main__':
    unittest.main()
