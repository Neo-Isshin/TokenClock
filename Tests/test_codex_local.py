"""Offline transport and native-worker integration; never invoke a real model."""
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request, urlopen

from scripts.model_integrity.probes import codex_local as local
from scripts.model_integrity.probes.common import write_json


class FakeRPC:
    instances = []
    conflict = False
    tool = False
    fail_submit = False
    missing_usage = False
    personal_instructions = False
    cancel_after_start = False

    def __init__(self, binary, home, cwd, cancelled=None):
        self.calls = []; self.pending = []; self.n = 0; self.closed = False
        self.interrupts = []; self.cancelled = cancelled or (lambda: False)
        type(self).instances.append(self)

    def call(self, method, params=None, timeout=25):
        params = params or {}; self.calls.append((method, params))
        if method == 'account/read': return {'requiresOpenaiAuth': True, 'account': {'type': 'chatgpt', 'planType': 'pro'}}
        if method == 'config/read': return {'config': {'model': 'test-model', 'model_provider': 'openai',
            'mcp_servers': {'fixture': {'command': 'must-not-run'}},
            'model_providers': {'openai': {'name': 'OpenAI', 'experimental_bearer_token': 'PRIVATE_TEST_ONLY'}}}}
        if method == 'model/list': return {'data': [{'model': 'test-model', 'displayName': 'Test model',
            'defaultReasoningEffort': 'high', 'supportedReasoningEfforts': [{'reasoningEffort': x} for x in ['high','low']]}]}
        if method == 'skills/list': return {'data': [{'skills': [{'path': '/fixture/SKILL.md'}]}]}
        if method == 'thread/start':
            self.n += 1
            return {'thread': {'id': f'thread-{self.n}', 'ephemeral': True}, 'model': 'wrong-model' if self.conflict else params['model'],
                    'modelProvider': 'openai', 'instructionSources': ['/fixture/AGENTS.md'] if self.personal_instructions else []}
        if method == 'thread/unsubscribe': return {}
        if method == 'turn/start':
            if self.fail_submit: raise local.CodexError('模拟提交后连接中断')
            tid = params['threadId']; turn = 'turn-'+str(self.n)
            self.pending += [
                {'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn,
                    'item': {'id': 'message', 'type': 'commandExecution' if self.tool else 'agentMessage',
                             'phase': 'final_answer', 'text': '缓存像手边的抽屉。'}}},
                {'method': 'thread/tokenUsage/updated', 'params': {'threadId': tid, 'turnId': turn,
                    'tokenUsage': {'total': {'inputTokens': 20, 'outputTokens': 10, 'totalTokens': 30}}}},
                {'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}}]
            if self.missing_usage: self.pending = [x for x in self.pending if x['method'] != 'thread/tokenUsage/updated']
            if self.cancel_after_start: self.cancelled = lambda: True
            return {'turn': {'id': turn}}
        raise AssertionError(method)

    def receive(self, deadline): raise local.CodexError('模拟无进展超时')
    def interrupt(self, thread, turn): self.interrupts.append((thread, turn))
    def close(self): self.closed = True


class LocalCodexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        FakeRPC.instances = []; FakeRPC.conflict = False; FakeRPC.tool = False
        FakeRPC.fail_submit = False; FakeRPC.missing_usage = False
        FakeRPC.personal_instructions = False; FakeRPC.cancel_after_start = False
        self.p1 = patch.object(local, 'RPC', FakeRPC); self.p1.start(); self.addCleanup(self.p1.stop)
        self.p2 = patch.object(local, 'installation', return_value=('/fixture/codex', '/fixture/home')); self.p2.start(); self.addCleanup(self.p2.stop)
        self.info = local.discover()
        self.cfg = {'workflow_mode': 'codex', 'mode': 'external', 'allow_live': True,
                    'codex': {'model': 'test-model', 'binding': self.info['binding'], 'method': 'behavior'}}

    def run_job(self, config=None):
        return local.run_analysis(None, semantic_config=config or self.cfg, output_dir=self.root/'result')

    def test_discovery_never_starts_thread_or_turn_and_sanitizes(self):
        self.assertFalse(any(m.startswith(('thread/', 'turn/')) for m, _ in FakeRPC.instances[0].calls))
        self.assertNotIn('PRIVATE_TEST_ONLY', json.dumps(self.info))
        self.assertTrue(FakeRPC.instances[0].closed)

    def test_preview_never_launches_process_and_does_not_claim_free_usage(self):
        before = len(FakeRPC.instances); result = local.preview(self.cfg)
        self.assertEqual(len(FakeRPC.instances), before)
        self.assertFalse(result['local_only']); self.assertIsNone(result['total_budget_usd'])
        self.assertEqual(result['limits']['requests'], 6)

    def test_six_independent_serial_threads_keep_original_prompts(self):
        result = self.run_job(); rpc = FakeRPC.instances[-1]
        starts = [p for m, p in rpc.calls if m == 'thread/start']
        turns = [p for m, p in rpc.calls if m == 'turn/start']
        self.assertEqual(len(starts), 6); self.assertEqual(len({p['threadId'] for p in turns}), 6)
        self.assertTrue(all(p['ephemeral'] and p['sandbox'] == 'read-only' for p in starts))
        self.assertTrue(all(p['input'] == [{'type': 'text', 'text': c['task']['prompt']}] for p,c in zip(turns, local.plan(self.cfg))))
        self.assertEqual(result['result']['attempted_requests'], 6)
        self.assertIsNone(result['identity_probability'])
        self.assertFalse(result['result']['reference_eligible'])
        self.assertEqual(result['user_summary']['brief']['status'], 'insufficient_evidence')
        self.assertTrue((self.root/'result/evidence.zip').is_file())
        for file in (self.root/'result').rglob('*.json'):
            self.assertNotIn('PRIVATE_TEST_ONLY', file.read_text())
        self.assertEqual(starts[0]['config']['mcp_servers'], {'fixture': {'enabled': False}})
        self.assertEqual(starts[0]['config']['skills']['config'][0]['enabled'], False)
        self.assertTrue(rpc.closed)

    def test_changed_binding_rejected_before_thread_start(self):
        self.cfg['codex']['binding'] = 'changed'
        with self.assertRaisesRegex(local.CodexError, '已经改变'): self.run_job()
        self.assertFalse(any(m == 'thread/start' for m,_ in FakeRPC.instances[-1].calls))

    def test_unknown_model_not_substituted(self):
        self.cfg['codex']['model'] = 'missing'
        with self.assertRaisesRegex(local.CodexError, '重新选择'): self.run_job()
        self.assertFalse(any(m == 'turn/start' for m,_ in FakeRPC.instances[-1].calls))

    def test_resolved_model_conflict_stops_before_inference(self):
        FakeRPC.conflict = True; result = self.run_job()
        self.assertEqual(result['result']['attempted_requests'], 0)
        self.assertEqual(len(result['result']['records']), 1)
        self.assertEqual(result['result']['status'], 'limited')

    def test_tool_event_interrupts_without_next_question(self):
        FakeRPC.tool = True; result = self.run_job()
        self.assertEqual(result['result']['attempted_requests'], 1)
        self.assertEqual(len(FakeRPC.instances[-1].interrupts), 1)

    def test_missing_usage_and_cost_remain_unknown(self):
        FakeRPC.missing_usage = True; result = self.run_job()['result']
        self.assertTrue(all(r['usage'] is None for r in result['records']))
        self.assertIsNone(result['accounting']['estimated_cost_usd'])

    def test_global_instruction_sources_are_disclosed_not_called_clean(self):
        FakeRPC.personal_instructions = True; result = self.run_job()['result']
        self.assertTrue(result['records'][0]['conditions']['personal_instructions_may_be_present'])
        self.assertFalse(result['reference_eligible'])

    def test_cancel_keeps_partial_record_and_stops_next_question(self):
        FakeRPC.cancel_after_start = True; result = self.run_job()['result']
        self.assertEqual(len(result['records']), 1)
        self.assertEqual(result['records'][0]['status'], 'cancelled')
        self.assertTrue((self.root/'result/evidence/001-answer.json').is_file())
        self.assertEqual(len(FakeRPC.instances[-1].interrupts), 1)

    def test_unknown_submit_outcome_is_counted_and_never_retried(self):
        FakeRPC.fail_submit = True; result = self.run_job()['result']
        self.assertEqual(result['attempted_requests'], 1)
        self.assertEqual(sum(m == 'turn/start' for m,_ in FakeRPC.instances[-1].calls), 1)

    def test_consent_and_method_cannot_be_bypassed(self):
        self.cfg['allow_live'] = False
        with self.assertRaises(local.CodexError): local.validate(self.cfg)
        self.cfg['allow_live'] = True; self.cfg['codex']['method'] = 'shell'
        with self.assertRaises(local.CodexError): local.validate(self.cfg)

    def test_worker_routes_and_saved_report_use_same_local_path(self):
        from scripts.model_integrity.l1.webui import create_server
        server = create_server(self.root/'state'); thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        def request(route, body=None):
            req = Request(server.base_url+route, data=json.dumps(body).encode() if body is not None else None,
                          headers={'Content-Type': 'application/json'})
            with urlopen(req) as response: return json.load(response)
        self.assertEqual(request('api/local-codex')['schema'], local.SCHEMA)
        row = request('api/jobs', {'semantic_config': self.cfg, 'allow_external': True})
        import time
        for _ in range(200):
            job = request('api/jobs/'+row['id'])
            if job['status'] not in {'queued','running'}: break
            time.sleep(.01)
        self.assertEqual(job['status'], 'completed', job)
        report = request('reports/'+row['id']+'/report.json')
        self.assertEqual(report['workflow_mode'], 'codex')
        self.assertIsNone(report['identity_probability'])
        self.assertEqual(report['user_summary']['brief']['title'], '暂不能确认型号')
        with self.assertRaises(ValueError): server.manager.resume(row['id'], semantic_config=self.cfg, allow_external=True)


class WireTests(unittest.TestCase):
    def test_real_stdio_handshake_error_and_owned_process_cleanup(self):
        import sys
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory)/'fake-codex'
            binary.write_text('#!'+sys.executable+'''\nimport sys,json
for line in sys.stdin:
 value=json.loads(line)
 if 'id' not in value:continue
 if value['method']=='failure':reply={'id':value['id'],'error':{'message':'PRIVATE_PROVIDER_DIAGNOSTIC'}}
 else:reply={'id':value['id'],'result':{'ok':True}}
 print(json.dumps(reply),flush=True)
''')
            binary.chmod(0o700)
            rpc = local.RPC(str(binary), directory, directory)
            try:
                self.assertTrue(rpc.call('ping')['ok'])
                with self.assertRaises(local.CodexError) as error: rpc.call('failure')
                self.assertNotIn('PRIVATE_PROVIDER_DIAGNOSTIC', str(error.exception))
            finally: rpc.close()
            self.assertIsNotNone(rpc.process.poll())


if __name__ == '__main__': unittest.main()
