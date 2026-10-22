"""Adopted external numeric fingerprint: serial probes, local frozen scoring.

The source method ranks a closed reference set. Adoption is explicitly distinct
from independent TokenClock identity validation. No API is used for scoring.
"""
from __future__ import annotations
import base64
from functools import lru_cache
import hashlib
from importlib.resources import files
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

from .common import write_json, load_json, cancelled, digest
from .numeric_input import inspect_answer
from .transport import ProbeClient, ProbeStop, request_body

REFERENCE_SHA = '90ed23954fbfd485837cfffc9164188e73dd547564b45e677dfc09d7f69693ce'
SCHEMA = 'tokenclock-numeric-fingerprint/v1'
MODULES = {'fingerprint-core.mjs', 'positional.mjs', 'shared-detector.mjs', 'detector-codec.mjs'}


@lru_cache(maxsize=1)
def reference():
    raw = files('scripts.model_integrity.probes').joinpath('resources/numeric-reference-v1.json').read_bytes()
    if len(raw) > 8 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != REFERENCE_SHA:
        raise ValueError('数字指纹参考文件不完整，请重新安装应用。')
    value = json.loads(raw)
    if value['schema'] != 'tokenclock-external-numeric-reference/v1' or set(value['modules']) != MODULES:
        raise ValueError('数字指纹参考格式不兼容。')
    if len(value['prompts']) != 3 or len(value['bank']['models']) != value['model_count']:
        raise ValueError('数字指纹参考数量不一致。')
    return value


def overview():
    ref = reference()
    return {'method': 'Ikaleio/lm-detector', 'commit': ref['commit'], 'sha256': REFERENCE_SHA,
            'models': ref['model_count'], 'answers': ref['reference_answers'],
            'adoption': 'external_method', 'local_independent_identity_validation': False,
            'title': '数字串指纹已接入', 'summary': '采用外部参考库，本机自动比较，不调用模型评分。',
            'limitation': '给出参考中最接近的型号；库外型号仍可能接近某个已知型号。'}


def plan(config):
    cap = config.get('numeric_output_limit', 8192)
    if type(cap) is not int or not 8192 <= cap <= 262144:
        raise ValueError('数字指纹输出上限须为8192–262144；不会为节省费用压缩回答。')
    return [{'index': i + 1, 'repeat': 1, 'task': {'id': f'NFP01:{i+1}', 'layer': 'L2',
             'title': '数字串指纹 '+str(i+1), 'prompt': p['prompt'],
             'prompt_sha256': hashlib.sha256(p['prompt'].encode()).hexdigest(),
             'expected_count': p['expected_count'], 'output_limit': cap}}
            for i, p in enumerate(reference()['prompts'])]


def provider(config):
    value = dict(config.get('provider') or {})
    value.setdefault('reasoning_effort', 'low')
    return value


def ensure_runtime():
    from .browser_driver import runtime_paths
    value = runtime_paths({})
    if not value.get('node_path') or not Path(value['node_path']).is_file() or value.get('unavailable_reason'):
        raise ValueError('本地数字指纹运行组件不可用，请检查安装。')
    return value['node_path']


def _compute(outputs):
    ref = reference(); node = ensure_runtime()
    # Only this hash-pinned, reviewed numerical program runs. Answer strings
    # are JSON stdin, never code, filenames, shell arguments or module imports.
    with tempfile.TemporaryDirectory(prefix='tokenclock-numeric-') as folder:
        root = Path(folder)
        for name, code in ref['modules'].items():
            (root/name).write_text(code)
        (root/'detector.bin').write_bytes(base64.b64decode(ref['detector_base64'], validate=True))
        (root/'bank.json').write_text(json.dumps(ref['bank']))
        (root/'run.mjs').write_text('''import fs from 'node:fs';
import {decodeDetector} from './detector-codec.mjs';
import {analyzeSharedOutputs} from './shared-detector.mjs';
const bank=JSON.parse(fs.readFileSync(new URL('./bank.json',import.meta.url),'utf8'));
const detector=decodeDetector(fs.readFileSync(new URL('./detector.bin',import.meta.url)));
const input=JSON.parse(fs.readFileSync(0,'utf8'));
process.stdout.write(JSON.stringify(analyzeSharedOutputs(input,bank,detector)));
''')
        value = subprocess.run([str(node), '--max-old-space-size=256', str(root/'run.mjs')],
            input=json.dumps(outputs, ensure_ascii=False), text=True, capture_output=True,
            timeout=30, env={'PATH': '/usr/bin:/bin', 'TMPDIR': folder}, cwd=root)
        if value.returncode or len(value.stdout) > 1024 * 1024:
            raise ValueError('本地指纹计算未完成，原回答已保留。')
        return json.loads(value.stdout)


def assess(samples, declared_model='', source_scope='new_live_requests'):
    base = {'schema': SCHEMA, 'method': 'shared-detector-v2', 'reference': overview(),
            'identity_probability': None, 'independent_evidence_groups': 1,
            'model': None, 'status': 'insufficient', 'title': '本次无法判断具体型号。',
            'summary': '需要三份完整、有效的数字回答。', 'source_scope': source_scope,
            'declared_model': declared_model, 'input_checks': [], 'top_candidates': []}
    if len(samples) != 3:
        return base
    outputs = []
    for sample in samples:
        meta = sample.get('metadata', {})
        check = inspect_answer(sample['answer'], sample['expected_count'], finish_reason=meta.get('finish_reason'))
        if meta.get('completed') is not True or meta.get('truncated') or meta.get('unexpected_tools'):
            check['accepted'] = False; check['reasons'].append('completion_or_tool_use_not_eligible')
        base['input_checks'].append(check)
        outputs.append({'text': sample['answer'], 'expected_count': sample['expected_count']})
    if not all(c['accepted'] for c in base['input_checks']):
        base.update(status='invalid_input', summary='回答未完整完成或不符合数字题要求，本次不作型号判断。')
        return base
    result = _compute(outputs)
    ranked = result.get('results', [])
    if not ranked:
        return base
    base['top_candidates'] = [{k: r.get(k) for k in ('model', 'display_name', 'score')} for r in ranked[:5]]
    # Retain the original closed-set quantity only in evidence, never as an
    # identity percentage or a claim of independent local calibration.
    base['external_closed_set_probability'] = result.get('probability')
    base['external_probability_scope'] = 'reference_candidates_only'
    best = ranked[0]; name = best['display_name']; probability = result.get('probability')
    registered = {r['id'] for r in reference()['bank']['models']}
    declared = declared_model.split('/')[-1]
    base['declared_reference_covered'] = declared in registered
    if probability is None or probability < .75:
        other = ranked[1]['display_name'] if len(ranked) > 1 else '其他参考'
        base.update(status='ambiguous', title=f'暂时无法区分 {name} 与 {other}。',
                    summary='这次回答还没有形成清楚的型号倾向。')
    else:
        base.update(status='likely', model=best['model'], title=f'最可能是 {name}。',
                    summary='三份回答的数字偏好最接近这一型号的参考。')
        if declared and declared not in registered:
            base.update(status='reference_only', title=f'最相似的参考型号：{name}',
                        summary='填写的型号暂无参考，本次只显示最接近的已知型号。')
        elif declared and declared != best['model']:
            base['summary'] = f'与填写的 {declared_model} 不一致，建议核查渠道。'
    if source_scope == 'scripted_demo':
        base.update(status='demonstration', model=None, title='这是演示结果', summary='没有调用模型，用于展示数字指纹流程。')
    elif source_scope != 'new_live_requests':
        base['summary'] = '这是已有回答的比较结果，不是一次新的接口检测。'
    base['note'] = '采用外部数字指纹参考；最接近的型号不等于已经证实真实来源。'
    return base


def run(source_path, output_dir, config=None, cancelled_check=None, progress=None):
    config = dict(config or {}); reference(); ensure_runtime()
    if (config.get('assessment') or {}).get('enabled'):
        raise ValueError('数字指纹在本地评分，不需要模型辅助解析。')
    tasks = plan(config); out = Path(output_dir); out.mkdir(parents=True, exist_ok=True)
    p = provider(config); mode = config.get('transport_mode', 'replay')
    scope = {'live': 'new_live_requests', 'replay': 'recorded_response_replay',
             'demo': 'scripted_demo', 'artifact': 'imported_answers'}[mode]
    p.update(transport_mode=mode, purpose='target'); p.setdefault('api_format', 'responses')
    samples = []; client = None; stop = None
    if mode == 'artifact':
        pack = load_json(source_path)
        if pack.get('schema') != 'tokenclock-numeric-answer-set/v1' or len(pack.get('samples', [])) != 3:
            raise ValueError('数字指纹回答包需要三份原题和回答。')
        p['model'] = pack.get('requested_model', '')
        for cell, row in zip(tasks, pack['samples']):
            task = cell['task']
            if row.get('prompt') != task['prompt'] or not isinstance(row.get('answer'), str):
                raise ValueError('回答包题面与冻结数字题不一致。')
            samples.append({'task_id': task['id'], 'prompt_sha256': task['prompt_sha256'],
                'expected_count': task['expected_count'], 'answer': row['answer'],
                'metadata': {'completed': row.get('completed') is True, 'truncated': row.get('truncated') is True,
                             'finish_reason': row.get('finish_reason'), 'source_scope': scope}, 'record': {}})
    else:
        p['max_requests'] = min(3, int(p.get('max_requests', 3)))
        if mode == 'replay':
            pack = load_json(source_path)
            if pack.get('schema') != 'tokenclock-probe-replay/v1':
                raise ValueError('需要明确的请求回放文件。')
            p['replay_records'] = pack.get('records', [])
            p.setdefault('model', pack.get('requested_model', ''))
        elif mode == 'demo':
            from .l2 import _demo_record
            rng = random.Random(20261016); p.update(transport_mode='replay', model='scripted-demo-model')
            p['replay_records'] = [_demo_record(request_body(p, prompt=c['task']['prompt'], output_limit=c['task']['output_limit']),
                p['api_format'], ' '.join(str(rng.randint(1, 355)) for _ in range(c['task']['expected_count'])), c['index']) for c in tasks]
        client = ProbeClient(p, out/'transport', progress, cancelled_check)
        for cell in tasks:
            task = cell['task']
            try:
                cancelled(cancelled_check)
                body = request_body(p, prompt=task['prompt'], output_limit=task['output_limit'])
                answer = client.request(body, {'task_id': task['id'], 'prompt_sha256': task['prompt_sha256'],
                                               'fresh_single_question': True, 'system': None, 'tools': None, 'history': None})
                samples.append({'task_id': task['id'], 'prompt_sha256': task['prompt_sha256'],
                    'expected_count': task['expected_count'], 'answer': answer['text'], 'record': answer['record'],
                    'metadata': {'completed': answer['completed'], 'truncated': answer['limited'],
                         'unexpected_tools': bool(answer['tool_calls']), 'finish_reason': answer['finish_reason'],
                         'source_scope': scope, 'reasoning_effort': p.get('reasoning_effort'),
                         'output_limit': task['output_limit']}})
                write_json(out/'numeric-samples.json', samples)
            except (ProbeStop, InterruptedError) as exc:
                stop = {'code': getattr(exc, 'code', 'cancelled')}; break
    try:
        result = assess(samples, p.get('model', ''), scope)
    except (ValueError, subprocess.TimeoutExpired, OSError):
        result = {'schema': SCHEMA, 'status': 'local_error', 'model': None,
                  'title': '本次无法判断具体型号。', 'summary': '本地计算未完成，原回答已保留。',
                  'reference': overview(), 'identity_probability': None}
    accounting = client.accounting() if client else {'live_requests': 0, 'reported_cost_usd': '0', 'estimated_cost_usd': '0', 'pending_reserved_usd': '0'}
    report = {'schema': 'tokenclock-l2-run/v1', 'layer': 'L2', 'l2_method': 'numeric',
              'status': 'completed' if len(samples) == 3 and not stop else 'cancelled' if stop and stop['code']=='cancelled' else 'limited',
              'numeric_fingerprint': result, 'numeric_samples': samples, 'planned_requests': 0 if mode == 'artifact' else 3,
              'attempted_requests': len(client.records) if client else 0,
              'completed_answers': sum(s['metadata'].get('completed') is True and not s['metadata'].get('truncated') for s in samples),
              'accounting': accounting, 'stop': stop, 'source_scope': scope,
              'fresh_session_per_answer': True, 'no_history_tools_answers_feedback': True}
    write_json(out/'numeric-samples.json', samples); write_json(out/'l2-result.json', report)
    return report
