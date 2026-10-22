"""Bounded Node/browser subprocess support; no candidate code runs in Python."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid
import sys
from importlib import resources
import re
import stat
import platform

ROOT = Path(__file__).resolve().parents[3]
NODE_DEFAULT = Path(os.environ.get('TOKENCLOCK_MODEL_INTEGRITY_NODE') or shutil.which('node') or '/usr/local/bin/node')
_NODE_PREFIX = NODE_DEFAULT.resolve().parent.parent
MODULES_DEFAULT = Path(os.environ.get('TOKENCLOCK_MODEL_INTEGRITY_NODE_MODULES') or
    next((str(p) for p in (_NODE_PREFIX/'node_modules',_NODE_PREFIX/'lib/node_modules') if p.is_dir()),'/usr/local/lib/node_modules'))


def runtime_paths(config):
    """Explicit overrides, then app runtime, then developer host dependencies."""
    bundled = Path(os.environ['TOKENCLOCK_MODEL_INTEGRITY_RUNTIME']) if os.environ.get('TOKENCLOCK_MODEL_INTEGRITY_RUNTIME') else None
    manifest = {};metadata={}
    if bundled and (bundled/'runtime-manifest.json').is_file():
        try:
            metadata = json.loads((bundled/'runtime-manifest.json').read_text());manifest=metadata.get('paths', {})
            for key, value in list(manifest.items()):
                resolved=(bundled/value).resolve()
                if not resolved.is_relative_to(bundled.resolve()):raise ValueError('Runtime path escapes its bundle')
                manifest[key]=str(resolved)
        except (OSError, ValueError, TypeError):manifest={}
    node=config.get('node_path') or manifest.get('node_path') or (str(NODE_DEFAULT) if NODE_DEFAULT.is_file() else shutil.which('node'))
    modules=config.get('node_modules_path') or config.get('node_modules') or manifest.get('node_modules_path') or str(MODULES_DEFAULT)
    browser=config.get('browser_executable') or config.get('browser_path') or manifest.get('browser_executable')
    if not browser:
        browser=next((p for p in ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','/usr/bin/chromium','/usr/bin/google-chrome'] if Path(p).is_file()),None)
    unavailable=None
    if manifest and not all(config.get(k) for k in ('node_path','node_modules_path','browser_executable')):
        minimum=metadata.get('minimum_macos_browser_stack')
        if sys.platform=='darwin' and minimum:
            try:
                if tuple(map(int,platform.mac_ver()[0].split('.')))<tuple(map(int,minimum.split('.'))):unavailable='Browser verification requires macOS '+minimum+' or later; local/text checks remain available.'
            except ValueError:unavailable='Unable to verify the browser runtime system requirement.'
        if metadata.get('architecture') and metadata['architecture']!=platform.machine():unavailable='Bundled browser runtime architecture differs from this process.'
    return {'node_path':node,'node_modules_path':modules,'browser_executable':browser,'bundled':bool(manifest),'unavailable_reason':unavailable}


def _disk_usage(directory, file_cap=20000):
    total=count=0
    for base, dirs, files in os.walk(directory,followlinks=False):
        dirs[:]=[d for d in dirs if not (Path(base)/d).is_symlink()]
        for name in files:
            try:
                info=(Path(base)/name).stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):total+=info.st_size;count+=1
            if count>file_cap:return total,count
    return total,count


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    path.chmod(0o600)


def source_metadata(raw, config):
    result = {'sha256': hashlib.sha256(raw).hexdigest(),
              'kind': config.get('source_kind', 'real_artifact')}
    if result['kind'] not in {'real_artifact', 'controlled_variant', 'synthetic_fixture'}:
        result['kind'] = 'real_artifact'
    for key in ('label_source', 'requested_model', 'reported_model', 'record_origin_label'):
        if isinstance(config.get(key), str):
            result[key] = config[key][:200]
    return result


def check(identifier, status, observed, group, *, mandatory=True, dimension='能力与交付', reason=None, evidence=()):
    result = {'id': identifier, 'status': status, 'observed': observed, 'dimension': dimension,
              'group': group, 'mandatory': mandatory, 'evidence': list(evidence)}
    if reason:
        result['reason'] = reason
    return result


def run_driver(mode, input_path, output_dir, config, cancelled=None):
    cancelled = cancelled or (lambda: False)
    output_dir = Path(output_dir)
    def unsupported(reason):
        result={'driver_status':'unsupported','error':reason,'actions':[],'screenshots':[],'checks':[]}
        save(output_dir/'browser-result.json',result);return result
    config = {**config, **{key:value for key,value in runtime_paths(config).items() if value is not None}}
    if config.get('unavailable_reason'):return unsupported(config['unavailable_reason'])
    node = config.get('node_path')
    if not node or not Path(node).is_file():
        return unsupported('Node.js unavailable')
    if sys.platform != 'darwin' or not Path('/usr/bin/sandbox-exec').is_file():
        return unsupported('A verified OS network sandbox is required; no bare-browser fallback is used.')
    limits = {'wall_seconds': min(300, max(2, float(config.get('wall_seconds', 120)))),
              'max_steps': min(80, max(4, int(config.get('max_steps', 60)))),
              'max_output_bytes': min(64 * 1024 * 1024, max(1024 * 1024, int(config.get('max_output_bytes', 24 * 1024 * 1024)))),
              'max_profile_bytes':128*1024*1024,'max_profile_files':10000,'node_heap_mb':256,
              'navigation_no_progress_attempts':2}
    screenshot_id = uuid.uuid4().hex
    screenshot_dir = output_dir / 'screenshots' / screenshot_id
    screenshot_dir.mkdir(parents=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='tc-l3-', dir='/private/tmp') as scratch, socket.socket() as canary, tempfile.NamedTemporaryFile(prefix='tc-l3-canary-',dir='/private/tmp') as file_canary:
        file_canary.write(b'OUTSIDE_SANDBOX_CONTENT');file_canary.flush()
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0)); artifact_port = reservation.getsockname()[1]
        canary.bind(('127.0.0.1', 0));canary.listen(1);canary.setblocking(False)
        canary_port = canary.getsockname()[1];canary_connections = 0
        settings = {'mode': mode, 'input_path': str(Path(input_path).resolve()), 'output_dir': str(output_dir.resolve()),
                    'screenshot_dir': str(screenshot_dir.resolve()), 'profile': str(Path(scratch) / 'profile'),
                    'limits': limits, 'annotation': config.get('annotation'),
                    'browser_executable': config.get('browser_executable') or config.get('browser_path'), 'full_page': config.get('full_page') is True,
                    'artifact_port': artifact_port, 'network_canary_port': canary_port,
                    'filesystem_canary': file_canary.name}
        settings_path = Path(scratch) / 'config.json'
        save(settings_path, settings)
        driver_path = Path(scratch) / 'browser_driver.cjs'
        driver_path.write_bytes(resources.files(__package__).joinpath('browser_driver.cjs').read_bytes())
        driver_path.chmod(0o600)
        profile = Path(scratch) / 'network.sb'
        scoped_tmp = Path(scratch).resolve() / 'tmp';scoped_tmp.mkdir(mode=0o700)
        socket_scope = json.dumps(str(Path(scratch).resolve()))
        # macOS Chromium chooses its ProcessSingleton socket with confstr(),
        # independently of TMPDIR. This is local Unix IPC, not IP networking.
        chrome_socket_scope = json.dumps(str(Path(tempfile.gettempdir()).resolve()))
        chrome_temp_pattern = json.dumps('^' + re.escape(str(Path(tempfile.gettempdir()).resolve())) + r'/com\.google\.Chrome\.[^/]+(/.*)?$')
        readable = ['/System','/usr','/bin','/sbin','/Library','/private/etc',str(Path(node).resolve().parent.parent),
                    str(Path(config.get('node_modules_path') or config.get('node_modules') or MODULES_DEFAULT).resolve()),
                    '/Applications/Google Chrome.app',str(Path(scratch).resolve()),str(output_dir.resolve())]
        if config.get('browser_executable') or config.get('browser_path'):
            readable.append(str(Path(config.get('browser_executable') or config.get('browser_path')).resolve().parent.parent.parent))
        filesystem_rules='(deny file-read-data)\n(deny file-write*)\n'
        filesystem_rules+=''.join(f'(allow file-read-data (subpath {json.dumps(p)}))\n' for p in readable)
        filesystem_rules+='(allow file-read-data (literal "/") (subpath "/dev"))\n(allow file-write* (literal "/dev/null"))\n'
        filesystem_rules+=''.join(f'(allow file-write* (subpath {json.dumps(str(p.resolve()))}))\n' for p in (Path(scratch),output_dir))
        filesystem_rules+=f'(allow file-read-data file-write* (regex {chrome_temp_pattern}))\n'
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n'
            f'(allow network-bind (local ip "localhost:{artifact_port}"))\n'
            f'(allow network-inbound (local ip "localhost:{artifact_port}"))\n'
            f'(allow network-outbound (remote ip "localhost:{artifact_port}"))\n'
            f'(allow network-bind (local unix-socket (subpath {socket_scope})))\n'
            f'(allow network-inbound (local unix-socket (subpath {socket_scope})))\n'
            f'(allow network-outbound (remote unix-socket (subpath {socket_scope})))\n'
            f'(allow network-bind (local unix-socket (subpath {chrome_socket_scope})))\n'
            f'(allow network-inbound (local unix-socket (subpath {chrome_socket_scope})))\n'
            f'(allow network-outbound (remote unix-socket (subpath {chrome_socket_scope})))\n'+filesystem_rules)
        (output_dir/'network-profile.sb').write_bytes(profile.read_bytes());(output_dir/'network-profile.sb').chmod(0o600)
        env = {'PATH': str(Path(node).parent) + ':/usr/bin:/bin:/usr/sbin:/sbin',
               'LANG': 'en_US.UTF-8', 'HOME': str(Path(scratch).resolve())}
        env['NODE_PATH'] = str(config.get('node_modules_path') or config.get('node_modules') or MODULES_DEFAULT)
        env['TMPDIR'] = str(scoped_tmp) + '/'
        logs = output_dir / 'driver-stderr.txt'
        with logs.open('wb') as error, (output_dir / 'driver-stdout.txt').open('wb') as stdout:
            process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(profile), str(node), '--max-old-space-size=256', str(driver_path), str(settings_path)],
                                       stdout=stdout, stderr=error, env=env, cwd=str(Path(scratch).resolve()), start_new_session=(os.name != 'nt'))
            started = time.monotonic()
            stopped = None
            while process.poll() is None:
                try:
                    connection, _ = canary.accept();canary_connections += 1;connection.close()
                except BlockingIOError:
                    pass
                if cancelled():
                    stopped = 'cancelled'
                elif time.monotonic() - started > limits['wall_seconds']:
                    stopped = 'wall_limit'
                elif _disk_usage(output_dir)[0] > limits['max_output_bytes']:
                    stopped = 'output_limit'
                else:
                    profile_bytes,profile_files=_disk_usage(scratch,limits['max_profile_files'])
                    if profile_files>limits['max_profile_files'] or profile_bytes>limits['max_profile_bytes']:
                        stopped='profile_storage_limit'
                if stopped:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        if os.name != 'nt':
                            os.killpg(process.pid, signal.SIGKILL)
                        else:
                            process.kill()
                        process.wait(timeout=5)
                    break
                time.sleep(.05)
        for p in (logs, output_dir / 'driver-stdout.txt'):
            p.chmod(0o600)
        result_path = output_dir / 'browser-result.json'
        if result_path.is_file():
            result = json.loads(result_path.read_text())
        else:
            result = {'driver_status': 'unsupported' if process.returncode else 'failed',
                      'error': 'Browser driver unavailable or stopped; see bounded local stderr.'}
        if stopped:
            result.update(driver_status='cancelled' if stopped == 'cancelled' else 'limited', stop_reason=stopped)
        result['limits'] = limits
        result['process_returncode'] = process.returncode
        result['network_sandbox'] = {'kind': 'macos_sandbox_exec_network_and_file_scopes',
            'allowed_remote': f'localhost:{artifact_port}', 'canary_connections': canary_connections,
            'verified': result.get('network_guard', {}).get('blocked_connect_error') in {'EPERM','EACCES'} and canary_connections == 0,
            'filesystem_read_guard_verified': result.get('network_guard', {}).get('blocked_read_error') in {'EPERM','EACCES'},
            'chromium_inner_sandbox': False,
            'policy_note': 'Outer macOS file/network sandbox replaces incompatible nested Chromium sandbox; only task paths and runtime/system files readable, task/Chromium temporary paths writable.'}
        result['elapsed_seconds'] = round(time.monotonic() - started, 4)
        result['screenshot_directory'] = str(screenshot_dir)
        if ROOT.is_dir() and (ROOT / 'Package.swift').is_file():
            skill_dir = ROOT / 'output/playwright/l3' / screenshot_id
            skill_dir.mkdir(parents=True, mode=0o700)
            for screenshot in screenshot_dir.glob('*.png'):
                shutil.copyfile(screenshot, skill_dir / screenshot.name)
                (skill_dir / screenshot.name).chmod(0o600)
            result['playwright_skill_copy_directory'] = str(skill_dir)
        save(output_dir/'browser-result.json',result)
        return result
