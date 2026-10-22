"""Bounded Python execution in an OS sandbox; no unsandboxed fallback.

The controller never imports submitted code. Only explicit workspace content is
visible to it, plus a read-only Python/system runtime. Environment is rebuilt.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import subprocess
import sys
import sysconfig
import tempfile
import time
from typing import Callable

DEFAULT_LIMITS = {'cpu_seconds': 10, 'wall_seconds': 15, 'memory_mb': 256,
                  'output_bytes': 262144, 'file_bytes': 1048576, 'workspace_bytes': 16777216,
                  'workspace_files': 1024}
_RUNTIME_CACHE = None


def _limits(config):
    limits = dict(DEFAULT_LIMITS)
    maxima = {'cpu_seconds': 120, 'wall_seconds': 180, 'memory_mb': 1024,
              'output_bytes': 4194304, 'file_bytes': 16777216, 'workspace_bytes': 67108864, 'workspace_files': 4096}
    for key, value in (config or {}).items():
        if key not in limits or type(value) is not int or value < 1 or value > maxima[key]:
            raise ValueError('Unsupported or unsafe isolation limit: ' + str(key))
        limits[key] = value
    return limits


def _runtime_paths():
    global _RUNTIME_CACHE
    if _RUNTIME_CACHE is not None:
        return _RUNTIME_CACHE
    executable = Path(sys.executable).resolve()
    framework_executable = Path(sys.base_prefix).resolve() / 'Resources/Python.app/Contents/MacOS/Python'
    if platform.system() == 'Darwin' and framework_executable.is_file():
        # Framework bin/python is a spawning launcher; start the actual runtime
        # directly so process-fork remains denied for the submitted program.
        executable = framework_executable
    roots = {Path(sysconfig.get_path('stdlib')).resolve(), Path(sys.base_prefix).resolve()}
    literals = {executable}
    # Read linker metadata of trusted runtime files, never candidate files.
    if platform.system() == 'Darwin' and Path('/usr/bin/otool').exists():
        extensions = sorted((Path(sysconfig.get_path('stdlib')) / 'lib-dynload').glob('*.so'))
        command = ['/usr/bin/otool', '-L', str(executable)] + [str(p) for p in extensions]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10, env={'PATH': '/usr/bin:/bin'})
        import re
        for path in re.findall(r'^\s+(/[^\n]+?)\s+\(compatibility version', result.stdout, re.M):
            item = Path(path)
            if item.exists(): literals.add(item.resolve())
    _RUNTIME_CACHE = (executable, sorted(roots), sorted(literals))
    return _RUNTIME_CACHE


def _mac_profile(workspace: Path, control_dir: Path | None = None):
    executable, roots, literals = _runtime_paths()
    read_roots = roots + [workspace, Path('/System/Library'), Path('/usr/lib')]
    if control_dir is not None: read_roots.append(control_dir)
    read_literals = literals + [Path('/'), Path('/dev/null'), Path('/dev/urandom'), Path('/dev/random')]
    ancestors = set()
    for path in read_roots + read_literals:
        ancestors.update(path.parents)
    forms = ['(version 1)', '(deny default)', '(deny network*)', '(deny process-fork)',
             '(allow process-exec (literal ' + json.dumps(str(executable)) + '))',
             '(allow sysctl-read)',
             '(allow file-map-executable ' + ' '.join('(subpath ' + json.dumps(str(p)) + ')' for p in roots + [Path('/System/Library'), Path('/usr/lib')]) + ' ' + ' '.join('(literal ' + json.dumps(str(p)) + ')' for p in literals) + ')',
             '(allow file-read* ' + ' '.join('(subpath ' + json.dumps(str(p)) + ')' for p in read_roots) + ' ' +
              ' '.join('(literal ' + json.dumps(str(p)) + ')' for p in read_literals) + ')',
             '(allow file-read-metadata ' + ' '.join('(literal ' + json.dumps(str(p)) + ')' for p in sorted(ancestors)) + ')',
             '(allow file-write* (subpath ' + json.dumps(str(workspace)) + ') (literal "/dev/null"))']
    return '\n'.join(forms)


def _bootstrap(entrypoint: str, limits: dict, workspace: Path):
    # Hard limits are installed inside the sandbox, before user code is loaded.
    # Avoid preexec_fn in the multithreaded application controller.
    return '''import os, sys, resource, runpy
L = ''' + repr(limits) + '''
resource.setrlimit(resource.RLIMIT_CPU, (L['cpu_seconds'], L['cpu_seconds']))
resource.setrlimit(resource.RLIMIT_FSIZE, (L['file_bytes'], L['file_bytes']))
resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
if hasattr(resource, 'RLIMIT_NPROC'):
    resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))
if hasattr(resource, 'RLIMIT_AS'):
    try: resource.setrlimit(resource.RLIMIT_AS, (L['memory_mb']*1024*1024, L['memory_mb']*1024*1024))
    except (OSError, ValueError): pass
os.chdir(''' + repr(str(workspace)) + ''')
sys.path.insert(0, ''' + repr(str(workspace)) + ''')
sys.argv = [''' + repr(entrypoint) + ''']
runpy.run_path(''' + repr(entrypoint) + ''', run_name='__main__')
'''


def capability() -> dict:
    system = platform.system()
    if system == 'Darwin':
        return {'available': Path('/usr/bin/sandbox-exec').is_file(), 'backend': 'macos-seatbelt', 'network': 'denied', 'subprocesses': 'denied'}
    if system == 'Linux':
        # A bwrap binary alone is insufficient: disabled user namespaces and
        # missing process-filter enforcement must never trigger bare execution.
        return {'available': False, 'backend': 'linux-bwrap', 'bwrap_found': bool(shutil.which('bwrap')),
                'reason': 'Linux seccomp/runtime allowlist has not been verified in this build; execution remains unavailable'}
    return {'available': False, 'backend': 'unavailable', 'reason': 'No verified OS sandbox for this platform'}


def _usage(workspace):
    total, count = 0, 0
    for base, dirs, files in os.walk(workspace, followlinks=False):
        for name in dirs + files:
            path = Path(base) / name
            if path.is_symlink():
                # Runtime symlinks cannot escape the OS sandbox; do not follow
                # them from the privileged controller either.
                continue
            if path.is_file():
                count += 1
                total += path.stat().st_size
    return total, count


def _rss(pid):
    if platform.system() == 'Darwin':
        result = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True, timeout=1,
                                env={'PATH': '/usr/bin:/bin'})
        try: return int(result.stdout.strip()) * 1024
        except ValueError: return None
    return None


def run_isolated(workspace, entrypoint, limits=None, cancelled: Callable[[], bool] | None = None) -> dict:
    limits = _limits(limits)
    workspace = Path(workspace).resolve()
    supplied_entry = Path(entrypoint)
    entry = supplied_entry if supplied_entry.is_absolute() else workspace / supplied_entry
    entry = entry.resolve()
    if not workspace.is_dir() or not entry.is_file() or not entry.is_relative_to(workspace):
        raise ValueError('Entrypoint must be an existing file inside the isolated workspace')
    for base, dirs, files in os.walk(workspace, followlinks=False):
        if any((Path(base) / name).is_symlink() for name in dirs + files):
            raise ValueError('Input workspace may not contain symlinks')
    workspace.chmod(0o700)
    total, files = _usage(workspace)
    if total > limits['workspace_bytes'] or files > limits['workspace_files']:
        raise ValueError('Initial workspace exceeds configured bounds')
    cancelled = cancelled or (lambda: False)
    info = capability()
    result = {'status': 'unsupported', 'returncode': None, 'stdout': '', 'stderr': '', 'sandbox': info,
              'limits': limits, 'elapsed_seconds': 0, 'termination_reason': None, 'network_calls': 0,
              'target_model_calls': 0, 'environment_inherited': False, 'memory_peak_bytes': None}
    if not info['available']:
        result['termination_reason'] = info.get('reason', 'Sandbox unavailable')
        return result
    if cancelled():
        result.update(status='cancelled', termination_reason='cancelled_before_start')
        return result
    control = Path(tempfile.mkdtemp(prefix='tokenclock-isolation-')).resolve()
    control.chmod(0o700)
    bootstrap = control / 'bootstrap.py'
    profile = control / 'sandbox.sb'
    bootstrap.write_text(_bootstrap(str(entry), limits, workspace)); bootstrap.chmod(0o600)
    profile.write_text(_mac_profile(workspace, control)); profile.chmod(0o600)
    executable = str(_runtime_paths()[0])
    command = ['/usr/bin/sandbox-exec', '-f', str(profile), executable, '-I', '-S', '-B', str(bootstrap)]
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'HOME': str(workspace), 'TMPDIR': str(workspace), 'PYTHONHASHSEED': '0'}
    started = time.monotonic()
    try:
        process = subprocess.Popen(command, cwd=workspace, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except BaseException:
        shutil.rmtree(control)
        raise
    result['sandbox']['control_files_readonly'] = True
    selector = selectors.DefaultSelector()
    buffers = {'stdout': bytearray(), 'stderr': bytearray()}
    for name, stream in [('stdout', process.stdout), ('stderr', process.stderr)]:
        os.set_blocking(stream.fileno(), False); selector.register(stream, selectors.EVENT_READ, name)
    reason = None
    kill_sent = False
    next_resource_check = started

    def stop(why):
        nonlocal reason, kill_sent
        reason = reason or why
        if not kill_sent and process.poll() is None:
            # Fork is denied by the OS profile. Signal this owned Popen child
            # once, avoiding repeated process-group signals during teardown.
            try: process.kill()
            except ProcessLookupError: pass
            kill_sent = True

    try:
        while selector.get_map():
            now = time.monotonic()
            if cancelled(): stop('cancelled')
            if now - started >= limits['wall_seconds']: stop('wall_limit')
            if now >= next_resource_check and process.poll() is None:
                peak = _rss(process.pid)
                if peak is not None:
                    result['memory_peak_bytes'] = max(result['memory_peak_bytes'] or 0, peak)
                    if peak > limits['memory_mb'] * 1024 * 1024: stop('memory_limit')
                size, count = _usage(workspace)
                if size > limits['workspace_bytes'] or count > limits['workspace_files']: stop('workspace_limit')
                next_resource_check = now + .15
            for key, _ in selector.select(.03):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj); continue
                remaining = max(0, limits['output_bytes'] - sum(len(data) for data in buffers.values()))
                buffers[key.data].extend(chunk[:remaining])
                if len(chunk) > remaining: stop('output_limit')
        process.wait(timeout=2)
    except BaseException:
        stop('controller_interrupted')
        process.wait(timeout=2)
        raise
    finally:
        selector.close(); process.stdout.close(); process.stderr.close()
        shutil.rmtree(control)
    result.update(returncode=process.returncode, stdout=bytes(buffers['stdout']).decode('utf-8', errors='replace'),
                  stderr=bytes(buffers['stderr']).decode('utf-8', errors='replace'), elapsed_seconds=time.monotonic() - started,
                  termination_reason=reason, status='cancelled' if reason == 'cancelled' else 'limited' if reason else 'completed' if process.returncode == 0 else 'failed')
    if process.returncode in (-signal.SIGXCPU, -signal.SIGKILL) and not reason:
        result['termination_reason'] = 'cpu_or_os_resource_limit'
        result['status'] = 'limited'
    if process.returncode == -signal.SIGXFSZ and not reason:
        result.update(termination_reason='file_size_limit', status='limited')
    if process.returncode and not reason and result['stderr'].rstrip().endswith('MemoryError'):
        result.update(termination_reason='memory_allocation_error_under_limit', status='limited')
    return result


def run_python(code: str, adapter: str, workspace, limits=None, cancelled=None):
    """Write explicit submitted/adapter strings to a scratch folder, then isolate."""
    workspace = Path(workspace)
    workspace.mkdir(parents=True, exist_ok=True); workspace.chmod(0o700)
    for name, text in [('submission.py', code), ('adapter.py', adapter)]:
        path = workspace / name
        if path.exists(): raise ValueError('Refusing to replace an existing runtime file')
        path.write_text(text); path.chmod(0o600)
    return run_isolated(workspace, 'adapter.py', limits, cancelled)
