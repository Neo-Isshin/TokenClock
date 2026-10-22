"""Package only runtime code and aggregate references; never research records."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[1]
DEST=ROOT/'Sources/TokenClock/Resources/model-integrity-worker'
MODULES=['__init__.py','__main__.py','cli.py','engine.py','ingest.py','sources.py','render.py','model_fields.py',
         'pipeline.py','semantic.py','references.py','verification.py','jobs.py','catalog.py','webui.py',
         'connections.py','capabilities.py','preview.py','model_catalog.py']


def build(destination=DEST):
    import sys
    if str(ROOT) not in sys.path:sys.path.insert(0,str(ROOT))
    from scripts.model_integrity.probes.reference_release import verify_bundle
    verify_bundle()  # Reject incomplete or inconsistent references before packaging.
    from scripts.model_integrity.probes.numeric_fingerprint import reference as numeric_reference
    numeric_reference()  # Hash-pinned adopted external method, separate from local validation.
    destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    prefix='scripts/model_integrity/l1/'
    selected={prefix+name:ROOT/prefix/name for name in MODULES}
    selected['scripts/model_integrity/m10_features.py']=ROOT/'scripts/model_integrity/m10_features.py'
    for name in ('index.html','style.css','app.js'):
        selected[prefix+'web/'+name]=ROOT/prefix/'web'/name
    selected[prefix+'resources/behavior-reference-v1.json']=ROOT/prefix/'resources/behavior-reference-v1.json'
    probe_prefix='scripts/model_integrity/probes/'
    for path in sorted((ROOT/probe_prefix).glob('*.py')):
        if path.name.startswith('build_'):continue  # offline reference builder is not a product runtime entry
        selected[probe_prefix+path.name]=path
    selected[probe_prefix+'browser_driver.cjs']=ROOT/probe_prefix/'browser_driver.cjs'
    for path in sorted((ROOT/probe_prefix/'resources').glob('*.json')):
        selected[probe_prefix+'resources/'+path.name]=path
    missing=[str(path) for path in selected.values() if not path.is_file()]
    if missing:raise ValueError('Runtime files missing: '+', '.join(missing))
    bindings=[]
    with zipfile.ZipFile(destination/'runtime.zip','w',compression=zipfile.ZIP_DEFLATED) as archive:
        for name in ('scripts/__init__.py','scripts/model_integrity/__init__.py'):
            info=zipfile.ZipInfo(name,date_time=(2026,1,1,0,0,0));archive.writestr(info,b'')
        for name,path in sorted(selected.items()):
            body=path.read_bytes();info=zipfile.ZipInfo(name,date_time=(2026,1,1,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED;archive.writestr(info,body)
            bindings.append({'path':name,'sha256':hashlib.sha256(body).hexdigest(),'bytes':len(body)})
    bootstrap='''"""TokenClock product worker; Python core and aggregate references, no private responses."""
import sys
import os
from pathlib import Path
if sys.version_info < (3,10):
    raise SystemExit("TokenClock L1 requires Python 3.10 or later")
worker_root=Path(__file__).resolve().parent
if (worker_root/"runtime/runtime-manifest.json").is_file():
    os.environ["TOKENCLOCK_MODEL_INTEGRITY_RUNTIME"]=str(worker_root/"runtime")
sys.path.insert(0,str(worker_root/"runtime.zip"))
from scripts.model_integrity.l1.cli import main
raise SystemExit(main())
'''
    (destination/'worker.py').write_text(bootstrap)
    result={'schema':'tokenclock-l1-runtime-bundle/v1','files':bindings,
            'research_raw_records_included':False,'credentials_included':False,
            'python_interpreter_included':False,'minimum_python':'3.10','optional_runtime':{'h01_h03':'verified OS sandbox','h02_h04':'Node.js + Playwright + verified OS network guard'},
            'runtime_sha256':hashlib.sha256((destination/'runtime.zip').read_bytes()).hexdigest()}
    (destination/'manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    return result


if __name__=='__main__':
    result=build();print(json.dumps({'files':len(result['files']),'destination':str(DEST),'runtime_sha256':result['runtime_sha256']}))
