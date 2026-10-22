"""Explicit connection profiles. Public configuration never contains credentials."""
from __future__ import annotations

import copy
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import threading
import uuid
from urllib.parse import urlsplit, unquote


class Keychain:
    """macOS generic passwords via Security.framework; no password in argv or disk."""
    kind = 'macos_keychain'

    def __init__(self, namespace):
        self.namespace = namespace
        self.cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.sec = C.CDLL('/System/Library/Frameworks/Security.framework/Security')
        for name, args, result in [
            ('CFStringCreateWithCString', [C.c_void_p, C.c_char_p, C.c_uint32], C.c_void_p),
            ('CFDataCreate', [C.c_void_p, C.c_void_p, C.c_long], C.c_void_p),
            ('CFDictionaryCreate', [C.c_void_p, C.c_void_p, C.c_void_p, C.c_long, C.c_void_p, C.c_void_p], C.c_void_p),
            ('CFDataGetLength', [C.c_void_p], C.c_long),
            ('CFDataGetBytePtr', [C.c_void_p], C.c_void_p),
            ('CFRelease', [C.c_void_p], None),
        ]:
            fn = getattr(self.cf, name); fn.argtypes = args; fn.restype = result
        for name in ('SecItemAdd', 'SecItemCopyMatching', 'SecItemUpdate'):
            fn = getattr(self.sec, name); fn.argtypes = [C.c_void_p, C.c_void_p]; fn.restype = C.c_int32
        self.sec.SecItemDelete.argtypes = [C.c_void_p]; self.sec.SecItemDelete.restype = C.c_int32

    def _constant(self, name):
        return C.c_void_p.in_dll(self.sec, name).value

    def _query(self, identifier, *, secret=None, fetch=False):
        owned = []
        def string(value):
            result = self.cf.CFStringCreateWithCString(None, value.encode(), 0x08000100)
            owned.append(result); return result
        pairs = [(self._constant('kSecClass'), self._constant('kSecClassGenericPassword')),
                 (self._constant('kSecAttrService'), string(self.namespace)),
                 (self._constant('kSecAttrAccount'), string(identifier)),
                 # Never cause a hidden worker to block on a system authentication dialog.
                 (self._constant('kSecUseAuthenticationUI'), self._constant('kSecUseAuthenticationUIFail'))]
        if secret is not None:
            raw = secret.encode(); data = self.cf.CFDataCreate(None, raw, len(raw)); owned.append(data)
            pairs.append((self._constant('kSecValueData'), data))
        if fetch:
            pairs.extend([(self._constant('kSecReturnData'), C.c_void_p.in_dll(self.cf, 'kCFBooleanTrue').value),
                          (self._constant('kSecMatchLimit'), self._constant('kSecMatchLimitOne'))])
        keys = (C.c_void_p * len(pairs))(*(p[0] for p in pairs))
        values = (C.c_void_p * len(pairs))(*(p[1] for p in pairs))
        # NULL callbacks: values are kept alive explicitly until the Security call returns.
        query = self.cf.CFDictionaryCreate(None, keys, values, len(pairs), None, None)
        return query, owned

    def _release(self, query, owned):
        self.cf.CFRelease(query)
        for value in owned: self.cf.CFRelease(value)

    def get(self, identifier):
        query, owned = self._query(identifier, fetch=True); data = C.c_void_p()
        try:
            status = self.sec.SecItemCopyMatching(query, C.byref(data))
            if status == -25300: return None
            if status: raise ValueError('系统钥匙串当前不可用；可改为仅本次会话保存')
            try: return C.string_at(self.cf.CFDataGetBytePtr(data), self.cf.CFDataGetLength(data)).decode()
            finally: self.cf.CFRelease(data)
        finally: self._release(query, owned)

    def put(self, identifier, secret):
        # A new immutable profile ID is allocated for every save; no delete-before-write.
        query, owned = self._query(identifier, secret=secret)
        try:
            if self.sec.SecItemAdd(query, None):
                raise ValueError('系统钥匙串未保存密钥；可改为仅本次会话保存')
        finally: self._release(query, owned)

    def delete(self, identifier):
        query, owned = self._query(identifier)
        try:
            status = self.sec.SecItemDelete(query)
            if status not in (0, -25300): raise ValueError('系统钥匙串未能删除该密钥')
        finally: self._release(query, owned)


class ConnectionStore:
    def __init__(self, directory, vault=None):
        self.directory = Path(directory); self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        self.path = self.directory / 'profiles.json'
        self.lock = threading.RLock(); self.memory = {}
        namespace = 'TokenClock.ModelDetect.' + hashlib.sha256(str(self.directory.resolve()).encode()).hexdigest()[:24]
        self.vault = vault
        if vault is None and sys.platform == 'darwin':
            try: self.vault = Keychain(namespace)
            except (OSError, AttributeError): pass
        self.profiles = {}
        if self.path.exists():
            if self.path.is_symlink() or self.path.stat().st_mode & 0o077: raise ValueError('连接配置权限无效')
            rows = json.loads(self.path.read_text()).get('profiles', [])
            for row in rows:
                identifier = row.get('id', '')
                if not re.fullmatch(r'[a-f0-9]{32}', identifier): raise ValueError('连接ID无效')
                validated = self._public(row)
                validated.update(id=identifier, secret_storage=row.get('secret_storage', 'session'))
                self.profiles[identifier] = validated

    @staticmethod
    def _public(value):
        result = {}
        for key, maximum in [('name', 80), ('endpoint', 2048), ('model', 200), ('api_format', 40)]:
            raw = value.get(key)
            if not isinstance(raw, str) or not raw.strip() or len(raw) > maximum or any(ord(c) < 32 for c in raw):
                raise ValueError('连接名称、接口、型号和格式必须完整有效')
            result[key] = raw.strip()
            decoded=result[key]
            for _ in range(4):decoded=unquote(decoded)
            if re.search(r'(?i)sk-(?:or-v\d+-)?[A-Za-z0-9_-]{12,}',decoded):
                raise ValueError('连接公开字段不能包含API密钥，请只在密钥栏输入')
        url = urlsplit(result['endpoint'])
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError('连接地址需为不含密钥、查询参数和片段的HTTPS接口')
        if result['api_format'] not in {'responses', 'messages', 'chat_completions'}: raise ValueError('接口格式无效')
        for key in ('input_usd_per_million', 'output_usd_per_million'):
            n = value.get(key)
            if isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) or not 0 <= n <= 10000:
                raise ValueError('请填写有效输入和输出单价')
            result[key] = n
        return result

    def _write(self):
        from ..probes.common import write_json
        write_json(self.path, {'schema': 'tokenclock-connection-profiles/v1', 'profiles': list(self.profiles.values())})

    def list(self):
        with self.lock:
            rows = []
            for value in self.profiles.values():
                row = dict(value)
                # Listing never reads keychain secrets or causes an authentication prompt.
                row['credential_state'] = 'system_store' if row['secret_storage'] == 'keychain' else ('session' if row['id'] in self.memory else 'needs_key')
                rows.append(row)
            return {'profiles': rows, 'system_secret_storage': self.vault.kind if self.vault else None}

    def save(self, value):
        public = self._public(value)
        secret = value.get('api_key')
        if not isinstance(secret, str) or not 1 <= len(secret) <= 8192 or any(ord(c) < 32 for c in secret):
            raise ValueError('保存连接需要有效密钥')
        for field in ('name','endpoint','model','api_format'):
            public_text=public[field]
            for _ in range(4):
                if secret in public_text:raise ValueError('连接公开字段含有本次密钥，未保存连接')
                public_text=unquote(public_text)
            if secret in public_text:raise ValueError('连接公开字段含有本次密钥，未保存连接')
        storage = value.get('secret_storage', 'session')
        if storage not in {'session', 'keychain'}: raise ValueError('密钥保存方式无效')
        identifier = uuid.uuid4().hex
        with self.lock:
            if storage == 'keychain':
                if not self.vault: raise ValueError('此系统尚未提供安全密钥存储，请使用仅本次会话')
                self.vault.put(identifier, secret)
            else: self.memory[identifier] = secret
            public.update(id=identifier, secret_storage=storage)
            self.profiles[identifier] = public
            try: self._write()
            except Exception:
                self.profiles.pop(identifier, None); self.memory.pop(identifier, None)
                if storage == 'keychain': self.vault.delete(identifier)
                raise
            return {'profile': dict(public)}

    def delete(self, identifier):
        with self.lock:
            row = self.profiles[identifier]
            if row['secret_storage'] == 'keychain':
                if not self.vault: raise ValueError('系统密钥存储不可用，未删除连接')
                self.vault.delete(identifier)
            self.memory.pop(identifier, None); del self.profiles[identifier]; self._write()
            return {'deleted': identifier}

    def resolve(self, config, *, preview=False):
        """Resolve only explicit runtime selections, never imported evidence/configuration."""
        result = copy.deepcopy(config)
        assessment=result.get('assessment') or {}
        if not isinstance(assessment,dict):raise ValueError('评审配置无效')
        providers = [result.get('provider'), assessment.get('provider') if assessment.get('connection_source','separate')!='target' else None, result.get('external')]
        with self.lock:
            for provider in providers:
                if not isinstance(provider, dict) or not provider.get('connection_id'): continue
                identifier = provider.pop('connection_id'); saved = self.profiles.get(identifier)
                if not saved: raise ValueError('所选连接已不存在')
                for field in ('endpoint', 'api_format', 'model'):
                    if provider.get(field, saved[field]) != saved[field]:
                        raise ValueError('接口、格式或型号已改变，请重新填写密钥并另存连接')
                    provider[field] = saved[field]
                if preview:
                    provider.pop('api_key',None)
                    continue  # Cost previews do not retrieve a secret or authorize a call.
                if provider.get('api_key'): continue
                secret = self.memory.get(identifier)
                if saved['secret_storage'] == 'keychain' and self.vault: secret = self.vault.get(identifier)
                if not secret: raise ValueError('此连接需要重新输入密钥')
                provider['api_key'] = secret
        from ..probes.review_config import resolve_shared_review
        return resolve_shared_review(result,include_secret=not preview)
