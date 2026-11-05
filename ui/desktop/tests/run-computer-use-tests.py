"""Exercise real desktop input only inside a disposable AppKit window."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--app', required=True, type=Path)
args = parser.parse_args()
binary = args.app / 'Contents/MacOS/F'

def request(value):
    result = subprocess.run([str(binary), '--computer-use'], input=json.dumps(value), text=True, capture_output=True, check=True, timeout=20)
    reply = json.loads(result.stdout)
    assert reply['ok'], reply
    return reply['value']

state = request({'action': 'state'})
assert state['accessibility'] and state['screenRecording'], 'Native desktop acceptance requires existing F accessibility and screen-recording permissions'
with tempfile.TemporaryDirectory(prefix='f-computer-native-') as temp:
    root = Path(temp)
    (root/'main.swift').write_text(r'''
import AppKit
final class Fixture: NSObject, NSApplicationDelegate {
    let field = NSTextField(frame: NSRect(x:40,y:120,width:330,height:30))
    let button = NSButton(frame:NSRect(x:40,y:60,width:150,height:32))
    var window: NSWindow!
    var timer: Timer?
    let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_COMPUTER_TEST_ROOT"]!)
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect:NSRect(x:160,y:220,width:450,height:230),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "F desktop acceptance"
        window.contentView!.addSubview(field)
        button.title = "Record fixture"; button.target = self; button.action = #selector(record)
        window.contentView!.addSubview(button)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        func point(_ view:NSView) -> [String:Double] {
            let point=window.convertPoint(toScreen:view.convert(NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil))
            return ["x":point.x,"y":NSScreen.main!.frame.maxY-point.y]
        }
        let data=try! JSONSerialization.data(withJSONObject:["field":point(field),"button":point(button)])
        try! data.write(to:root.appendingPathComponent("coordinates.json"),options:.atomic)
        timer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [self] _ in
            let state:[String:Any] = ["text":field.currentEditor()?.string ?? field.stringValue,"focused":field.currentEditor() != nil,"active":NSApp.isActive,"key":window.isKeyWindow]
            try! JSONSerialization.data(withJSONObject:state).write(to:root.appendingPathComponent("state.json"),options:.atomic)
        }
    }
    @objc func record() { try! field.stringValue.write(to:root.appendingPathComponent("result.txt"),atomically:true,encoding:.utf8) }
}
let app=NSApplication.shared, delegate=Fixture()
app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
''')
    subprocess.run(['swiftc', str(root/'main.swift'), '-o', str(root/'fixture')], check=True)
    fixture = subprocess.Popen([str(root/'fixture')], env=dict(os.environ, F_COMPUTER_TEST_ROOT=str(root)))
    try:
        deadline = time.monotonic() + 15
        while not (root/'coordinates.json').exists():
            assert fixture.poll() is None
            if time.monotonic() > deadline: raise TimeoutError('Fixture window did not open')
            time.sleep(.05)
        coordinates = json.loads((root/'coordinates.json').read_text())
        def wait_state(expected):
            deadline = time.monotonic() + 10
            state = {}
            while time.monotonic() < deadline:
                if (root/'state.json').exists():
                    state = json.loads((root/'state.json').read_text())
                    if all(state.get(key) == value for key, value in expected.items()): return
                time.sleep(.02)
            raise AssertionError('Desktop fixture did not settle: ' + json.dumps(state, ensure_ascii=False))
        wait_state({'text': '', 'active': True, 'key': True})
        request({'action': 'click', **coordinates['field']})
        wait_state({'focused': True, 'active': True, 'key': True})
        payload = 'F桌面测试' + '0123456789中文' * 4 + '🧪👩‍💻'
        request({'action': 'type', 'text': payload + 'x'})
        wait_state({'text': payload + 'x'})
        request({'action': 'key', 'keyCode': 51})
        wait_state({'text': payload})
        request({'action': 'move', **coordinates['button']})
        request({'action': 'click', **coordinates['button']})
        deadline = time.monotonic() + 10
        while not (root/'result.txt').exists():
            if time.monotonic() > deadline: raise TimeoutError('Native click did not reach the fixture')
            time.sleep(.05)
        assert (root/'result.txt').read_text() == payload
        request({'action': 'screenshot', 'path': str(root/'capture.png')})
        assert (root/'capture.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        assert (root/'capture.png').stat().st_size > 10000
        invalid = subprocess.run([str(binary), '--computer-use'], input='{"action":"click","x":-1,"y":-1}', text=True, capture_output=True)
        assert invalid.returncode != 0
        print('PASS: real desktop permission state, Unicode typing, Backspace, mouse move/click, screenshot and invalid coordinates')
    finally:
        fixture.terminate()
        fixture.wait(timeout=5)
