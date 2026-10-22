"""Shared serialization and evidence helpers, with no network or code execution."""
from __future__ import annotations

import hashlib
import json
import os
import uuid
from pathlib import Path


def canonical(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def digest(value):return hashlib.sha256(canonical(value)).hexdigest()


def write_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.parent.chmod(0o700)
    raw=json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False).encode()+b'\n'
    if path.is_symlink():raise ValueError('Evidence path cannot be a symlink')
    temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex+'.tmp')
    try:
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
        with os.fdopen(fd,'wb') as f:
            f.write(raw);f.flush();os.fsync(f.fileno())
        os.replace(temporary,path)
        path.chmod(0o600)
    finally:
        if temporary.exists():temporary.unlink()



def load_json(path,max_bytes=32*1024*1024):
    from scripts.model_integrity.l1.ingest import strict_loads
    p=Path(path)
    if p.stat().st_size>max_bytes:raise ValueError('Input exceeds byte limit')
    with p.open('rb') as f:raw=f.read(max_bytes+1)
    if len(raw)>max_bytes:raise ValueError('Input grew beyond byte limit')
    return strict_loads(raw.decode('utf-8-sig'))


def cancelled(check):
    if check and check():raise InterruptedError('用户已取消')


def archive_evidence(root,destination,max_bytes=128*1024*1024):
    import zipfile
    root=Path(root);destination=Path(destination);size=0;included=[];omitted=[]
    with zipfile.ZipFile(destination,'w',zipfile.ZIP_DEFLATED) as archive:
        for p in sorted(root.rglob('*')):
            if p==destination or p.is_symlink() or not p.is_file():continue
            relative=p.relative_to(root).as_posix()
            if size+p.stat().st_size>max_bytes:
                omitted.append(relative);continue
            size+=p.stat().st_size;archive.write(p,relative);included.append(relative)
        archive.writestr('archive-manifest.json',json.dumps({'schema':'tokenclock-evidence-archive/v1','included':included,'omitted_by_size_bound':omitted,'uncompressed_bytes':size,'partial':bool(omitted)},ensure_ascii=False))
    destination.chmod(0o600)
    return destination
