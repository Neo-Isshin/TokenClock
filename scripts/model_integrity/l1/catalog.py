"""Bounded metadata/head-only session discovery inside explicit or known roots."""
from __future__ import annotations

from datetime import datetime, timezone
import heapq
import json
import os
from pathlib import Path
import re
import stat
import time

from .render import redact

MAX_LIMIT = 100
MAX_ENTRIES = 20000
MAX_HEAD_BYTES = 128 * 1024
MAX_DEPTH = 8


def known_session_roots():
    codex = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
    return [codex / 'sessions', codex / 'archived_sessions', Path.home() / '.claude' / 'projects']


def _link(path):
    return path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction())


def _text(value, limit=240):
    return redact(value)[:limit] if isinstance(value, str) else None


def _header(raw, size):
    text = raw.decode('utf-8-sig', errors='replace')
    rows = []
    if len(raw) == size:
        try:
            document = json.loads(text)
            if isinstance(document, dict):
                rows = [document]
        except ValueError:
            pass
    if not rows:
        lines = text.splitlines()
        if len(raw) < size and not text.endswith('\n'):
            lines = lines[:-1]
        for line in lines:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                rows.append(value)
    fmt, session_id, title, display = None, None, None, None
    models, requested = [], []
    for item in rows:
        kind = item.get('type')
        payload = item.get('payload') if isinstance(item.get('payload'), dict) else {}
        if item.get('schema') == 'tokenclock-l1-observation/v1':
            fmt = 'observation'
            context = item.get('context') if isinstance(item.get('context'), dict) else {}
            session_id = _text(context.get('session_id'))
            title = _text(item.get('title'))
            display = _text(context.get('display_model'))
            if isinstance(context.get('requested_model'), str):
                models.append(context['requested_model'])
                requested.append(context['requested_model'])
        elif kind in {'session_meta', 'turn_context', 'response_item'}:
            fmt = 'codex'
            if kind == 'session_meta':
                session_id = _text(payload.get('id')) or session_id
                title = _text(payload.get('title')) or title
            if kind == 'turn_context' and isinstance(payload.get('model'), str):
                models.append(payload['model'])
                requested.append(payload['model'])
        elif kind in {'assistant', 'user'} and isinstance(item.get('message'), dict):
            fmt = 'claude-code'
            session_id = _text(item.get('sessionId')) or session_id
            if isinstance(item['message'].get('model'), str):
                models.append(item['message']['model'])
        elif isinstance(item.get('info'), dict) and isinstance(item.get('messages'), list):
            fmt = 'opencode'
            info = item['info']
            session_id = _text(info.get('id'))
            title = _text(info.get('title'))
            declared = info.get('model')
            if isinstance(declared, dict) and isinstance(declared.get('id'), str):
                models.append(declared['id'])
            display = _text(info.get('display_model'))
    # A first metadata line can itself exceed the head budget. Only identify its
    # declared format, never infer a model by searching arbitrary prompt text.
    if fmt is None and re.match(r'^\s*\{\s*"(?:timestamp|type)"', text):
        prefix = text[:256]
        if re.search(r'"type"\s*:\s*"session_meta"', prefix):
            fmt = 'codex'
    if fmt is None:
        return None
    unique = list(dict.fromkeys(_text(m) for m in models if _text(m)))
    return {'format': fmt, 'session_id': session_id, 'title': title,
            'raw_model': unique[0] if len(unique) == 1 else None, 'raw_models': unique,
            'requested_models': list(dict.fromkeys(_text(m) for m in requested if _text(m))),
            'display_model': display, 'multiple_model_declarations_in_head': len(unique) > 1,
            'model_scope': '仅文件开头可见的声明，不代表整份会话或实际后端身份',
            'head_complete_file': len(raw) == size}


def _safe_head(path, root, count):
    current = path
    while True:
        if _link(current):
            raise ValueError('symlink skipped')
        if current == root:
            break
        if current == current.parent:
            raise ValueError('candidate escaped selected root')
        current = current.parent
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('not a regular file')
        raw = os.read(fd, count)
        return raw, info
    finally:
        os.close(fd)


def discover_sessions(roots=None, *, limit=100, max_entries=5000, head_bytes=32768,
                      time_budget_seconds=2.0):
    if type(limit) is not int or not 1 <= limit <= MAX_LIMIT:
        raise ValueError('limit 必须为 1..100')
    if type(max_entries) is not int or not 1 <= max_entries <= MAX_ENTRIES:
        raise ValueError('max_entries 必须为 1..20000')
    if type(head_bytes) is not int or not 256 <= head_bytes <= MAX_HEAD_BYTES:
        raise ValueError('head_bytes 必须为 256..131072')
    if not isinstance(time_budget_seconds, (int, float)) or not 0.01 <= time_budget_seconds <= 10:
        raise ValueError('扫描时间上限必须为 0.01..10 秒')
    chosen = known_session_roots() if roots is None else roots
    if isinstance(chosen, (str, Path)):
        chosen = [chosen]
    if not isinstance(chosen, (list, tuple)) or len(chosen) > 20:
        raise ValueError('请指定最多 20 个会话根目录')
    started, budget = time.monotonic(), float(time_budget_seconds)
    pending, candidates, roots_info, seen_roots, seen_files = [], [], [], set(), set()
    entries_seen = errors = skipped_links = max_depth_skips = 0
    sequence = 0
    reason = None
    for item in chosen:
        root = Path(item).expanduser().absolute()
        if str(root) in seen_roots:
            continue
        seen_roots.add(str(root))
        if _link(root):
            roots_info.append({'path': str(root), 'status': 'symlink_skipped'})
            skipped_links += 1
        elif not root.is_dir():
            roots_info.append({'path': str(root), 'status': 'not_available'})
        else:
            roots_info.append({'path': str(root), 'status': 'scanned'})
            sequence += 1
            heapq.heappush(pending, (-root.stat().st_mtime_ns, sequence, root, root, 0))
    candidate_limit = min(limit * 3, 300)
    while pending and reason is None:
        if time.monotonic() - started >= budget:
            reason = 'time_budget'
            break
        _, _, directory, root, depth = heapq.heappop(pending)
        if _link(directory):
            skipped_links += 1
            continue
        try:
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if entries_seen >= max_entries:
                        reason = 'entry_budget'
                        break
                    if time.monotonic() - started >= budget:
                        reason = 'time_budget'
                        break
                    entries_seen += 1
                    path = Path(entry.path)
                    if entry.is_symlink() or _link(path):
                        skipped_links += 1
                        continue
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError:
                        errors += 1
                        continue
                    sequence += 1
                    if stat.S_ISDIR(info.st_mode):
                        if depth >= MAX_DEPTH:
                            max_depth_skips += 1
                            continue
                        heapq.heappush(pending, (-info.st_mtime_ns, sequence, path, root, depth + 1))
                    elif stat.S_ISREG(info.st_mode) and path.suffix.casefold() in {'.jsonl', '.json'}:
                        if str(path) in seen_files:
                            continue
                        seen_files.add(str(path))
                        candidate = (info.st_mtime_ns, sequence, path, root, info.st_size)
                        if len(candidates) < candidate_limit:
                            heapq.heappush(candidates, candidate)
                        elif candidate[:2] > candidates[0][:2]:
                            heapq.heapreplace(candidates, candidate)
        except OSError:
            errors += 1
    sessions, bytes_read, head_reads = [], 0, 0
    # Spend a small bounded read budget even when the metadata entry cap was
    # reached, but never exceed the caller's total wall-clock budget.
    for _, _, path, root, _ in sorted(candidates, reverse=True):
        if len(sessions) >= limit:
            break
        if time.monotonic() - started >= budget:
            reason = 'time_budget'
            break
        try:
            raw, info = _safe_head(path, root, head_bytes)
        except (OSError, ValueError):
            errors += 1
            continue
        bytes_read += len(raw)
        head_reads += 1
        metadata = _header(raw, info.st_size)
        if metadata is None:
            continue
        sessions.append({'path': str(path), 'root': str(root), 'name': path.name,
                         'bytes': info.st_size, 'mtime_ns': info.st_mtime_ns,
                         'modified_at': datetime.fromtimestamp(info.st_mtime, timezone.utc).isoformat(),
                         **metadata})
    return {'sessions': sessions, 'roots': roots_info,
            'scan': {'entries_seen': entries_seen, 'head_reads': head_reads, 'bytes_read': bytes_read,
                     'elapsed_seconds': round(time.monotonic() - started, 4), 'truncated': bool(reason or max_depth_skips),
                     'stop_reason': reason, 'skipped_symlinks': skipped_links, 'depth_skips': max_depth_skips,
                     'read_errors': errors, 'max_results': limit, 'head_bytes_limit': head_bytes},
            'limitations': ['仅扫描指定根或固定已知会话根，不搜索全盘，也不跟随符号链接。',
                            '结果是扫描预算内最近的候选，不保证发现整个目录的全部最新会话。',
                            '型号字段只来自有限头部中的原始声明；缺失或多个型号时不猜一个代表型号。',
                            '选择条目后，分析任务才会固定源快照并读取完整授权范围。']}
