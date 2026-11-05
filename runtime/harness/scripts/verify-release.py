"""Bind a versions major to the exact fully validated source and signed artifact."""
from pathlib import Path
import importlib.util
import json
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('f_prepared_release', root/'ui/desktop/scripts/prepare-update.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
report_path = Path(sys.argv[1]).resolve(strict=True)
report = json.loads(report_path.read_text())
required = {'isolated-build', 'harness', 'layout', 'office', 'provider-tool-bridge', 'computer-use', 'cbi-deepseek-flash', 'self-check', 'signature'}
required.update('run-' + name + '-tests' for name in ['whiteboard', 'queue', 'plugin', 'file-browser', 'history-navigation', 'viewport', 'versions', 'project-mutation', 'update', 'project-stress', 'daily-paper', 'paper-media', 'gmail', 'browser'])
assert report['passed'] and required.issubset({suite['name'] for suite in report['suites']}), 'Full release validation is incomplete'
assert all(suite['passed'] and suite['exitCode'] == 0 for suite in report['suites']), 'A release suite failed'
assert report['sourceDigest'] == prepare.source_digest(), 'Source changed after validation'
artifact = report_path.parent.parent/'F.app'
assert report['artifactSHA256'] == prepare.helper.digest_tree(artifact), 'Artifact changed after validation'
model = json.loads((report_path.parent/'cbi.json').read_text())
assert model['passed'] and model['provider'] == 'cbi' and model['model'] == 'deepseek-v4.1-flash', 'Pinned real-model acceptance is missing'
print('Validated source and signed F artifact:', report['id'], 'suites:', len(report['suites']))
