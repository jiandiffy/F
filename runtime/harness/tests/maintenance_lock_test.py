"""Targeted coordination tests only; never builds, publishes or restarts F."""
from pathlib import Path
from contextlib import contextmanager
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lock_file = ROOT/'runtime/harness/src/skills/maintenance_lock.py'
locks = load('maintenance_lock_tested', lock_file)
prepare = load('prepare_update_tested', ROOT/'ui/desktop/scripts/prepare-update.py')


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base/'source'
        self.source.mkdir()
        self.store = locks.Store(self.source, self.base/'metadata')

    def claim(self, owner, *paths):
        return self.store.operate(owner, 'claim', {'paths': list(paths)})

    def test_disjoint_plugins_and_overlapping_public_source(self):
        self.claim('one', 'ui/desktop/Plugins/A')
        self.claim('two', 'ui/desktop/Plugins/B')
        self.claim('file-owner', 'ui/desktop/Plugins/C/one.swift')
        with self.assertRaises(ValueError):
            self.claim('different-file-same-plugin', 'ui/desktop/Plugins/C/two.swift')
        for owner, paths in [('two', ['ui/desktop/Plugins/A/file.swift']), ('three', ['ui/desktop']), ('three', ['.'])]:
            with self.assertRaises(ValueError):
                self.claim(owner, *paths)
        self.claim('one', 'ui/desktop/Core/Shared.swift')
        with self.assertRaises(ValueError):
            self.claim('two', 'ui/desktop/Core/Shared.swift')
        # No TTL: even a long-paused owner keeps the reservation.
        self.assertIn('one', self.store.operate('reader', 'status')['leases'])

    def test_unauthorized_symlink_hardlink_and_escape(self):
        with self.assertRaises(ValueError):
            self.store.operate('legacy-session', 'pin', {'path': 'a', 'pid': os.getpid()})
        with self.assertRaises(ValueError):
            self.claim('one', '../outside')
        (self.source/'alias').symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.claim('one', 'alias/file')
        (self.source/'file').write_text('keep')
        os.link(self.source/'file', self.base/'hardlink')
        with self.assertRaises(ValueError):
            self.claim('one', 'file')

    def test_explicit_delegation_excludes_parent_and_siblings(self):
        self.claim('parent', 'plugin')
        self.store.operate('parent', 'delegate', {'childId': 'child', 'paths': ['plugin/a']})
        for owner, file in [('parent', 'plugin/a/x'), ('parent', 'plugin'), ('sibling', 'plugin/a/x')]:
            with self.assertRaises(ValueError):
                self.store.operate(owner, 'pin', {'path': file, 'pid': os.getpid()})
        with self.assertRaises(ValueError):
            self.store.operate('parent', 'release')
        with self.assertRaises(ValueError):
            self.claim('child', 'plugin/b')
        pin = self.store.operate('child', 'pin', {'path': 'plugin/a/x', 'pid': os.getpid()})
        with self.assertRaises(ValueError):
            self.store.operate('child', 'release')
        self.store.operate('child', 'unpin', pin)
        self.store.operate('child', 'release')
        pin = self.store.operate('parent', 'pin', {'path': 'plugin/a/x', 'pid': os.getpid()})
        self.store.operate('parent', 'unpin', pin)
        self.store.operate('parent', 'release')

    def test_pins_prevent_transfer_and_freeze(self):
        self.claim('one', '.')
        pin = self.store.operate('one', 'pin', {'path': 'a', 'pid': os.getpid()})
        with self.assertRaises(ValueError):
            self.store.operate('one', 'delegate', {'childId': 'child', 'paths': ['a']})
        with self.assertRaises(ValueError):
            with self.store.freeze('one'):
                self.fail('freeze while editing')
        self.store.operate('one', 'unpin', pin)
        with self.store.freeze('one'):
            for action, args in [('claim', {'paths': ['a']}), ('release', {}), ('pin', {'path': 'a', 'pid': os.getpid()})]:
                with self.assertRaises(ValueError):
                    self.store.operate('one', action, args)
            self.assertEqual(self.store.operate('one', 'status')['freeze']['owner'], 'one')
            # Publisher can write generated outputs; freeze is a lease gate, not an OS sandbox.
            for name in ['runtime/harness/dist/out', 'ui/desktop/.build/out', 'ui/desktop/Resources/packages/excalidraw/web/out']:
                output = self.source/name
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text('generated')
        self.assertNotIn('freeze', self.store.operate('one', 'status'))

    def test_freeze_never_steals_other_sessions(self):
        self.claim('one', 'a')
        self.claim('two', 'b')
        with self.assertRaises(ValueError):
            with self.store.freeze('one'):
                self.fail('stole lease')
        self.assertEqual(set(self.store.operate('one', 'status')['leases']), {'one', 'two'})
        self.store.operate('two', 'release')
        with self.store.freeze('one'):
            pass

    def test_publication_process_lock_covers_entire_lifetime(self):
        updates = self.base/'updates'
        command = [sys.executable, '-B', '-c',
                   'import runpy,sys; m=runpy.run_path(sys.argv[1]); '\
                   'ctx=m["publication_lock"](sys.argv[2]); ctx.__enter__(); print("acquired")',
                   str(lock_file), str(updates)]
        with locks.publication_lock(updates):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('prepare-update', result.stderr)
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertTrue((updates/'.prepare-update.lock').exists())

    def test_pending_no_clobber_even_if_created_after_lock(self):
        updates = self.base/'updates'
        with locks.publication_lock(updates):
            candidate = updates/'candidate.json'
            pending = updates/'pending.json'
            candidate.write_text('{"id":"new"}')
            pending.write_text('{"id":"existing"}')
            with self.assertRaises(FileExistsError):
                locks.publish_pending(candidate, pending)
            self.assertEqual(json.loads(pending.read_text())['id'], 'existing')
        with self.assertRaises(ValueError):
            with locks.publication_lock(updates):
                self.fail('overwrote published update')
        pending.unlink()
        pending.symlink_to(updates/'missing')
        with self.assertRaises(FileExistsError):
            locks.publish_pending(candidate, pending)
        pending.unlink()
        locks.publish_pending(candidate, pending)
        self.assertEqual(pending.read_text(), candidate.read_text())

    def test_concurrent_claims_have_only_one_winner(self):
        script = ('import runpy,sys; m=runpy.run_path(sys.argv[1]); '
                  'm["Store"](sys.argv[2],sys.argv[3]).operate(sys.argv[4],"claim",{"paths":["shared"]})')
        children = [subprocess.Popen([sys.executable, '-B', '-c', script, str(lock_file), str(self.source),
                                      str(self.base/'metadata'), owner], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for owner in ['one', 'two', 'three', 'four']]
        results = []
        for child in children:
            child.communicate(timeout=10)
            results.append(child.returncode)
        self.assertEqual(results.count(0), 1)
        self.assertEqual(len(self.store.operate('reader', 'status')['leases']), 1)

    def test_digest_covers_source_resources_not_generated_bundles(self):
        names = ['AGENTS.md', 'F_MAINTENANCE.md', 'ui/desktop/main.swift', 'ui/desktop/build.sh',
                 'ui/desktop/Info.plist', 'ui/desktop/PLUGIN_SPEC.md', 'ui/desktop/ARCHITECTURE.md', 'runtime/harness/README.md', 'runtime/pi/package.json', 'packages/excalidraw/web/package.json',
                 'packages/excalidraw/web/package-lock.json', 'runtime/harness/package.json', 'runtime/harness/package-lock.json', 'runtime/pi/package-lock.json',
                 'ui/desktop/Resources/update-helper.py', 'ui/desktop/Resources/Other/template.html']
        for name in names:
            file = self.source/name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('original')
        with patch.object(prepare, 'source', self.source):
            before = prepare.source_digest()
            for name in ['ui/desktop/Resources/whiteboard/bundle.js', 'ui/desktop/Resources/terminal/bundle.js', 'runtime/harness/dist/generated.js']:
                file = self.source/name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('generated')
            self.assertEqual(before, prepare.source_digest())
            for name in ['ui/desktop/Resources/update-helper.py', 'ui/desktop/Resources/Other/template.html']:
                file = self.source/name
                file.write_text('changed')
                self.assertNotEqual(before, prepare.source_digest())
                file.write_text('original')

    def test_digest_rejects_changed_source(self):
        with patch.object(prepare, 'source_digest', return_value='changed'):
            with self.assertRaises(RuntimeError):
                prepare.require_source_digest('before')

    def test_prepare_final_validation_digest_change_never_commits(self):
        # Exercise prepare's final commit path with ALL build/validation commands mocked.
        # This is not a native/model validation run and does not publish to real updates.
        target = self.base/'target.app'
        (target/'Contents/MacOS').mkdir(parents=True)
        import plistlib
        (target/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'F'}))
        (target/'Contents/MacOS/F').write_text('old')
        updates = self.base/'updates'
        updates.mkdir()
        args = types.SimpleNamespace(no_whiteboard=True, announcement='测试')
        current = ['before']
        def changed_during_manifest_validation(_path):
            current[0] = 'after'
        with patch.dict(os.environ, F_APP_BUNDLE=str(target)), \
             patch.object(prepare, 'source_digest', side_effect=lambda: current[0]), \
             patch.object(prepare.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)), \
             patch.object(prepare.helper, 'digest_tree', return_value='artifact'), \
             patch.object(prepare.helper, 'load_manifest', side_effect=changed_during_manifest_validation):
            with self.assertRaises(RuntimeError):
                prepare.prepare(args, updates)
        self.assertFalse((updates/'pending.json').exists())
        reports = list(updates.glob('*/validation/validation.json'))
        self.assertEqual(len(reports), 1)
        self.assertFalse(json.loads(reports[0].read_text())['passed'])
        self.assertFalse(list(updates.glob('.pending-*')))


if __name__ == '__main__':
    unittest.main()
