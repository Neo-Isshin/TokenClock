"""Local Codex adapter. No key extraction, HTTP proxy, resume or identity calibration.

The native app supplies its configured CODEX_HOME to the worker. Codex owns auth.
Discovery starts no thread/turn. Each probe starts a separate ephemeral thread.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

from .common import write_json, digest, archive_evidence

SCHEMA = 'tokenclock-codex-local/v1'
MAX_WALL = 900
MAX_TURN = 300
MAX_IDLE = 120
MAX_TOKENS = 65536  # observed usage stop, not a server-enforced output ceiling
MAX_BYTES = 4 * 1024 * 1024
DISABLED = ('apps', 'plugins', 'hooks', 'memories', 'shell_tool', 'unified_exec',
            'multi_agent', 'multi_agent_v2', 'computer_use', 'browser_use',
            'in_app_browser', 'image_generation', 'code_mode_host', 'skill_search')


class CodexError(ValueError):
    pass


def installation():
    home = Path(os.environ.get('TOKENCLOCK_CODEX_HOME') or os.environ.get('CODEX_HOME') or Path.home()/'.codex').expanduser().resolve()
    if not home.is_dir():
        raise CodexError('没有找到本机 Codex 配置，请先安装并登录 Codex。')
    explicit = os.environ.get('CODEX_BINARY')
    candidates = [explicit] if explicit else [
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex',
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        '/Applications/ChatGPT.app/Contents/Resources/codex',
        '/Applications/Codex.app/Contents/Resources/codex',
        shutil.which('codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    binary = next((str(Path(p).expanduser().absolute()) for p in candidates if p and os.path.isfile(os.path.expanduser(p)) and os.access(os.path.expanduser(p), os.X_OK)), None)
    if not binary:
        raise CodexError('没有找到可运行的 Codex，请先安装或更新 Codex。')
    return binary, str(home)


class RPC:
    """Bounded stdio JSON-RPC; stderr and account/config responses are never logged."""
    def __init__(self, binary, home, cwd, cancelled=None):
        self.cancelled = cancelled or (lambda: False)
        self.events = queue.Queue(maxsize=512)
        self.sequence = 0
        self.pending = []
        env = dict(os.environ)
        env['CODEX_HOME'] = home
        env['PATH'] = env.get('PATH', '') + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
        # Avoid attaching to a parent Codex task or its tools/session.
        for key in ('CODEX_THREAD_ID', 'CODEX_TURN_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE'):
            env.pop(key, None)
        overrides = {'project_doc_max_bytes': 0, 'web_search': 'disabled',
                     'developer_instructions': '', 'features.skip_host_skill_discovery': True}
        overrides.update({'features.'+k: False for k in DISABLED})
        argv = [binary, 'app-server', '--listen', 'stdio://']
        for key, value in overrides.items():
            argv.extend(['-c', key+'='+json.dumps(value)])
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, cwd=cwd, env=env, start_new_session=True)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        try:
            self.call('initialize', {'clientInfo': {'name': 'tokenclock_model_check', 'title': 'TokenClock', 'version': '1'},
                                     'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized', 'params': {}})
        except BaseException:
            self.close(); raise

    def _read(self):
        try:
            while True:
                raw = self.process.stdout.readline(MAX_BYTES+1)
                if not raw: break
                if len(raw) > MAX_BYTES: raise CodexError('Codex 返回的数据超过本次读取上限。')
                try: value = json.loads(raw)
                except ValueError: raise CodexError('Codex 返回了无法读取的协议数据。') from None
                self.events.put_nowait(value)
        except (ValueError, queue.Full):
            try: self.events.put_nowait({'_error': True})
            except queue.Full: pass
        finally:
            try: self.events.put_nowait({'_closed': True})
            except queue.Full: pass

    def send(self, value):
        try:
            self.process.stdin.write(json.dumps(value, ensure_ascii=False).encode()+b'\n')
            self.process.stdin.flush()
        except (OSError, ValueError): raise CodexError('本机 Codex 连接已中断。') from None

    def receive(self, deadline):
        while time.monotonic() < deadline:
            if self.cancelled(): raise InterruptedError('用户已停止本次检测。')
            try: value = self.events.get(timeout=min(.1, max(.001, deadline-time.monotonic())))
            except queue.Empty: continue
            if value.get('_error'): raise CodexError('Codex 事件无法读取，原有记录已保留。')
            if value.get('_closed'): raise CodexError('本机 Codex 连接已中断。')
            if 'method' in value and 'id' in value:
                # This adapter never approves commands, patches, tools or login flows.
                self.send({'id': value['id'], 'error': {'code': -32601, 'message': 'Not supported by the probe client'}})
                raise CodexError('Codex 请求额外操作，已停止；本次仅允许回答题目。')
            return value
        raise CodexError('本次 Codex 操作超时，已停止等待。')

    def call(self, method, params=None, timeout=25):
        if self.cancelled(): raise InterruptedError('用户已停止本次检测。')
        self.sequence += 1; identifier = self.sequence
        self.send({'id': identifier, 'method': method, 'params': params or {}})
        end = time.monotonic()+timeout
        while True:
            value = self.receive(end)
            if value.get('id') == identifier:
                if 'error' in value: raise CodexError('Codex 未能完成 '+method+'；请检查登录、型号权限或客户端版本。')
                return value.get('result', {})
            self.pending.append(value)
            if len(self.pending) > 512: raise CodexError('Codex 事件过多，已停止本次操作。')

    def interrupt(self, thread_id, turn_id):
        try: self.send({'id': 'stop-'+uuid.uuid4().hex, 'method': 'turn/interrupt', 'params': {'threadId': thread_id, 'turnId': turn_id}})
        except CodexError: pass

    def close(self):
        try:
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try: self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL); self.process.wait(timeout=2)
        except (ProcessLookupError, OSError): pass
        for stream in (self.process.stdin, self.process.stdout):
            if stream:
                try: stream.close()
                except OSError: pass


def inspect(rpc, binary, home, cwd):
    account = rpc.call('account/read', {'refreshToken': False})
    config = rpc.call('config/read', {'includeLayers': False, 'cwd': cwd}).get('config', {})
    if account.get('requiresOpenaiAuth') and not account.get('account'):
        raise CodexError('Codex 尚未登录，请先在 Codex 中完成登录。')
    models = []; cursor = None
    for _ in range(10):
        page = rpc.call('model/list', {'limit': 100, 'includeHidden': False, **({'cursor': cursor} if cursor else {})})
        for row in page.get('data', []):
            name = row.get('model') or row.get('id')
            if isinstance(name, str) and 0 < len(name) <= 200:
                models.append({'id': name, 'name': row.get('displayName') or name,
                               'efforts': [x['reasoningEffort'] for x in row.get('supportedReasoningEfforts', []) if isinstance(x.get('reasoningEffort'), str)],
                               'default_effort': row.get('defaultReasoningEffort'), 'default': row.get('isDefault', False)})
        cursor = page.get('nextCursor')
        if not cursor: break
    if not models or cursor: raise CodexError('没有取得完整的 Codex 型号列表，请更新客户端后重试。')
    provider = config.get('model_provider') or 'openai'
    selected = config.get('model')
    acct = account.get('account') or {}
    # Bind all effective config privately by digest; never persist arbitrary config/auth.
    binding = digest({'binary': binary, 'home': home, 'account': acct, 'provider': provider,
                      'config': config})
    label = 'ChatGPT 已登录' if acct.get('type') == 'chatgpt' else 'Codex 已配置的连接'
    if acct.get('planType'): label += ' · '+str(acct['planType'])[:40]
    email = acct.get('email')
    if isinstance(email, str) and '@' in email:
        username, domain = email.rsplit('@', 1)
        label += ' · '+username[:1]+'***@'+domain[:100]
    return {'schema': SCHEMA, 'binding': binding, 'models': models, 'provider': provider,
            'account_label': label, 'selected_model': selected if selected in [m['id'] for m in models] else '',
            'billing': '使用此 Codex 账户的订阅额度或 API 额度；无法预估美元费用。',
            'home': home}, config


def discover():
    binary, home = installation()
    with tempfile.TemporaryDirectory(prefix='tokenclock-codex-discovery-') as cwd:
        rpc = RPC(binary, home, cwd)
        try: return inspect(rpc, binary, home, cwd)[0]
        finally: rpc.close()


def validate(config, authorized=True):
    cfg = config.get('codex')
    if not isinstance(cfg, dict): raise CodexError('请选择本机 Codex 和待测型号。')
    if authorized and config.get('allow_live') is not True: raise CodexError('请先确认使用本机 Codex 额度。')
    for key in ('binding', 'model'):
        if not isinstance(cfg.get(key), str) or not 0 < len(cfg[key]) <= 200: raise CodexError('请重新读取 Codex 登录与型号信息。')
    if config.get('assessment', {}).get('enabled'): raise CodexError('本机检测不调用模型评审。')
    method = cfg.get('method', 'numeric')
    if method not in {'numeric', 'behavior'}: raise CodexError('未知的本机测试方法。')
    return {'workflow_mode': 'codex', 'mode': 'external', 'transport_mode': 'codex',
            'allow_live': config.get('allow_live') is True,
            'codex': {k: cfg[k] for k in ('binding', 'model')} | {'method': method},
            'assessment': {'enabled': False}}


def plan(config):
    if config['codex']['method'] == 'numeric':
        from .numeric_fingerprint import plan as numeric_plan
        return numeric_plan({})
    from .catalog import l2_plan
    return l2_plan('openai', ['O05:A', 'O06:A', 'O07:A'], 2)


def preview(config):
    cfg = validate(config, authorized=False); count = len(plan(cfg))
    return {'schema': 'tokenclock-task-preview/v1', 'valid': True, 'local_only': False,
            'roles': [{'role': 'target', 'max_requests': count, 'sends': ['本次冻结题面'], 'budget_usd': None}],
            'errors': [], 'warnings': ['Codex 自带指令与 API 参考条件不同；本轮保存观察，不直接确认型号或计算身份概率。'],
            'total_budget_usd': None, 'total_upper_usd': None, 'model_requests': 0, 'creates_job': False,
            'billing_mode': 'codex_account', 'limits': {'requests': count, 'wall_seconds': MAX_WALL,
                'turn_seconds': MAX_TURN, 'idle_seconds': MAX_IDLE, 'observed_total_tokens': MAX_TOKENS,
                'server_output_token_cap': None}}


def turn(rpc, task, model, provider, effort, cwd, isolation, run_end, token_left, save, seen_threads):
    start = time.monotonic(); thread_id = turn_id = None
    record = {'task_id': task['id'], 'prompt': task['prompt'], 'prompt_sha256': task['prompt_sha256'],
              'requested_model': model, 'resolved_model': None, 'response_model': None,
              'provider_response_id': None, 'route': None, 'fallback': None, 'usage': None,
              'cost_usd': None, 'status': 'preparing', 'answer': '', 'events': [],
              'started_at': time.time(), 'conditions': {'transport': 'codex_app_server', 'fresh_thread': True,
              'history': None, 'feedback': None, 'base_instructions': 'codex_builtin', 'effort': effort,
              'output_token_limit': None, 'output_limit_note': 'App-server does not expose a per-turn hard output cap.',
              'isolation_overrides': {'disabled_features': list(DISABLED), 'project_doc_max_bytes': 0,
                  'web_search': 'disabled', 'disabled_skills': len(isolation.get('skills', {}).get('config', [])),
                  'disabled_mcp_servers': len(isolation.get('mcp_servers', {})), 'adapter_automatic_retries': 0,
                  'codex_internal_retries': 'provider_default_not_a_per_turn_control'}}}
    save(record)
    try:
        info = rpc.call('thread/start', {'model': model, 'modelProvider': provider, 'cwd': cwd,
            'ephemeral': True, 'approvalPolicy': 'never', 'sandbox': 'read-only',
            'allowProviderModelFallback': False, 'environments': [], 'selectedCapabilityRoots': [],
            'developerInstructions': '', 'config': isolation})
        thread_id = info.get('thread', {}).get('id')
        record.update(thread_id=thread_id, resolved_model=info.get('model'),
                      resolved_provider=info.get('modelProvider'), instruction_sources=info.get('instructionSources', []))
        if not thread_id or info.get('model') != model or info.get('modelProvider') != provider:
            raise CodexError('Codex 创建的会话与所选型号或来源不一致，尚未发题。')
        if info.get('thread', {}).get('ephemeral') is not True or thread_id in seen_threads:
            raise CodexError('Codex 未创建新的临时会话，尚未发题。')
        seen_threads.add(thread_id)
        # Some clients still list global AGENTS.md with a zero document limit.
        # A new thread alone must never be described as clearing personal rules.
        record['conditions']['personal_instructions_may_be_present'] = bool(info.get('instructionSources'))
        rpc.pending.clear()
        record['status'] = 'submitted'; record['submission_attempted'] = True; save(record)
        reply = rpc.call('turn/start', {'threadId': thread_id, 'model': model, 'effort': effort,
            'input': [{'type': 'text', 'text': task['prompt']}], 'approvalPolicy': 'never'}, timeout=25)
        turn_id = reply.get('turn', {}).get('id'); record['turn_id'] = turn_id
        if not turn_id: raise CodexError('Codex 未返回本次生成标识，已停止后续请求。')
        end = min(run_end, start+MAX_TURN); last_progress = time.monotonic(); characters = 0
        messages = {}; deltas = {}
        while True:
            if rpc.cancelled(): raise InterruptedError('用户已停止本次检测。')
            event = rpc.pending.pop(0) if rpc.pending else rpc.receive(min(end, last_progress+MAX_IDLE))
            method = event.get('method', ''); params = event.get('params', {})
            if params.get('threadId') != thread_id: continue
            if params.get('turnId', turn_id) != turn_id: continue
            if method == 'error': raise CodexError('Codex 报告生成错误，已停止；不会自动重发题目。')
            if method == 'item/agentMessage/delta':
                delta = params.get('delta', ''); characters += len(delta.encode())
                if characters > MAX_BYTES: raise CodexError('回答超过本次保存上限，已停止。')
                item_id = params.get('itemId', 'answer'); deltas[item_id] = deltas.get(item_id, '')+delta
                record['answer'] = '\n'.join(deltas.values()); last_progress = time.monotonic()
            elif method in {'item/reasoning/textDelta', 'item/reasoning/summaryTextDelta'}:
                last_progress = time.monotonic()  # event type only; no private reasoning text
            elif method in {'item/started', 'item/completed'}:
                item = params.get('item', {}); kind = item.get('type')
                if kind not in {'userMessage', 'agentMessage', 'reasoning', 'plan'}:
                    raise CodexError('检测到工具或额外操作，已停止；本次回答不作同条件比较。')
                if kind == 'agentMessage' and method == 'item/completed':
                    messages[item.get('id', 'answer')] = item
                    record['answer'] = '\n'.join(x.get('text', '') for x in messages.values() if x.get('phase') in (None, 'final_answer'))
                    last_progress = time.monotonic()
            elif method == 'thread/tokenUsage/updated':
                usage = params.get('tokenUsage', {}).get('total')
                if isinstance(usage, dict):
                    record['usage'] = usage
                    if usage.get('totalTokens', 0) >= token_left: raise CodexError('已达到本次观测 token 上限，停止后续生成。')
                # Usage/heartbeat alone is not answer progress.
            elif method == 'turn/completed':
                completed = params.get('turn', {})
                if completed.get('id') != turn_id: continue
                record['status'] = completed.get('status', 'unknown')
                record['finish_reason'] = record['status']
                if record['status'] != 'completed': raise CodexError('Codex 本次回答未完成，已停止后续题目。')
                if not record['answer'].strip(): raise CodexError('Codex 没有返回可用回答，已停止后续题目。')
                break
            if len(record['events']) < 1000 and method not in {'item/agentMessage/delta'}:
                record['events'].append({'method': method, 'thread_id': thread_id, 'turn_id': params.get('turnId'),
                                         'elapsed_seconds': round(time.monotonic()-start, 3)})
            save(record)
    except (CodexError, InterruptedError) as exc:
        record['status'] = 'cancelled' if isinstance(exc, InterruptedError) else 'limited'
        record['stop_reason'] = str(exc)
        if thread_id and turn_id: rpc.interrupt(thread_id, turn_id)
    finally:
        record['elapsed_seconds'] = round(time.monotonic()-start, 3); save(record)
        if thread_id:
            try: rpc.call('thread/unsubscribe', {'threadId': thread_id}, timeout=3)
            except (CodexError, InterruptedError): pass
    return record


def run_analysis(source_path, comparison_model=None, semantic_config=None, progress=None, cancelled=None, output_dir=None):
    cfg = validate(semantic_config); tasks = plan(cfg)
    out = Path(output_dir); out.mkdir(mode=0o700, parents=True, exist_ok=False)
    evidence = out/'evidence'; evidence.mkdir(mode=0o700)
    binary, home = installation(); records = []; stop = None; started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='tokenclock-codex-probes-') as cwd:
        rpc = RPC(binary, home, cwd, cancelled)
        try:
            current, effective = inspect(rpc, binary, home, cwd)
            if current['binding'] != cfg['codex']['binding']: raise CodexError('Codex 账户或配置已经改变，请重新读取并确认。')
            model = next((m for m in current['models'] if m['id'] == cfg['codex']['model']), None)
            if not model: raise CodexError('所选型号不在此 Codex 的型号列表中，请重新选择。')
            requested_effort = 'low' if cfg['codex']['method'] == 'numeric' else 'high'
            if requested_effort not in model['efforts']: raise CodexError('此型号不支持本题包的推理档位；没有自动降档或换型。')
            skills = rpc.call('skills/list', {'cwds': [cwd], 'forceReload': True})
            isolation = {'project_doc_max_bytes': 0, 'web_search': 'disabled', 'model_reasoning_effort': requested_effort,
                'developer_instructions': '', 'features': {k: False for k in DISABLED},
                'skills': {'config': [{'path': s['path'], 'enabled': False} for row in skills.get('data', []) for s in row.get('skills', []) if s.get('path')]},
                'mcp_servers': {k: {'enabled': False} for k in effective.get('mcp_servers', {})}}
            used = 0; seen_threads = set()
            for index, cell in enumerate(tasks):
                if cancelled and cancelled(): raise InterruptedError('用户已停止本次检测。')
                if time.monotonic()-started >= MAX_WALL or used >= MAX_TOKENS: break
                if progress: progress(stage='codex_probe', message=f'本机 Codex · 第 {index+1}/{len(tasks)} 题', fraction=index/len(tasks))
                file = evidence/f'{index+1:03d}-answer.json'
                row = turn(rpc, cell['task'], model['id'], current['provider'], requested_effort, cwd,
                           isolation, started+MAX_WALL, MAX_TOKENS-used, lambda value: write_json(file, value), seen_threads)
                row['repeat'] = cell['repeat']; records.append(row); write_json(file, row)
                used += (row.get('usage') or {}).get('totalTokens', 0)
                if row['status'] != 'completed': stop = row.get('stop_reason'); break
        finally: rpc.close()
    result = {'schema': SCHEMA, 'status': 'completed' if len(records) == len(tasks) and not stop else 'limited',
              'requested_model': cfg['codex']['model'], 'records': records, 'stop': stop,
              'planned_requests': len(tasks), 'attempted_requests': sum(r.get('submission_attempted') is True for r in records),
              'identity_probability': None, 'reference_eligible': False,
              'limitations': ['本地 Codex 指令环境与直接 API 参考不同，未验证其参考适用性。',
                              '新会话不继承原聊天；全局个人指令可能仍被加载，来源清单单独记录。',
                              '记录的是测试回合数；Codex 内部网络重试数和美元费用可能不可见。',
                              '会话返回型号是客户端声明，不是服务端权重证明。'],
              'accounting': {'live_requests': sum(r.get('submission_attempted') is True for r in records), 'reported_cost_usd': None,
                             'estimated_cost_usd': None, 'billing_mode': 'codex_account'}}
    if cfg['codex']['method'] == 'behavior':
        from .features import extract
        result['features'] = [extract(r['task_id'], r['answer'], {'completed': r['status'] == 'completed',
                'truncated': r['status'] != 'completed', 'conditions': r['conditions']}) for r in records]
    # Existing algorithm remains unchanged; its ranking is only a conditional observation.
    elif len(records) == 3 and all(r['status'] == 'completed' for r in records):
        from .numeric_fingerprint import assess
        try:
            result['reference_observation'] = assess([{'task_id': r['task_id'], 'answer': r['answer'],
                'expected_count': cell['task']['expected_count'],
                'metadata': {'completed': True, 'truncated': False}} for r, cell in zip(records, tasks)],
                cfg['codex']['model'], 'local_codex_conditions_not_validated')
        except (ValueError, OSError, subprocess.TimeoutExpired): result['reference_observation'] = {'status': 'local_compute_unavailable'}
    brief = {'schema': 'tokenclock-result-brief/v1', 'status': 'insufficient_evidence', 'title': '暂不能确认型号',
             'summary': f'已通过本机 Codex 完成 {sum(r["status"] == "completed" for r in records)}/{len(tasks)} 份回答。',
             'reasons': [], 'caveat': '这条本地调用路径还没有同条件参考；回答与运行记录已保存。',
             'next_action': {'kind': 'none'}}
    brief['display'] = {'schema': 'tokenclock-human-result/v1', 'status': brief['status'], 'title': brief['title'],
                        'summary': brief['summary'], 'note': brief['caveat'], 'tone': 'limited',
                        'suggestion': '可以保存本次回答与运行记录。', 'next_action': {'kind': 'none'}}
    report = {'schema': 'tokenclock-product-report/v1', 'workflow_mode': 'codex', 'result': result,
              'summary': {'status': result['status'], 'identity_status': 'not_authenticated'},
              'identity_probability': None, 'user_summary': {'brief': brief}}
    write_json(out/'report.json', report); write_json(out/'observation.json', result)
    page = '<!doctype html><meta charset="utf-8"><title>TokenClock · Codex</title><h1>'+brief['title']+'</h1><p>'+brief['summary']+'</p><p>'+brief['caveat']+'</p><details><summary>查看记录</summary><pre>'+html.escape(json.dumps(result, ensure_ascii=False, indent=2))+'</pre></details>'
    (out/'report.html').write_text(page)
    archive_evidence(evidence, out/'evidence.zip')
    return report
