"""Stage a Mac integration asset without installation, upload or release pins.

Produces the installer's standalone TokenClock + sibling resource bundle format,
plus an isolated .app for UI verification. Dependencies are supplied explicitly.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile


MAGICS={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}


def native_files(root):
    result=[]
    for path in root.rglob('*'):
        if not path.is_file() or path.is_symlink():continue
        with path.open('rb') as f:magic=f.read(4)
        if magic in MAGICS:result.append(path)
    return result


def package(binary,runtime,output):
    binary=Path(binary).resolve();runtime=Path(runtime).resolve();out=Path(output).resolve()
    if out.exists():raise ValueError('Existing integration package preserved')
    meta=json.loads((runtime/'runtime-manifest.json').read_text())
    arch=meta['architecture'];archs=subprocess.check_output(['/usr/bin/lipo','-archs',str(binary)],text=True).split()
    if meta['platform']!='darwin' or archs!=[arch]:raise ValueError('This internal package requires one matching binary/runtime architecture; it is not a universal release')
    original_bundle=binary.parent/'TokenClock_TokenClock.bundle'
    if not original_bundle.is_dir():raise ValueError('SwiftPM sibling resource bundle missing')
    stage=out/'standalone';stage.mkdir(parents=True)
    shutil.copy2(binary,stage/'TokenClock');bundle=stage/original_bundle.name
    shutil.copytree(original_bundle,bundle,symlinks=True)
    workers=list(bundle.rglob('model-integrity-worker/worker.py'))
    if len(workers)!=1:raise ValueError('Expected one bundled model detection worker')
    worker=workers[0].parent;deps=worker/'runtime'
    shutil.copytree(runtime,deps,symlinks=True)
    # Never ship bytecode generated in a developer's absolute filesystem path.
    # Worker, version probe and sandboxed evaluators all use Python -B.
    for directory in sorted(deps.rglob('__pycache__'),key=lambda p:len(p.parts),reverse=True):
        if directory.is_dir():shutil.rmtree(directory)
    for file in deps.rglob('*.pyc'):file.unlink()
    minima=[]
    for file in native_files(deps):
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(file)],check=True,capture_output=True)
        info=subprocess.run(['/usr/bin/vtool','-show-build',str(file)],check=True,capture_output=True,text=True).stdout
        minima.extend(tuple(int(v) for v in version.split('.')) for version in re.findall(r'\bminos\s+(\d+(?:\.\d+)+)',info))
    # Sign first, inventory second. The cache validates these actual distributed bytes.
    native_min='.'.join(str(x) for x in max(minima))
    meta['minimum_macos_browser_stack']=native_min
    meta['files']=[{'path':str(p.relative_to(deps)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size}
                   for p in sorted(deps.rglob('*')) if p.is_file() and not p.is_symlink() and p!=deps/'runtime-manifest.json']
    meta['bytes']=sum(row['bytes'] for row in meta['files'])
    (deps/'runtime-manifest.json').write_text(json.dumps(meta,indent=2)+'\n')
    wm=json.loads((worker/'manifest.json').read_text());wm.update(python_interpreter_included=True,bundled_architecture=arch,
        minimum_macos_core='26.0',minimum_macos_browser_stack=native_min,dependency_manifest_sha256=hashlib.sha256((deps/'runtime-manifest.json').read_bytes()).hexdigest())
    (worker/'manifest.json').write_text(json.dumps(wm,indent=2)+'\n')
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(stage/'TokenClock')],check=True,capture_output=True)
    archive=out/f'TokenClock-glass-{arch}-model-detect-integration.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        tar.add(stage/'TokenClock',arcname='TokenClock');tar.add(bundle,arcname=bundle.name)
    app=out/'TokenClock Glass Quick Check.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True);(contents/'Resources').mkdir()
    shutil.copy2(stage/'TokenClock',contents/'MacOS/TokenClock');shutil.copytree(bundle,contents/'Resources'/bundle.name,symlinks=True)
    info={'CFBundleName':'TokenClock Glass Quick Check','CFBundleDisplayName':'TokenClock Glass Quick Check','CFBundleIdentifier':'com.tokenclock.model-detect.glass.quick-check',
          'CFBundleExecutable':'TokenClock','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.11.0','CFBundleVersion':'2026101601',
          'LSMinimumSystemVersion':'26.0','LSUIElement':True,'NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    receipt={'schema':'tokenclock-maintained-macos-integration-package/v1','app':str(app),'standalone':str(stage),'archive':str(archive),
        'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'worker_sha256':wm['runtime_sha256'],
        'dependency_manifest_sha256':wm['dependency_manifest_sha256'],'architecture':arch,'universal':False,
        'minimum_macos_core':'26.0','minimum_macos_browser_stack':native_min,'installed':False,'published':False,'notarized':False,
        'runtime_inventory_after_signing':True,'sibling_resource_bundle_present':True,
        'integration_version':'0.11.0','integration_build':'2026101601'}
    (out/'package-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--runtime',required=True);p.add_argument('--output',required=True);a=p.parse_args()
    print(json.dumps(package(a.binary,a.runtime,a.output)))
