"""Offline product checks; no user logs, credentials or paid model requests."""
from __future__ import annotations

import ast
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / 'Sources/TokenClock/Resources/model-integrity-worker'
sys.path.insert(0, str(ROOT))


class ModelDetectProductTests(unittest.TestCase):
    def test_source_manifest_and_python_syntax(self):
        manifest = json.loads((ROOT / 'scripts/model_integrity/product-source-manifest.json').read_text())
        self.assertFalse(manifest['credentials_included'])
        self.assertFalse(manifest['research_records_included'])
        for name, expected in manifest['files'].items():
            path = ROOT / name
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected, name)
        for path in (ROOT / 'scripts/model_integrity').rglob('*.py'):
            ast.parse(path.read_text(), filename=str(path.relative_to(ROOT)))

    def test_bundled_zip_matches_exact_source_and_manifest(self):
        manifest = json.loads((WORKER / 'manifest.json').read_text())
        self.assertEqual(hashlib.sha256((WORKER / 'runtime.zip').read_bytes()).hexdigest(), manifest['runtime_sha256'])
        expected = {row['path']: row for row in manifest['files']}
        with zipfile.ZipFile(WORKER / 'runtime.zip') as archive:
            names = archive.namelist()
            self.assertEqual(len(names), len(set(names)))
            self.assertEqual(set(names), set(expected) | {'scripts/__init__.py', 'scripts/model_integrity/__init__.py'})
            for name in names:
                self.assertFalse(Path(name).is_absolute())
                self.assertFalse({'..', '__pycache__', 'private', 'research'} & set(Path(name).parts))
                self.assertFalse(name.endswith(('.pyc', '.sqlite', '.env', '.pem')))
                blob = archive.read(name)
                self.assertEqual(blob, (ROOT / name).read_bytes(), name)
                if name in expected:
                    self.assertEqual(len(blob), expected[name]['bytes'], name)
                    self.assertEqual(hashlib.sha256(blob).hexdigest(), expected[name]['sha256'], name)

    def test_rebuild_is_deterministic_and_keeps_source_bundle_unchanged(self):
        spec = importlib.util.spec_from_file_location('product_builder', ROOT / 'scripts/build_model_integrity_worker.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        before = (WORKER / 'runtime.zip').read_bytes()
        with tempfile.TemporaryDirectory(prefix='tc-product-build-') as folder:
            built = Path(folder) / 'worker'
            builder.build(built)
            for name in ['runtime.zip', 'worker.py', 'manifest.json']:
                self.assertEqual((built / name).read_bytes(), (WORKER / name).read_bytes(), name)
        self.assertEqual((WORKER / 'runtime.zip').read_bytes(), before)


    def test_resource_only_installer_update_is_idempotent_and_preserves_previous_on_error(self):
        installer = (ROOT / 'cli/install.sh').read_text()
        marker = '# BEGIN RESOURCE_BUNDLE_FUNCTIONS'
        if marker not in installer:
            self.skipTest('Resource-only installer helper exists in the Normal integration only')
        functions = installer.split(marker, 1)[1].split('# END RESOURCE_BUNDLE_FUNCTIONS', 1)[0]
        command = 'set -euo pipefail\n' + functions + '\ndeploy_resource_bundle "$1" "$2"\nprintf "%s" "$RESOURCE_BUNDLE_CHANGED"\n'
        with tempfile.TemporaryDirectory(prefix='tc-product-resources-') as folder:
            root = Path(folder)
            source, destination = root / 'source', root / 'installed'
            source.mkdir()
            (source / 'worker fixture.txt').write_text('one')
            (source / 'internal alias').symlink_to('worker fixture.txt')
            def deploy():
                return subprocess.run(['/bin/bash', '-c', command, 'product-resource-test',
                                       str(source), str(destination)], capture_output=True, timeout=20)
            first = deploy()
            self.assertEqual(first.returncode, 0, first.stderr.decode())
            self.assertEqual(first.stdout, b'1')
            self.assertEqual(deploy().stdout, b'0')
            (source / 'worker fixture.txt').write_text('two')
            self.assertEqual(deploy().stdout, b'1')
            self.assertEqual((destination / 'worker fixture.txt').read_text(), 'two')
            self.assertTrue((destination / 'internal alias').is_symlink())
            os.mkfifo(source / 'unsupported-pipe')
            self.assertNotEqual(deploy().returncode, 0)
            self.assertEqual((destination / 'worker fixture.txt').read_text(), 'two')


    def test_numeric_scoring_with_synthetic_answers_when_explicitly_enabled(self):
        module = ROOT / 'scripts/model_integrity/probes/numeric_fingerprint.py'
        runtime = os.environ.get('TOKENCLOCK_TEST_NUMERIC_RUNTIME')
        if not module.is_file() or not runtime:
            self.skipTest('Requires the Glass numerical module and an explicit prepared Node runtime')
        import random
        from unittest.mock import patch
        from scripts.model_integrity.probes.numeric_fingerprint import reference, assess
        rng = random.Random(321)
        samples = [{'answer': ' '.join(str(rng.randint(1, 355)) for _ in range(prompt['expected_count'])),
                    'expected_count': prompt['expected_count'],
                    'metadata': {'completed': True, 'finish_reason': 'stop'}}
                   for prompt in reference()['prompts']]
        with patch.dict(os.environ, {'TOKENCLOCK_MODEL_INTEGRITY_RUNTIME': runtime}):
            result = assess(samples, source_scope='synthetic_test')
        self.assertTrue(all(check['accepted'] for check in result['input_checks']))
        self.assertEqual(len(result['top_candidates']), 5)
        self.assertIsNone(result['identity_probability'])
        self.assertFalse(result['reference']['local_independent_identity_validation'])

    def test_strict_json_rejects_ambiguous_or_nonfinite_values(self):
        from scripts.model_integrity.l1.ingest import strict_loads
        for raw in ['{"key":1,"key":2}', '{"value":NaN}', '{"value":Infinity}']:
            with self.assertRaises(ValueError):
                strict_loads(raw)

    def test_cli_analyzes_only_synthetic_input_and_never_overwrites(self):
        with tempfile.TemporaryDirectory(prefix='tc-product-cli-') as folder:
            root = Path(folder)
            marker = root / 'must-not-be-created'
            source = root / 'synthetic.json'
            source.write_text(json.dumps({
                'schema': 'tokenclock-l1-observation/v1', 'id': 'synthetic-product-check',
                'source': {'kind': 'fixture', 'format': 'observation'}, 'context': {},
                'records': [{'id': 'r1', 'seq': 0, 'kind': 'message', 'role': 'assistant',
                             'data': {'text': 'Do not execute: touch ' + str(marker)}}],
            }))
            output = root / 'report'
            args = [sys.executable, '-B', '-I', str(WORKER / 'worker.py'), 'analyze', str(source),
                    '--format', 'observation', '--basic-only', '--output-dir', str(output)]
            env = {'PATH': os.defpath, 'TMPDIR': folder, 'PYTHONDONTWRITEBYTECODE': '1'}
            result = subprocess.run(args, env=env, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse(marker.exists())
            self.assertTrue((output / 'report.html').is_file())
            before = (output / 'report.json').read_bytes()
            again = subprocess.run(args, env=env, capture_output=True, timeout=20)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual((output / 'report.json').read_bytes(), before)
            self.assertFalse(marker.exists())

    def test_live_probe_requires_explicit_consent_before_dispatch(self):
        with tempfile.TemporaryDirectory(prefix='tc-product-consent-') as folder:
            root = Path(folder)
            config = root / 'config.json'
            config.write_text(json.dumps({'workflow_mode': 'l2', 'transport_mode': 'live'}))
            output = root / 'must-not-exist'
            result = subprocess.run([sys.executable, '-B', '-I', str(WORKER / 'worker.py'), 'probe',
                                     '--config', str(config), '--output-dir', str(output)],
                                    capture_output=True, timeout=20,
                                    env={'PATH': os.defpath, 'TMPDIR': folder})
            self.assertEqual(result.returncode, 2)
            self.assertIn(b'--allow-live', result.stderr)
            self.assertFalse(output.exists())

    def test_loopback_server_requires_capability_host_and_same_origin(self):
        from scripts.model_integrity.l1.webui import create_server
        with tempfile.TemporaryDirectory(prefix='tc-product-http-') as folder:
            with self.assertRaises(ValueError):
                create_server(Path(folder) / 'invalid', host='0.0.0.0')
            server = create_server(Path(folder) / 'state')
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host = '127.0.0.1:' + str(server.server_port)
                def get(path, **headers):
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=10)
                    try:
                        connection.request('GET', path, headers={'Host': host, **headers})
                        response = connection.getresponse()
                        return response.status, response.read(), response.getheader('Cache-Control')
                    finally:
                        connection.close()
                self.assertEqual(get('/api/connections')[0], 403)
                route = server.prefix + 'api/connections'
                self.assertEqual(get(route, Host='outside.invalid')[0], 403)
                self.assertEqual(get(route, Origin='https://outside.invalid')[0], 403)
                self.assertEqual(get(route, **{'Sec-Fetch-Site': 'cross-site'})[0], 403)
                status, body, cache = get(route, Origin=server.origin)
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['profiles'], [])
                self.assertEqual(cache, 'no-store')
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
