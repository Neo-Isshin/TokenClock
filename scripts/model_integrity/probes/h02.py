"""Actual isolated-browser evaluation of a free-form three-step offline HTML."""
import hashlib
import re
import time
from pathlib import Path

from .browser_driver import check, run_driver, save, source_metadata


def extract_html(text):
    blocks = re.findall(r'^```(?:html)?\s*\n([\s\S]*?)^```\s*$', text, re.M | re.I)
    candidates = [b for b in blocks if re.search(r'<html\b', b, re.I)]
    if len(candidates) == 1:
        return candidates[0]
    if re.match(r'\s*(?:<!doctype[^>]*>\s*)?<html\b', text, re.I):
        return text
    raise ValueError('HTML extraction is ambiguous; provide one original HTML artifact')


def evaluate(source_path, output_dir, config=None, cancelled=None, progress=None):
    config = config or {}
    cancelled = cancelled or (lambda: False)
    started = time.monotonic()
    output = Path(output_dir)
    if output.is_symlink() or (output.exists() and any(output.iterdir())):
        raise ValueError('Refusing to replace existing evaluation evidence')
    if Path(source_path).stat().st_size > min(2 * 1024 * 1024, int(config.get('max_source_bytes', 1024 * 1024))):
        raise ValueError('Source exceeds bounded HTML limit')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.chmod(0o700)
    raw = Path(source_path).read_bytes()
    result = {'schema': 'tokenclock-task-result/v1', 'task_id': 'H02', 'variant': 'OA01',
              'status': 'limited', 'checks': [], 'source': source_metadata(raw, config),
              'execution': {'actor': 'evaluator', 'network_calls': 0, 'target_model_calls': 0,
                            'sandbox': 'new_disposable_chromium_profile_external_network_blocked'},
              'artifacts': [], 'limitations': [
                  'Actions and browser checks belong to the evaluator, not the target model.',
                  'Navigation uses actually observed DOM controls; no storage is injected and no candidate source is patched.',
                  'A missing recognizable control is unknown, not automatic model failure.',
                  'The test uses a stable isolated HTTP origin; file:// storage behavior may differ.']}
    try:
        if len(raw) > min(2 * 1024 * 1024, int(config.get('max_source_bytes', 1024 * 1024))):
            raise ValueError('Source exceeds bounded HTML limit')
        if cancelled():
            result['status'] = 'cancelled'
            return result
        html = extract_html(raw.decode('utf-8'))
        artifact = output / 'artifact.html'
        artifact.write_bytes(html.encode('utf-8'))
        artifact.chmod(0o600)
        result['source']['artifact_sha256'] = hashlib.sha256(artifact.read_bytes()).hexdigest()
        source_check=check('h02.original_source_preserved', 'pass', {'sha256': result['source']['artifact_sha256']}, 'H02-SOURCE',mandatory=False,dimension='来源声明')
        result['checks'].append(source_check)
        if progress:
            progress('h02_browser', '检查真实表单与关闭重开后的数据', .25)
        observed = run_driver('html', artifact, output, config, cancelled)
        if observed.get('driver_status')!='completed':
            result['checks'].append(check('h02.execution_complete','unknown',{'status':observed.get('driver_status'),'stop_reason':observed.get('stop_reason')},'H02-ENVIRONMENT',reason='The evaluator did not finish under the current runtime conditions.'))
        for row in observed.get('checks', []):
            result['checks'].append(check(row['id'], row['status'], row['observed'],
                'H02-RETENTION' if 'retention' in row['id'] or 'persistence' in row['id'] else 'H02-FLOW',
                evidence=[{'path': str(output / 'browser-result.json'), 'note': 'DOM observations and actual evaluator actions'}]))
        for identifier in ('h02.three_step_flow', 'h02.backward_retention', 'h02.forward_retention',
                           'h02.browser_restart_persistence', 'h02.completion_feedback'):
            if not any(c['id'] == identifier for c in result['checks']):
                result['checks'].append(check(identifier, 'unknown', None, 'H02-FLOW', reason=observed.get('error', observed.get('stop_reason', 'No complete browser observation'))))
        result['execution'].update(elapsed_seconds=observed.get('elapsed_seconds'), limits=observed.get('limits'),
            network_calls=observed.get('loopback_requests', 0), external_network_calls=0,
            sandbox=observed.get('network_sandbox',{'verified':False}),
            environment_inherited=False,blocked_request_count=len(observed.get('blocked_requests', [])), evaluator_action_count=len(observed.get('actions', [])))
        result['artifacts'] = [{'path': str(artifact), 'media_type': 'text/html', 'purpose': 'Unmodified extracted artifact'},
                              {'path': str(output / 'browser-result.json'), 'media_type': 'application/json', 'purpose': 'Actual actions, DOM snapshots, checks'}]
        result['artifacts'] += [{'path': p, 'media_type': 'image/png', 'purpose': 'Isolated browser state'} for p in observed.get('screenshots', [])]
        if observed.get('driver_status') in ('cancelled', 'unsupported'):
            result['status'] = observed['driver_status']
        elif any(c['status'] == 'fail' for c in result['checks']):
            result['status'] = 'failed'
        elif any(c['mandatory'] and c['status'] == 'unknown' for c in result['checks']):
            result['status'] = 'limited'
        else:
            result['status'] = 'completed'
        if observed.get('stop_reason'):
            result['limitations'].append('Stopped under limit: ' + observed['stop_reason'])
    except (ValueError, OSError, UnicodeError) as exc:
        result['checks'].append(check('h02.input_or_runtime', 'unknown', None, 'H02-ENVIRONMENT', reason=str(exc)))
    finally:
        result['execution']['elapsed_seconds'] = round(time.monotonic() - started, 4)
        save(output / 'task-result.json', result)
    return result
