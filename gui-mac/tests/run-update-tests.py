#!/usr/bin/env python3
"""Installer safety and rollback regression using disposable app bundles; never launches the real F."""
from pathlib import Path
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('update_helper', root/'Resources/update-helper.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='f-update-test-')
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name)
        self.id = 'abc-123'
        self.target = self.path/'installed/F.app'
        self.artifact = self.path/self.id/'F.app'
        for app, value in [(self.target,b'old'),(self.artifact,b'new')]:
            (app/'Contents/MacOS').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.fixture.F','CFBundleExecutable':'F'}))
            (app/'Contents/MacOS/F').write_bytes(value)
        self.manifest = self.path/'pending.json'
        self.data = {'version':1,'id':self.id,'artifact':str(self.artifact),'target':str(self.target),
            'announcement':'终端与安全更新已修复，原功能保留。','sha256':helper.digest_tree(self.artifact),
            'previous_sha256':helper.digest_file(self.target/'Contents/MacOS/F')}
        helper.atomic_json(self.manifest,self.data)
        self.raw_loader = helper.load_manifest

    def validate(self): return self.raw_loader(self.manifest,verify_signature=False)
    def test_valid_and_tampered_artifact(self):
        self.assertEqual(self.validate()['id'],self.id)
        (self.artifact/'Contents/MacOS/F').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError,'changed after validation'): self.validate()
    def test_changed_installed_version(self):
        (self.target/'Contents/MacOS/F').write_bytes(b'other update')
        with self.assertRaisesRegex(ValueError,'Installed application changed'): self.validate()
    def test_identity_and_announcement(self):
        self.data['announcement']='x'*101;helper.atomic_json(self.manifest,self.data)
        with self.assertRaisesRegex(ValueError,'1–100'): self.validate()
        self.data['announcement']='ok'
        info=self.artifact/'Contents/Info.plist';info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'wrong','CFBundleExecutable':'F'}))
        self.data['sha256']=helper.digest_tree(self.artifact);helper.atomic_json(self.manifest,self.data)
        with self.assertRaisesRegex(ValueError,'identity changed'):self.validate()
    def test_path_traversal(self):
        self.data['id']='../bad';helper.atomic_json(self.manifest,self.data)
        with self.assertRaisesRegex(ValueError,'Invalid update id'): self.validate()
    def loader(self,path): return self.raw_loader(path,verify_signature=False)
    def test_live_app_is_never_replaced(self):
        with mock.patch.object(helper,'load_manifest',side_effect=self.loader), mock.patch.object(helper.time,'monotonic',side_effect=[0,100]), mock.patch.object(helper.time,'sleep'):
            helper.install(self.manifest,os.getpid())
        self.assertEqual((self.target/'Contents/MacOS/F').read_bytes(),b'old')
        self.assertTrue((self.artifact/'Contents').exists())
    def test_success_keeps_bundle_directory_and_backup(self):
        inode=self.target.stat().st_ino
        def command(args,**kwargs):
            if args[0]=='/usr/bin/open':(self.path/self.id/'ready.json').write_text('ready')
            return subprocess.CompletedProcess(args,0)
        with mock.patch.object(helper,'load_manifest',side_effect=self.loader),mock.patch.object(helper.subprocess,'run',side_effect=command):
            helper.install(self.manifest,99999999)
        self.assertEqual(self.target.stat().st_ino,inode)
        self.assertEqual((self.target/'Contents/MacOS/F').read_bytes(),b'new')
        self.assertEqual((self.path/self.id/'previous.app/Contents/MacOS/F').read_bytes(),b'old')
        self.assertFalse(self.manifest.exists())
    def test_failed_start_rolls_back(self):
        helper.atomic_json(self.path/'resume.json',{'announcement':'new'})
        with mock.patch.object(helper,'load_manifest',side_effect=self.loader),mock.patch.object(helper.subprocess,'run',return_value=subprocess.CompletedProcess([],0)),mock.patch.object(helper.time,'monotonic',side_effect=[0,0,21]):
            with self.assertRaisesRegex(RuntimeError,'did not finish'):helper.install(self.manifest,99999999)
        self.assertEqual((self.target/'Contents/MacOS/F').read_bytes(),b'old')
        self.assertFalse(json.loads((self.path/self.id/'result.json').read_text())['success'])
        self.assertIn('恢复上一版本',json.loads((self.path/'resume.json').read_text())['announcement'])
    def test_in_app_build_cannot_relaunch_or_overwrite(self):
        env=dict(os.environ,F_APP_PID=str(os.getpid()),F_APP_BUNDLE=str(root/'F.app'))
        for option in ['--relaunch','--fresh','--no-whiteboard','--app=./F.app']:
            result=subprocess.run(['bash',str(root/'build.sh'),option],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('prepare-update.py',result.stderr)

    def test_native_deferred_quit_drains_plugin_save_callbacks(self):
        # Exercise the actual AppKit nested termination loop, not a mocked NSApplication.
        source = (root/'Core/ApplicationLifecycle.swift').read_text()
        source += r'''
final class QuitDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { FApplicationLifecycle.requestTermination() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        try! Data("saved".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
let app = NSApplication.shared
let delegate = QuitDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
'''
        swift = self.path/'main.swift'; swift.write_text(source)
        binary = self.path/'QuitTest'; marker = self.path/'saved'
        subprocess.run(['swiftc',str(swift),'-o',str(binary)],check=True,capture_output=True)
        subprocess.run([str(binary),str(marker)],check=True,timeout=8,capture_output=True)
        self.assertEqual(marker.read_text(),'saved')


if __name__=='__main__':unittest.main(verbosity=2)
