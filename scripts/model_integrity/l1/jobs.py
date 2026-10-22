"""One-worker local L1 jobs with fixed input snapshots and explicit recovery.

The queue never executes transcript commands or opens a network connection.
Only an injected analysis runner (normally pipeline.run_analysis) does analysis.
Recovered work is paused, including queued jobs, until explicitly resumed.
"""
from __future__ import annotations

from collections import deque
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import threading
import time
import uuid

from .render import redact
import zipfile

JOB_SCHEMA = 'tokenclock-l1-job/v1'
JOB_ID = re.compile(r'job-[a-f0-9]{32}\Z')
ACTIVE = {'queued', 'running', 'cancelling'}
TERMINAL = {'completed', 'cancelled', 'failed', 'interrupted', 'action_required'}
REQUIRED_REPORT_FILES = ('observation.json', 'report.json', 'report.html')
BILLING_STAGES = {'semantic_request_reserved', 'semantic_request_started',
                  'semantic_request_finished', 'semantic_request_failed'}
BILLING_ENUMS = {
    'billing_status': {'unsettled', 'settled_response_reported_cost', 'settled_configured_rate_estimate',
                       'unsettled_missing_usage_reservation_retained', 'not_dispatched_no_cost'},
    'finish_reason': {'stop', 'length', 'max_tokens', 'tool_calls', 'end_turn', 'stop_sequence',
                      'content_filter', 'completed', 'error', 'cancelled', 'function_call'},
    'error_category': {'budget_or_request_limit', 'input_limit_no_complete_turn_fits', 'invalid_output_limit',
                       'invalid_input_limit', 'response_truncated', 'invalid_json_response',
                       'cancelled_before_dispatch', 'cancelled_after_dispatch', 'interface_timeout',
                       'interface_failure', 'invalid_backend_configuration'},
}


def _money(value):
    if value is None:
        return None
    if isinstance(value, bool) or len(str(value)) > 64:
        raise ValueError('Invalid billing amount')
    try:
        amount = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError('Invalid billing amount') from exc
    if not amount.is_finite() or amount < 0 or amount > Decimal('1000000'):
        raise ValueError('Invalid billing amount')
    return str(amount)


def _billing_event(raw, attempt):
    stage = raw.get('stage')
    if stage not in BILLING_STAGES:
        return None
    event = {'stage': stage, 'attempt': attempt, 'recorded_at': _now()}
    for key in ('reserved_cost_usd', 'actual_cost_usd', 'estimated_cost_usd'):
        if key in raw:
            try:
                event[key] = _money(raw[key])
            except ValueError:
                event[key + '_invalid'] = True
    for key in ('request_count', 'requests', 'input_token_admission_upper_bound', 'max_output_tokens'):
        if type(raw.get(key)) is int and 0 <= raw[key] <= 10000000:
            event[key] = raw[key]
    for key in ('reservation_released', 'cancelled', 'budget_bound_exceeded'):
        if type(raw.get(key)) is bool:
            event[key] = raw[key]
    for key in ('billing_status', 'finish_reason', 'error_category'):
        value = raw.get(key)
        if value is None and key in raw:
            event[key] = None
        elif isinstance(value, str) and value in BILLING_ENUMS[key]:
            event[key] = value
        elif key in raw:
            event[key + '_unrecognized'] = True
    usage = raw.get('usage')
    if isinstance(usage, dict):
        safe = {}
        for key in ('prompt_tokens', 'completion_tokens', 'input_tokens', 'output_tokens', 'total_tokens', 'reasoning_tokens'):
            if type(usage.get(key)) is int and 0 <= usage[key] <= 1000000000:
                safe[key] = usage[key]
        if 'cost' in usage:
            try:
                safe['cost'] = _money(usage['cost'])
            except ValueError:
                pass
        event['usage'] = safe
    return event


def _append_billing(job, event):
    ledger = job.setdefault('semantic_billing', {'schema': 'tokenclock-l1-semantic-job-billing/v1', 'attempts': []})
    attempt = next((entry for entry in ledger['attempts'] if entry['attempt'] == event['attempt']), None)
    if attempt is None:
        attempt = {'attempt': event['attempt'], 'events': [], 'latest': {}}
        ledger['attempts'].append(attempt)
    # Current enhancement dispatches at most one request per attempt. Keep a
    # generous bounded event history without losing the latest accounting state.
    if len(attempt['events']) < 128:
        attempt['events'].append(event)
    else:
        attempt['events_omitted'] = attempt.get('events_omitted', 0) + 1
    for key, value in event.items():
        if key in {'attempt', 'recorded_at'}:
            continue
        if key in {'actual_cost_usd', 'estimated_cost_usd', 'reserved_cost_usd'} and value is None and attempt['latest'].get(key) is not None:
            continue  # an omitted later cost cannot erase an already observed amount
        attempt['latest'][key] = value
    if event['stage'] == 'semantic_request_reserved':
        attempt['latest'].setdefault('reservation_released', False)
    actual, estimated, pending = Decimal('0'), Decimal('0'), Decimal('0')
    requests = 0
    for entry in ledger['attempts']:
        last = entry['latest']
        requests += last.get('request_count', last.get('requests', 0))
        reported, estimate = last.get('actual_cost_usd'), last.get('estimated_cost_usd')
        if reported is not None:
            actual += Decimal(reported)
        elif estimate is not None:
            estimated += Decimal(estimate)
        if last.get('reservation_released') is not True and last.get('reserved_cost_usd') is not None:
            pending += Decimal(last['reserved_cost_usd'])
    ledger['totals'] = {'reported_actual_cost_usd': str(actual), 'estimated_only_cost_usd': str(estimated),
                        'pending_reserved_cost_usd': str(pending), 'requests': requests,
                        'scope': 'known_checkpoints_only_missing_cost_is_not_zero'}

def _append_probe_billing(job, raw, attempt):
    if raw.get('billing_schema') != 'tokenclock-probe-billing-checkpoint/v1':return
    request_id=raw.get('client_request_id')
    if not isinstance(request_id,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',request_id):return
    snapshot=raw.get('request_billing')
    if not isinstance(snapshot,dict):return
    safe={}
    for key in ('reservation_usd','reported_cost_usd','estimated_cost_usd','pending_reserved_usd'):
        try:safe[key]=_money(snapshot.get(key))
        except ValueError:
            safe[key]=None;job['probe_receipts_require_review']=True
    safe['reservation_released']=snapshot.get('reservation_released') is True
    if safe['pending_reserved_usd'] is None and not safe['reservation_released']:job['probe_receipts_require_review']=True
    safe['accounting']=redact(str(snapshot.get('accounting','')))[:100]
    ledger=job.setdefault('probe_billing',{'schema':'tokenclock-probe-job-billing/v1','requests':[]})
    row=next((r for r in ledger['requests'] if r['attempt']==attempt and r['client_request_id']==request_id),None)
    if row is None:
        if len(ledger['requests'])>=1000:raise ValueError('请求账本达到安全上限')
        row={'attempt':attempt,'client_request_id':request_id,'purpose':raw.get('purpose','target')};ledger['requests'].append(row)
    if row.get('purpose','target')!=raw.get('purpose','target') or raw.get('purpose','target') not in {'target','judge'}:job['probe_receipts_require_review']=True
    previous=row.get('latest',{})
    for key in ('reported_cost_usd','estimated_cost_usd'):
        old=previous.get(key)
        if old is not None and safe.get(key) is None:
            safe[key]=old
            if key=='reported_cost_usd' or safe.get('reported_cost_usd') is None:job['probe_receipts_require_review']=True
        elif old is not None and safe.get(key) is not None and Decimal(safe[key])<Decimal(old):
            safe[key]=old;job['probe_receipts_require_review']=True
    row.update(latest=safe,stage=raw.get('stage'),recorded_at=_now())
    totals={'reported_actual_cost_usd':Decimal(0),'estimated_only_cost_usd':Decimal(0),'pending_reserved_cost_usd':Decimal(0)}
    for row in ledger['requests']:
        v=row['latest']
        if v['reported_cost_usd'] is not None:totals['reported_actual_cost_usd']+=Decimal(v['reported_cost_usd'])
        elif v['estimated_cost_usd'] is not None:totals['estimated_only_cost_usd']+=Decimal(v['estimated_cost_usd'])
        if v['pending_reserved_usd'] is not None:totals['pending_reserved_cost_usd']+=Decimal(v['pending_reserved_usd'])
    ledger['totals']={k:str(v) for k,v in totals.items()}
    ledger['totals'].update(requests=len(ledger['requests']),scope='all_attempts_known_checkpoints_only')
    ledger['by_purpose']={purpose:_probe_totals([r for r in ledger['requests'] if r.get('purpose','target')==purpose]) for purpose in ('target','judge')}

def _probe_totals(rows):
    totals={'reported_actual_cost_usd':Decimal(0),'estimated_only_cost_usd':Decimal(0),'pending_reserved_cost_usd':Decimal(0)}
    for row in rows:
        v=row['latest']
        if v.get('reported_cost_usd') is not None:totals['reported_actual_cost_usd']+=Decimal(v['reported_cost_usd'])
        elif v.get('estimated_cost_usd') is not None:totals['estimated_only_cost_usd']+=Decimal(v['estimated_cost_usd'])
        if v.get('pending_reserved_usd') is not None:totals['pending_reserved_cost_usd']+=Decimal(v['pending_reserved_usd'])
    return {**{k:str(v) for k,v in totals.items()},'requests':len(rows)}


MAX_SOURCE_BYTES = 256 * 1024 * 1024


def _now():
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds')


def _json(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8') + b'\n'


def _private_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('任务目录不可是符号链接')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def _atomic_json(path, value):
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def _safe_error(error):
    return redact(str(error))[:1600]


def _external(config):
    from ..probes.assessment import live as judge_live
    if config.get('workflow_mode') in {'l2','l3'}:
        return config.get('transport_mode') == 'live' or judge_live(config.get('assessment'))
    nested = config.get('external')
    return ((isinstance(nested, dict) and nested.get('enabled') is True)
            or str(config.get('mode', 'local')).casefold() not in {'local', 'off', 'none', 'disabled'})


def _redacted_metadata(item):
    if isinstance(item, dict):
        return {str(key): _redacted_metadata(value) for key, value in item.items()
                if str(key).casefold().replace('-', '_') not in {
                    'api_key', 'apikey', 'authorization', 'access_token', 'auth_token', 'password', 'secret'}}
    if isinstance(item, list):
        return [_redacted_metadata(value) for value in item]
    return redact(item) if isinstance(item, str) else item


def _config(value):
    result = deepcopy(value) if value is not None else {'mode': 'local'}
    if not isinstance(result, dict):
        raise ValueError('semantic_config 必须是对象')
    result.setdefault('mode', 'local')
    encoded = _json(result)
    if len(encoded) > 65536:
        raise ValueError('semantic_config 超过 64 KiB')
    return result, _redacted_metadata(result)


class JobCancelled(Exception):
    """Cooperative cancellation; a staging result will not be published."""


class JobManager:
    def __init__(self, state_dir, runner=None, *, autostart=True,
                 max_source_bytes=64 * 1024 * 1024, max_pending=20):
        if type(max_source_bytes) is not int or not 1 <= max_source_bytes <= MAX_SOURCE_BYTES:
            raise ValueError('输入字节上限必须为 1..256 MiB')
        if type(max_pending) is not int or not 1 <= max_pending <= 100:
            raise ValueError('max_pending 必须为 1..100')
        self.state_dir = Path(state_dir).expanduser().absolute()
        _private_dir(self.state_dir)
        self._lock_fd = None
        self._lock_backend = None
        self._claim_owner()
        self.runner = runner
        self.max_source_bytes = max_source_bytes
        self.max_pending = max_pending
        self._condition = threading.Condition(threading.RLock())
        self._jobs = {}
        self._runtime_config = {}
        self._queue = deque()
        self._closed = False
        self._thread = None
        try:
            self._recover()
            if autostart:
                self._thread = threading.Thread(target=self._worker, name='TokenClock-L1-worker', daemon=True)
                self._thread.start()
        except BaseException:
            self._release_owner()
            raise

    def _claim_owner(self):
        path = self.state_dir / '.manager.lock'
        if path.is_symlink():
            raise ValueError('任务锁不能是符号链接')
        fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            if os.name == 'nt':
                import msvcrt
                if os.fstat(fd).st_size == 0:
                    os.write(fd, b'0')
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                self._lock_backend = 'msvcrt'
            else:
                import fcntl
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self._lock_backend = 'fcntl'
        except OSError as exc:
            os.close(fd)
            raise ValueError('此任务目录已有工作进程，请先关闭已有实例') from exc
        self._lock_fd = fd
        os.chmod(path, 0o600)

    def _release_owner(self):
        fd, self._lock_fd = self._lock_fd, None
        if fd is not None:
            try:
                if self._lock_backend == 'msvcrt':
                    import msvcrt
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    def _job_dir(self, job_id):
        if not isinstance(job_id, str) or not JOB_ID.fullmatch(job_id):
            raise ValueError('任务 ID 不合法')
        path = self.state_dir / job_id
        if path.is_symlink():
            raise ValueError('任务目录被替换为符号链接')
        return path

    def _save(self, job):
        job['updated_at'] = _now()
        _atomic_json(self._job_dir(job['id']) / 'job.json', job)

    def _recover(self):
        for directory in sorted(self.state_dir.iterdir()):
            if directory.is_symlink() or not JOB_ID.fullmatch(directory.name) or not directory.is_dir():
                continue
            path = directory / 'job.json'
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
                continue
            try:
                job = json.loads(path.read_text(encoding='utf-8'))
            except (ValueError, OSError):
                continue
            if not isinstance(job, dict) or job.get('schema') != JOB_SCHEMA or job.get('id') != directory.name:
                continue
            if job.get('semantic_config',{}).get('workflow_mode') in {'l2','l3'}:
                # Reconcile the transport's atomic receipts before permitting
                # any resumed spending; process death can precede a callback.
                self._recover_probe_receipts(job,directory)
            if job.get('status') in ACTIVE:
                job.update(status='interrupted', error='进程已停止；源快照保留，需显式继续。',
                           cancel_requested=False, report_directory=None,
                           progress={'stage': 'interrupted', 'message': '等待显式继续', 'fraction': None})
                if _external(job.get('semantic_config', {})):
                    job['action_required'] = 'reconfirm_external_configuration'
                self._save(job)
            self._jobs[job['id']] = job

    def _recover_probe_receipts(self,job,directory):
        before=deepcopy(job)
        candidates=[]
        for base,pattern in [(directory,'.attempt-*'),(directory/'partial','attempt-*'),(directory/'reports','attempt-*')]:
            if base.is_symlink() or not base.is_dir():continue
            for folder in base.glob(pattern):
                match=re.fullmatch(r'\.?attempt-([0-9]{4})',folder.name)
                if not match or folder.is_symlink():continue
                attempt=int(match.group(1))
                if folder.name.startswith('.'):
                    partial=directory/'partial'/f'attempt-{attempt:04d}';_private_dir(partial.parent)
                    if not partial.exists():
                        os.rename(folder,partial);job['partial_directory']=str(partial.relative_to(directory));folder=partial
                for relative,purpose in [('evidence/transport/calls.json','target'),('evidence/task/transport/calls.json','target'),('evidence/assessment/transport/calls.json','judge')]:
                    path=folder/relative
                    if any(p.is_symlink() for p in (path,path.parent,path.parent.parent,folder/'evidence')):continue
                    if not path.is_file():continue
                    try:
                        if path.stat().st_size>4*1024*1024:raise ValueError('Receipt too large')
                        records=json.loads(path.read_text())
                        if not isinstance(records,list) or not 1<=len(records)<=64:raise ValueError('Receipt invalid')
                        request_ids=set()
                        for row in records:
                            if not isinstance(row,dict):raise ValueError('Receipt row invalid')
                            rid=row.get('client_request_id')
                            if not isinstance(rid,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',rid) or rid in request_ids:raise ValueError('Receipt request identity invalid')
                            request_ids.add(rid)
                            if type(row.get('dispatched')) is not bool or type(row.get('reservation_released')) is not bool:raise ValueError('Receipt dispatch state missing')
                            for key in ('reserved_usd','pending_reserved_usd'):
                                if key not in row or _money(row[key]) is None:raise ValueError('Receipt amount missing')
                            for key in ('reported_cost_usd','estimated_cost_usd'):
                                if key not in row:raise ValueError('Receipt amount state missing')
                                _money(row[key])
                            if row.get('purpose',purpose)!=purpose:raise ValueError('Receipt billing role mismatch')
                            pending=row.get('pending_reserved_usd',row.get('reserved_usd','0'))
                            _append_probe_billing(job,{'stage':'probe_request_failed','billing_schema':'tokenclock-probe-billing-checkpoint/v1',
                                'client_request_id':row.get('client_request_id'),'purpose':purpose,'request_billing':{
                                    'reservation_usd':row.get('reserved_usd','0'),'reported_cost_usd':row.get('reported_cost_usd'),
                                    'estimated_cost_usd':row.get('estimated_cost_usd'),'pending_reserved_usd':pending,
                                    'reservation_released':row.get('reservation_released',False),'accounting':row.get('accounting','recovered_checkpoint')}},attempt)
                        candidates.append((attempt,purpose))
                    except (OSError,ValueError,TypeError,KeyError):
                        job['probe_receipts_require_review']=True
        if job.get('status') in {'running','cancelling'} and _external(job.get('semantic_config',{})) and not any(a==job.get('attempt_count',0) for a,p in candidates):
            job['probe_receipts_require_review']=True
        if job!=before:self._save(job)

    def _snapshot(self, path, destination):
        path = Path(path).expanduser().absolute()
        if path.is_symlink():
            raise ValueError('请直接选择源文件，不能通过符号链接提交')
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        src_fd = os.open(path, flags)
        hasher, total = hashlib.sha256(), 0
        try:
            before = os.fstat(src_fd)
            if not stat.S_ISREG(before.st_mode):
                raise ValueError('仅可提交普通文件')
            if before.st_size > self.max_source_bytes:
                raise ValueError('源文件超过当前输入大小上限')
            out_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(out_fd, 'wb') as output:
                while True:
                    chunk = os.read(src_fd, min(1024 * 1024, self.max_source_bytes + 1 - total))
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > self.max_source_bytes:
                        raise ValueError('源文件读取时增长超过大小上限')
                    hasher.update(chunk)
                    output.write(chunk)
                after = os.fstat(src_fd)
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    raise ValueError('源文件仍在变化，未创建任务；请重新提交稳定快照')
                output.flush()
                os.fsync(output.fileno())
            os.chmod(destination, 0o600)
        finally:
            os.close(src_fd)
        return {'original_path': str(path), 'name': path.name, 'snapshot_name': destination.name,
                'sha256': hasher.hexdigest(), 'bytes': total, 'captured_at': _now(),
                'original_mtime_ns': before.st_mtime_ns}

    def _recommendation_input(self, origin):
        """One durable child per parent; old reports cannot reissue a budget.

        Runs under the manager lock. Recovers the remaining amount from all
        attempts' receipts, never from a client-supplied report or displayed cap.
        """
        from ..probes.common import load_json
        parent=self._jobs.get(origin)
        if parent is None or parent.get('status')!='completed':raise ValueError('推荐来源任务尚未完成或不存在')
        if parent.get('recommendation_child_job_id') or any(j.get('recommendation_origin_job_id')==origin for j in self._jobs.values()):raise ValueError('该报告已创建后续任务，请查看后续任务，不能重复领取剩余预算')
        if parent.get('probe_receipts_require_review'):raise ValueError('原费用回执不完整，先核对费用')
        report=load_json(self.report_path(origin)/'report.json')
        previous=deepcopy(parent['semantic_config'])
        if previous.get('transport_mode')!='live':raise ValueError('已有会话或文件的建议须作为新检测明确配置连接和预算')
        if 'probe_budget_cap_usd' not in parent or not isinstance(previous.get('provider'),dict):raise ValueError('缺少原任务预算记录，不能重新获得一份补测预算')
        by=parent.get('probe_billing',{}).get('by_purpose',{})
        checked=deepcopy(report)
        for role,key,provider in [('target','probe_budget_cap_usd',previous.get('provider')),
                                  ('judge','assessment_budget_cap_usd',previous.get('assessment',{}).get('provider'))]:
            if key not in parent:continue
            row=by.get(role)
            if not isinstance(row,dict):raise ValueError('缺少原任务的分角色费用回执')
            values={k:_money(row.get(k)) for k in ('reported_actual_cost_usd','estimated_only_cost_usd','pending_reserved_cost_usd')}
            if any(v is None for v in values.values()):raise ValueError('原费用字段缺失，无法继承预算')
            used=Decimal(values['reported_actual_cost_usd'])+Decimal(values['estimated_only_cost_usd'])
            pending=Decimal(values['pending_reserved_cost_usd'])
            if pending:raise ValueError('原任务费用尚未结清')
            provider['max_cost_usd']=parent[key]
            accounting={'budget_accounted_usd':str(used),'pending_reserved_usd':str(pending)}
            if role=='target':checked['result']['accounting']=accounting
            else:checked['result'].setdefault('reviewer_assessment',{})['accounting']=accounting
        previous['_planning_history']=parent.get('planning_history',[])
        return parent,report,checked,previous

    def recommendation_for_display(self, origin):
        from ..probes.recommendations import recommend, SCHEMA
        with self._condition:
            parent=self._jobs.get(origin)
            if not parent or parent.get("semantic_config",{}).get("transport_mode")!="live":return None
            try:
                parent,report,checked,previous=self._recommendation_input(origin)
                return recommend(checked,previous)
            except (ValueError,KeyError,TypeError) as exc:
                message="这份结果已安排过补测，可在历史中查看后续结果。" if parent.get("recommendation_child_job_id") else str(exc)
                return {"schema":SCHEMA,"status":"review_first","summary":message,"actions":[],"stop_reasons":[message],"automatic_dispatch":False}

    def _recommendation_config(self, origin, action_id, runtime_config, *, describe=False):
        from ..probes.recommendations import recommend, _seen
        parent,report,checked,previous=self._recommendation_input(origin)
        proposal=recommend(checked,previous)
        selected=next((a for a in proposal['actions'] if a['id']==action_id),None)
        if proposal['status']!='recommended' or not selected:raise ValueError('该推荐已不适用，请重新查看报告与预算')
        expected=selected['configuration_patch']
        if runtime_config.get('l2_method')=='numeric':raise ValueError('推荐对应原行为题包；数字指纹请另建检测，保留原预算记录')
        for key in ('workflow_mode','transport_mode','family','task_id','task_ids','repeats'):
            if key in expected and runtime_config.get(key)!=expected[key]:raise ValueError('推荐方法或题目改变，请改为新的手动检测')
        old=proposal['target_binding'];new=runtime_config.get('provider',{})
        if any(new.get(k,'responses' if k=='api_format' else None)!=v for k,v in old.items()):raise ValueError('推荐的待测接口或型号不一致')
        if runtime_config.get('assessment',{}).get('enabled'):raise ValueError('此推荐使用本地核验；新增解析预算请明确另建检测')
        if new.get('reasoning_effort','high')!='high':raise ValueError('推荐需保留 high 参考条件')
        if new.get('max_requests',20)<selected['request_count']:raise ValueError('请求次数上限不足以完成推荐的独立请求')
        if runtime_config.get('output_limit') is not None:raise ValueError('推荐保留原题生成上限，不能另设输出上限')
        cap=Decimal(expected['provider']['max_cost_usd'])
        asked=Decimal(_money(new.get('max_cost_usd')) or '0')
        if asked<=0 or asked>cap:raise ValueError('后续检测不能超过原任务剩余预算')
        from .preview import preview
        quote=preview(runtime_config)
        if not quote['valid'] or quote.get('total_upper_usd') is None or Decimal(quote['total_upper_usd'])>asked:raise ValueError('剩余预算不足以完整预留这项推荐')
        tasks,_=_seen(report.get('result',report),report.get('result',{}).get('subject',{}).get('id'))
        history=sorted(set(parent.get('planning_history',[]))|tasks)
        return {'history':history,'action':deepcopy(selected)} if describe else history

    def preview_recommendation(self, origin, action_id, runtime_config):
        with self._condition:
            return self._recommendation_config(origin,action_id,runtime_config,describe=True)['action']

    def submit(self, source_path, comparison_model=None, semantic_config=None, *, input_name=None,
               recommendation_origin_job_id=None, recommendation_action_id=None):
        from ..probes.workflow import validate_config
        runtime_config, config = _config(validate_config(semantic_config))
        runtime_config.pop('_planning_history',None);config.pop('_planning_history',None)
        if comparison_model is not None and (not isinstance(comparison_model, str) or len(comparison_model) > 200):
            raise ValueError('比较目标必须为不超过 200 字符的文字')
        if input_name is not None:
            if not isinstance(input_name,str) or len(input_name)>200 or any(ord(c)<32 for c in input_name):raise ValueError('文件显示名称无效')
            input_name=Path(input_name.replace('\\','/')).name
        with self._condition:
            if self._closed:
                raise ValueError('任务管理器已关闭')
            if sum(job['status'] in ACTIVE for job in self._jobs.values()) >= self.max_pending:
                raise ValueError('待处理任务已达上限')
            planning_history=[]
            if recommendation_origin_job_id is not None or recommendation_action_id is not None:
                if not isinstance(recommendation_origin_job_id,str) or not isinstance(recommendation_action_id,str):raise ValueError('推荐来源和动作标识必须完整')
                planning_history=self._recommendation_config(recommendation_origin_job_id,recommendation_action_id,runtime_config)
            identifier = 'job-' + uuid.uuid4().hex
            directory = self._job_dir(identifier)
            directory.mkdir(mode=0o700)
            suffix = Path(source_path).suffix.casefold()
            if suffix not in {'.json','.jsonl','.py','.html','.svg','.txt'}:suffix='.json'
            try:
                source = self._snapshot(source_path, directory / ('source' + suffix))
                assessment_source=None
                if runtime_config.get('assessment',{}).get('enabled') and runtime_config['assessment'].get('transport_mode')=='replay' and runtime_config['assessment'].get('replay_path'):
                    assessment_source=self._snapshot(runtime_config['assessment']['replay_path'],directory/'assessment-replay.json')
                    runtime_config['assessment']['replay_path']=str(directory/'assessment-replay.json')
                    runtime_config,config=_config(runtime_config)
                timestamp = _now()
                job = {'schema': JOB_SCHEMA, 'id': identifier, 'status': 'queued',
                       'input_name':input_name,
                       'created_at': timestamp, 'updated_at': timestamp, 'source': source,
                       'comparison_model': comparison_model, 'semantic_config': config,
                       'attempt_count': 0, 'cancel_requested': False, 'error': None,
                       'progress': {'stage': 'queued', 'message': '等待本地工作进程', 'fraction': 0},
                       'report_directory': None, 'report_summary': None,'assessment_source':assessment_source}
                if recommendation_origin_job_id is not None:
                    job.update(recommendation_origin_job_id=recommendation_origin_job_id,
                               recommendation_action_id=recommendation_action_id,planning_history=planning_history)
                if runtime_config.get('workflow_mode') in {'l2','l3'} and runtime_config.get('transport_mode')=='live':
                    job['probe_budget_cap_usd']=_money(runtime_config['provider'].get('max_cost_usd'))
                from ..probes.assessment import live as judge_live
                if judge_live(runtime_config.get('assessment')):job['assessment_budget_cap_usd']=_money(runtime_config['assessment']['provider']['max_cost_usd'])
                if runtime_config.get('workflow_mode','l1')=='l1' and _external(runtime_config):job['semantic_budget_cap_usd']=_money(runtime_config['external'].get('max_cost_usd'))
                self._save(job)
                if recommendation_origin_job_id is not None:
                    parent=self._jobs[recommendation_origin_job_id]
                    parent['recommendation_child_job_id']=identifier
                    self._save(parent)
            except BaseException:
                shutil.rmtree(directory)
                raise
            self._jobs[identifier] = job
            self._runtime_config[identifier] = runtime_config
            self._queue.append(identifier)
            self._condition.notify_all()
            return deepcopy(job)

    def get(self, job_id):
        self._job_dir(job_id)
        with self._condition:
            if job_id not in self._jobs:
                raise KeyError('任务不存在')
            return deepcopy(self._jobs[job_id])

    def list(self, limit=100, *, completed_only=False):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError('列表上限必须为 1..100')
        with self._condition:
            jobs = [j for j in self._jobs.values() if not completed_only or j['status'] == 'completed']
            return deepcopy(sorted(jobs, key=lambda j: j.get('completed_at',j.get('created_at',j['updated_at'])) if j.get('status')=='completed' else j['updated_at'], reverse=True)[:limit])

    def cancel(self, job_id):
        with self._condition:
            job = self._jobs.get(job_id)
            if job is None:
                raise KeyError('任务不存在')
            if job['status'] in TERMINAL:
                return deepcopy(job)
            job['cancel_requested'] = True
            job['status'] = 'cancelled' if job['status'] == 'queued' else 'cancelling'
            if job['status'] == 'cancelled':
                self._runtime_config.pop(job_id, None)
            job['progress']['message'] = '已取消' if job['status'] == 'cancelled' else '等待当前步骤安全结束'
            self._save(job)
            self._condition.notify_all()
            return deepcopy(job)

    def _resume_config(self, job, runtime_config):
        runtime_config=deepcopy(runtime_config)
        previous=job['semantic_config']
        if previous.get('l2_method','behavior')!=runtime_config.get('l2_method','behavior'):
            raise ValueError('恢复必须使用原检测方法；切换数字指纹请另建任务')
        if previous.get('l2_method')=='numeric' and previous.get('numeric_output_limit',8192)!=runtime_config.get('numeric_output_limit',8192):
            raise ValueError('恢复必须保留原数字题生成上限')
        for key in ('workflow_mode','task_id','transport_mode'):
            if previous.get(key)!=runtime_config.get(key):raise ValueError('恢复必须使用原流程、任务及模式；改变配置请另建任务')
        for provider_path in ('provider','assessment'):
            old=previous.get(provider_path,{}) or {};new=runtime_config.get(provider_path,{}) or {}
            if provider_path=='assessment':
                if old.get('enabled',False)!=new.get('enabled',False) or (old.get('enabled') and old.get('transport_mode')!=new.get('transport_mode')):raise ValueError('评审模式改变请另建任务，避免混用旧费用或回放')
                old=old.get('provider',{});new=new.get('provider',{})
            for field in ('model','endpoint','api_format','reasoning_effort'):
                if old.get(field)!=new.get(field):raise ValueError('接口或型号改变请另建任务；恢复仅更新密钥与剩余预算')
        if runtime_config.get('workflow_mode') in {'l2','l3'} and _external(runtime_config):
            if job.get('probe_receipts_require_review'):raise ValueError('中断时请求回执不完整，无法确定剩余预算；该任务停止继续付费')
            totals=job.get('probe_billing',{}).get('totals',{})
            if Decimal(totals.get('pending_reserved_cost_usd','0'))>0:
                raise ValueError('上次请求仍有待结费用，本任务停止续费；请先核对接口账单')
            from ..probes.assessment import live as judge_live
            roles=[]
            if runtime_config.get('transport_mode')=='live':roles.append(('target','probe_budget_cap_usd',runtime_config['provider']))
            if judge_live(runtime_config.get('assessment')):roles.append(('judge','assessment_budget_cap_usd',runtime_config['assessment']['provider']))
            for purpose,cap_key,provider in roles:
                if cap_key not in job:raise ValueError('原任务未授权此类费用，请为新评审另建任务')
                subtotal=job.get('probe_billing',{}).get('by_purpose',{}).get(purpose,totals if purpose=='target' else {})
                used=Decimal(subtotal.get('reported_actual_cost_usd','0'))+Decimal(subtotal.get('estimated_only_cost_usd','0'))
                remaining=Decimal(job[cap_key])-used
                if remaining<=0:raise ValueError('该任务的'+purpose+'预算已用完')
                provider['max_cost_usd']=str(min(remaining,Decimal(str(provider['max_cost_usd']))))
            runtime_config,stored_config=_config(runtime_config)
        if runtime_config.get('workflow_mode')=='l2' and runtime_config.get('l2_method')!='numeric' and runtime_config.get('transport_mode')!='artifact':
            from ..probes.catalog import l2_plan
            if l2_plan(previous.get('family','openai'),previous.get('task_ids'))!=l2_plan(runtime_config.get('family','openai'),runtime_config.get('task_ids')):
                raise ValueError('恢复需使用原题包；更换题目请另建任务')
        if previous.get('assessment',{}).get('enabled') and previous['assessment'].get('repeats',2)!=runtime_config['assessment'].get('repeats',2):
            raise ValueError('评审次数改变请另建任务')
        if previous.get('assessment',{}).get('enabled'):
            for key,default in [('batch_once',False),('connection_source','separate')]:
                if previous['assessment'].get(key,default)!=runtime_config['assessment'].get(key,default):raise ValueError('解析方式或连接来源改变请另建任务')
        if runtime_config.get('workflow_mode','l1')=='l1' and _external(runtime_config):
            totals=job.get('semantic_billing',{}).get('totals',{})
            if Decimal(totals.get('pending_reserved_cost_usd','0'))>0:
                raise ValueError('上次语义请求仍有待结费用，停止继续付费')
            old_external=previous.get('external',{});new_external=runtime_config.get('external',{})
            for key in ('endpoint','model'):
                if old_external.get(key)!=new_external.get(key):raise ValueError('语义接口或型号改变请另建任务')
            original=job.get('semantic_budget_cap_usd',old_external.get('max_cost_usd'))
            if original is None:raise ValueError('原语义预算不可确定，请另建任务')
            used=Decimal(totals.get('reported_actual_cost_usd','0'))+Decimal(totals.get('estimated_only_cost_usd','0'))
            remaining=Decimal(str(original))-used
            if remaining<=0:raise ValueError('原语义增强任务预算已用完')
            new_external['max_cost_usd']=str(min(remaining,Decimal(str(new_external['max_cost_usd']))))
        return runtime_config

    def preview_resume(self, job_id, semantic_config):
        """No queue or job mutation; uses the same scope and remaining-budget admission."""
        with self._condition:
            job=self._jobs.get(job_id)
            if job is None:raise KeyError('任务不存在')
            if job['status'] not in {'interrupted','cancelled','failed','action_required'}:raise ValueError('该任务目前不能重试')
            source=self._verify_snapshot(job)
            if job.get('assessment_source'):self._verify_assessment_snapshot(job)
            admitted=self._resume_config(job,semantic_config)
            return str(source),admitted

    def resume(self, job_id, semantic_config=None, *, allow_external=False):
        with self._condition:
            if self._closed:
                raise ValueError('任务管理器已关闭')
            job = self._jobs.get(job_id)
            if job is None:
                raise KeyError('任务不存在')
            if job['status'] not in {'interrupted', 'cancelled', 'failed', 'action_required'}:
                raise ValueError('仅中断、取消或失败的任务可以显式继续')
            if sum(j['status'] in ACTIVE for j in self._jobs.values()) >= self.max_pending:
                raise ValueError('待处理任务已达上限')
            self._verify_snapshot(job)
            if semantic_config is None and _external(job['semantic_config']):
                job.update(status='action_required',action_required='reconfirm_external_configuration',error='外部模式需要重新提供本次密钥与配置；尚未发送请求。')
                self._save(job);return deepcopy(job)
            from ..probes.workflow import validate_config
            runtime_config, stored_config = _config(validate_config(semantic_config or job['semantic_config']))
            previous=job['semantic_config']
            if _external(runtime_config) and (semantic_config is None or not allow_external):
                job.update(status='action_required', action_required='reconfirm_external_configuration',
                           error='外部模式继续前必须重新提供配置并明确同意；尚未调用外部服务。')
                self._save(job)
                return deepcopy(job)
            runtime_config=self._resume_config(job,runtime_config)
            runtime_config,stored_config=_config(runtime_config)
            if job.get('assessment_source'):
                runtime_config['assessment']['replay_path']=str(self._verify_assessment_snapshot(job))
                runtime_config,stored_config=_config(runtime_config)
            elif previous.get('assessment',{}).get('replay_records')!=runtime_config.get('assessment',{}).get('replay_records'):
                raise ValueError('评审回放内容改变，请另建任务')
            job['semantic_config'] = stored_config
            self._runtime_config[job_id] = runtime_config
            job.pop('action_required', None)
            job.update(status='queued', cancel_requested=False, error=None, report_directory=None,
                       user_summary=None,
                       progress={'stage': 'queued', 'message': '用户已显式继续；复用固定源快照', 'fraction': 0})
            self._save(job)
            self._queue.append(job_id)
            self._condition.notify_all()
            return deepcopy(job)

    def _verify_assessment_snapshot(self,job):
        metadata=job.get('assessment_source')
        if not isinstance(metadata,dict):return None
        if metadata.get('snapshot_name')!='assessment-replay.json':raise ValueError('评审快照名称无效')
        path=self._job_dir(job['id'])/'assessment-replay.json'
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=metadata.get('bytes') or path.stat().st_size>self.max_source_bytes:
            raise ValueError('评审快照缺失或被替换')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=metadata.get('sha256'):raise ValueError('评审快照校验失败')
        return path

    def _verify_snapshot(self, job):
        name = job.get('source', {}).get('snapshot_name')
        if name not in ('source.json', 'source.jsonl','source.py','source.html','source.svg','source.txt'):
            raise ValueError('源快照名称不合法')
        source = self._job_dir(job['id']) / name
        if source.is_symlink() or not source.is_file():
            raise ValueError('源快照缺失或已被替换')
        size = source.stat().st_size
        if size > self.max_source_bytes or size != job['source'].get('bytes'):
            raise ValueError('固定源快照大小发生变化，任务未运行')
        hasher = hashlib.sha256()
        with source.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(chunk)
        if hasher.hexdigest() != job['source']['sha256']:
            raise ValueError('固定源快照校验失败，任务未运行')
        return source

    def partial_evidence_path(self,job_id):
        with self._condition:
            job=self._jobs.get(job_id)
            if not job or job['status'] in ACTIVE:raise ValueError('没有可导出的已停止任务')
            relative=job.get('partial_directory')
            if not isinstance(relative,str) or not re.fullmatch(r'partial/attempt-[0-9]{4}',relative):raise ValueError('没有部分证据')
            folder=self._job_dir(job_id)/relative
            if folder.is_symlink() or folder.parent.is_symlink():raise ValueError('部分证据路径不安全')
            from ..probes.common import archive_evidence
            return archive_evidence(folder,folder/'partial-evidence.zip')

    def report_path(self, job_id):
        with self._condition:
            job = self._jobs.get(job_id)
            if job is None:
                raise KeyError('任务不存在')
            if job['status'] != 'completed' or not job.get('report_directory'):
                raise ValueError('该任务尚无完整可发布报告')
            relative = job['report_directory']
            if not re.fullmatch(r'reports/attempt-\d{4,}', relative):
                raise ValueError('报告目录记录不合法')
            path = self._job_dir(job_id) / relative
            if path.parent.is_symlink() or path.is_symlink() or not path.is_dir():
                raise ValueError('报告目录缺失或不安全')
            return path

    def _progress(self, job_id, stage=None, message='', fraction=None, **extra):
        with self._condition:
            job = self._jobs[job_id]
            event_data = dict(extra, stage=stage)
            if isinstance(stage, dict):
                entry = stage
                event_data = dict(entry)
                stage, message, fraction = entry.get('stage'), entry.get('message', ''), entry.get('fraction')
            billing = _billing_event(event_data, job['attempt_count'])
            if billing is not None:
                _append_billing(job, billing)
                self._save(job)
            if str(stage).startswith('probe_request_'):
                _append_probe_billing(job,event_data,job['attempt_count'])
                self._save(job)
            if self._closed or job['cancel_requested']:
                if stage in {'semantic_request_finished', 'semantic_request_failed','probe_request_finished','probe_request_failed'}:
                    return
                raise JobCancelled('任务已取消或管理器已关闭')
            fraction = float(fraction) if isinstance(fraction, (float, int)) and not isinstance(fraction, bool) and math.isfinite(fraction) else None
            if fraction is not None:
                fraction = max(0.0, min(1.0, fraction))
            job['progress'] = {'stage': redact(stage or 'working')[:100],
                               'message': redact(message)[:600], 'fraction': fraction}
            self._save(job)

    def _cancelled(self, job_id):
        with self._condition:
            return self._closed or self._jobs[job_id]['cancel_requested']

    def _run(self, identifier):
        with self._condition:
            job = self._jobs[identifier]
            if job['status'] != 'queued' or self._closed:
                return
            job.update(status='running', attempt_count=job['attempt_count'] + 1,
                       progress={'stage': 'starting', 'message': '读取固定源快照', 'fraction': 0})
            self._save(job)
            attempt = job['attempt_count']
            config = deepcopy(self._runtime_config.get(identifier, job['semantic_config']))
            config['_planning_history']=job.get('planning_history',[])
            model = job['comparison_model']
        directory = self._job_dir(identifier)
        staging = directory / f'.attempt-{attempt:04d}'
        try:
            source = self._verify_snapshot(job)
            assessment_path=self._verify_assessment_snapshot(job)
            if assessment_path:config['assessment']['replay_path']=str(assessment_path)
            runner = self.runner
            if runner is None:
                from ..probes.workflow import run_analysis
                runner = run_analysis
            result = runner(source_path=source, comparison_model=model, semantic_config=config,
                            progress=lambda *a, **k: self._progress(identifier, *a, **k),
                            cancelled=lambda: self._cancelled(identifier), output_dir=staging)
            if not isinstance(result, dict):
                raise ValueError('分析执行器未返回报告对象')
            _json(result)  # validate before mutating durable completion metadata
            if staging.is_symlink() or not staging.is_dir():
                raise ValueError('分析执行器未提供完整报告目录')
            for filename in REQUIRED_REPORT_FILES:
                path = staging / filename
                if path.is_symlink() or not path.is_file():
                    raise ValueError('分析结果缺少完整报告文件：' + filename)
                os.chmod(path, 0o600)
            with self._condition:
                job = self._jobs[identifier]
                if self._closed or job['cancel_requested']:
                    raise JobCancelled('任务已取消，未发布报告')
                published = directory / 'reports' / f'attempt-{attempt:04d}'
                _private_dir(published.parent)
                if published.exists():
                    raise ValueError('报告目标已存在，不覆盖历史结果')
                os.rename(staging, published)
                os.chmod(published, 0o700)
                job.update(status='completed', error=None, completed_at=_now(), report_directory=str(published.relative_to(directory)),
                           report_summary=_redacted_metadata(result.get('summary', {})),
                           user_summary=_redacted_metadata(result.get('user_summary',{})),
                           progress={'stage': 'completed', 'message': '完整报告已就绪', 'fraction': 1})
                self._save(job)
        except Exception as exc:
            with self._condition:
                job = self._jobs[identifier]
                status = 'interrupted' if self._closed else 'cancelled' if job['cancel_requested'] or isinstance(exc, JobCancelled) else 'failed'
                job.update(status=status, error=None if status == 'cancelled' else _safe_error(exc),
                           report_directory=None, progress={'stage': status, 'message': '未发布未完成结果', 'fraction': None})
                self._save(job)
        finally:
            if staging.is_symlink():
                staging.unlink()
            elif staging.exists():
                # Incomplete is not published as a complete report; retain paid
                # receipts and partial artifacts so cancellation loses no evidence.
                partial = directory / 'partial' / f'attempt-{attempt:04d}'
                _private_dir(partial.parent)
                if not partial.exists():
                    os.rename(staging,partial)
                    with self._condition:
                        self._jobs[identifier]['partial_directory']=str(partial.relative_to(directory))
                        self._save(self._jobs[identifier])
            with self._condition:
                self._runtime_config.pop(identifier, None)
                self._condition.notify_all()

    def _worker(self):
        try:
            while True:
                with self._condition:
                    while not self._queue and not self._closed:
                        self._condition.wait()
                    if self._closed:
                        return
                    identifier = self._queue.popleft()
                self._run(identifier)
        finally:
            self._release_owner()

    def close(self, wait=True, timeout=5):
        with self._condition:
            if not self._closed:
                self._closed = True
                self._runtime_config.clear()
                for job in self._jobs.values():
                    if job['status'] == 'queued':
                        job.update(status='interrupted', error='管理器已关闭；需显式继续')
                        self._save(job)
                self._condition.notify_all()
        if self._thread is not None and wait:
            self._thread.join(timeout=max(0, min(float(timeout), 60)))
        if self._thread is None:
            self._release_owner()
        return self._thread is None or not self._thread.is_alive()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
