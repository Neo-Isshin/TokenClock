"""Independent H03 pipeline checks using only OS-isolated candidate processes.

The public task snapshot has no hidden answers. Hidden projects and compiler
expectations live in a separate evaluator scratch; expected outcomes are
computed in this controller, never returned by candidate-supplied graders.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from importlib.resources import files as resource_files
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile
import time

from .isolation import run_isolated

RESOURCE = resource_files(__package__).joinpath('resources/h03_pipeline.json')


def pipeline_task():
    task = json.loads(RESOURCE.read_text(encoding='utf-8'))
    task['id'] = 'H03:pipeline'
    return task


def _save(path, value):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True); path.parent.chmod(0o700)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n'); path.chmod(0o600)


def _safe_path(root, relative):
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()): raise ValueError('Evaluator path escapes scratch')
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink(): raise ValueError('Evaluator refuses candidate-created symlink')
    return path


def _write(root, relative, text):
    path = _safe_path(root,relative); path.parent.mkdir(parents=True,exist_ok=True)
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|getattr(os,'O_NOFOLLOW',0),0o600)
    with os.fdopen(descriptor,'w') as handle: handle.write(text)
    return path


def _read(root, relative):
    path=_safe_path(root,relative)
    if path.stat().st_size>1048576: raise ValueError('Evaluator cache-read limit')
    return path.read_bytes()


def _project(root, nodes):
    name='project-'+secrets.token_hex(6)
    manifest={'nodes':{}}
    for node,(source,deps) in nodes.items():
        _write(root,name+'/src/'+node+'.txt',source)
        manifest['nodes'][node]={'source':'src/'+node+'.txt','dependencies':deps}
    _write(root,name+'/pipeline.json',json.dumps(manifest))
    return name


def _expected(nodes, target):
    source,deps=nodes[target]
    return target+'<'+source.strip()+'>['+','.join(dep+'='+_expected(nodes,dep) for dep in sorted(set(deps)))+']'


WORKER = r'''import os, sys, json, importlib, time, io, unittest
from pathlib import Path
REQUEST = __REQUEST__
FRAME = __FRAME__

def dispatch(request, importer=importlib.import_module, path_class=Path, pause=time.sleep, clock=time.monotonic):
    root=path_class('.')
    sys.path.insert(0,str((root/'candidate').resolve()))
    if request.get('public'):
        suite=unittest.defaultTestLoader.discover(str(root/'candidate/tests'),pattern='test_*.py')
        stream=io.StringIO()
        result=unittest.TextTestRunner(stream=stream,verbosity=0).run(suite)
        return {'public':{'tests_run':result.testsRun,'successful':result.wasSuccessful(),
                         'failures':[str(t) for t,_ in result.failures],'errors':[str(t) for t,_ in result.errors]}}
    api=importer('buildpipe')
    calls=[]
    def compiler(name,source,dependencies):
        calls.append(name)
        if request.get('delay'): pause(request['delay'])
        if name==request.get('fail_on'): raise RuntimeError('injected compiler failure')
        return name+'<'+source.strip()+'>['+','.join(dep+'='+dependencies[dep] for dep in sorted(dependencies))+']'
    barrier=request.get('barrier')
    if barrier:
        (root/barrier['ready']).write_text('ready')
        deadline=clock()+8
        while not (root/barrier['go']).exists():
            if clock()>deadline: raise TimeoutError('barrier timed out')
            pause(.01)
    try:
        result=api.Pipeline(root/request['cache'],compiler).build(root/request['project'],request['targets'])
        return {'exception':None,'calls':calls,'result':{'outputs':dict(result.outputs),'built':list(result.built),'reused':list(result.reused)}}
    except BaseException as exc:
        return {'exception':type(exc).__name__,'calls':calls,'result':None}

def main():
    write=os.write; dumps=json.dumps; dispatch_local=dispatch; request=REQUEST; frame=FRAME
    os.unlink(__file__)
    try: payload=dispatch_local(request)
    except BaseException as exc: payload={'worker_exception':type(exc).__name__}
    write(1,(frame+dumps(payload,ensure_ascii=False,separators=(',',':'))+'\n').encode())
main()
'''


class Unobserved(RuntimeError): pass


class Evaluator:
    def __init__(self,scratch,output,config,cancelled):
        self.scratch,self.output,self.config,self.cancelled=scratch,output,config,cancelled
        self.receipts=[]
    def rpc(self,action):
        if self.cancelled and self.cancelled(): raise Unobserved('cancelled')
        token=secrets.token_hex(12); frame='RESULT_'+token+' '
        name='worker-'+token+'.py'
        path=_safe_path(self.scratch,name)
        descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
        with os.fdopen(descriptor,'w') as handle:
            handle.write(WORKER.replace('__REQUEST__',repr(action)).replace('__FRAME__',repr(frame)))
        execution=run_isolated(self.scratch,name,self.config.get('limits'),self.cancelled)
        receipt_path=self.output/('execution-'+token+'.json')
        _save(receipt_path,execution)
        self.receipts.append(str(receipt_path))
        if execution['status']!='completed': raise Unobserved(execution['status']+': '+str(execution.get('termination_reason')))
        framed=[line[len(frame):] for line in execution['stdout'].splitlines() if line.startswith(frame)]
        if len(framed)!=1: raise Unobserved('result framing missing or ambiguous')
        try: payload=json.loads(framed[0])
        except (ValueError,RecursionError): raise Unobserved('malformed result') from None
        if not isinstance(payload,dict) or 'worker_exception' in payload: raise Unobserved('worker interface or runtime error')
        return payload
    def build(self,project,cache,targets,**extra):
        return self.rpc({'project':project,'cache':cache,'targets':targets,**extra})


def _check_content(e):
    suffix=secrets.token_hex(3); base,middle,app,docs=['n'+x+suffix for x in ('a','b','c','d')]
    before=secrets.token_hex(8); after=secrets.token_hex(8)
    nodes={base:(before,[]),middle:('middle',[base]),app:('app',[middle]),docs:('docs',[])}
    project=_project(e.scratch,nodes); cache='content.json'
    first=e.build(project,cache,[app,docs])
    file=_safe_path(e.scratch,project+'/src/'+base+'.txt'); metadata=file.stat()
    _write(e.scratch,project+'/src/'+base+'.txt',after); os.utime(file,ns=(metadata.st_atime_ns,metadata.st_mtime_ns))
    nodes[base]=(after,[])
    second=e.build(project,cache,[app,docs])
    output=(second.get('result') or {}).get('outputs',{})
    passed=second.get('exception') is None and set(second.get('calls',[]))=={base,middle,app} and len(second['calls'])==3 and output=={app:_expected(nodes,app),docs:_expected(nodes,docs)} and docs in second['result']['reused']
    return passed,{'first':first,'after_same_mtime_edit':second,'expected_outputs':{app:_expected(nodes,app),docs:_expected(nodes,docs)},'mtime_preserved':file.stat().st_mtime_ns==metadata.st_mtime_ns}


def _check_rewire(e):
    left,right,app='left','right','app'
    nodes={left:('left-'+secrets.token_hex(5),[]),right:('right-'+secrets.token_hex(5),[]),app:('app',[left])}
    project=_project(e.scratch,nodes); cache='rewire.json'
    e.build(project,cache,[app,right])
    left_file=_safe_path(e.scratch,project+'/src/left.txt'); metadata=left_file.stat(); old_text=nodes[left][0]
    active={right:nodes[right],app:('app',[right])}
    _write(e.scratch,project+'/pipeline.json',json.dumps({'nodes':{n:{'source':'src/'+n+'.txt','dependencies':d} for n,(_,d) in active.items()}}));left_file.unlink()
    rewired=e.build(project,cache,[app])
    _write(e.scratch,project+'/src/left.txt',old_text);os.utime(left_file,ns=(metadata.st_atime_ns,metadata.st_mtime_ns))
    _write(e.scratch,project+'/pipeline.json',json.dumps({'nodes':{n:{'source':'src/'+n+'.txt','dependencies':d} for n,(_,d) in nodes.items()}}))
    restored=e.build(project,cache,[app])
    passed=rewired.get('exception') is None and rewired.get('calls')==[app] and (rewired.get('result') or {}).get('outputs')=={app:_expected(active,app)} and restored.get('exception') is None and set(restored.get('calls',[]))=={left,app} and len(restored['calls'])==2 and (restored.get('result') or {}).get('outputs')=={app:_expected(nodes,app)}
    return passed,{'rewired':rewired,'reintroduced_after_successful_removal':restored,'pruning_observed_via_recompile_not_cache_schema':True}


def _check_failure(e):
    nodes={'base':('old-base',[]),'app':('old-app',['base'])}
    project=_project(e.scratch,nodes); cache='atomic.json'
    initial=e.build(project,cache,['app']); before=_read(e.scratch,cache)
    _write(e.scratch,project+'/src/base.txt','new-base-with-different-content');_write(e.scratch,project+'/src/app.txt','new-app-with-different-content')
    failed=e.build(project,cache,['app'],fail_on='app'); after=_read(e.scratch,cache)
    try: intact=json.loads(before)==json.loads(after); state_basis='json_state'
    except (ValueError,UnicodeError): intact=before==after; state_basis='opaque_bytes'
    recovered=e.build(project,cache,['app'])
    current={'base':('new-base-with-different-content',[]),'app':('new-app-with-different-content',['base'])}
    passed=failed.get('exception')=='PipelineError' and 'base' in failed.get('calls',[]) and intact and set(recovered.get('calls',[]))=={'base','app'} and len(recovered['calls'])==2 and (recovered.get('result') or {}).get('outputs')=={'app':_expected(current,'app')}
    return passed,{'initial':initial,'compiler_failure':failed,'last_good_state_intact':intact,'state_comparison':state_basis,'later_success':recovered}


def _check_concurrent(e):
    nodes={'alpha':('alpha-'+secrets.token_hex(5),[]),'beta':('beta-'+secrets.token_hex(5),[])}
    project=_project(e.scratch,nodes);cache='shared.json';go='go-'+secrets.token_hex(6)
    ready=['ready-'+secrets.token_hex(6) for _ in range(2)]
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(e.build,project,cache,[target],delay=.3,barrier={'ready':ready[i],'go':go}) for i,target in enumerate(nodes)]
        deadline=time.monotonic()+8
        while not all((_safe_path(e.scratch,name).is_file() and not (e.scratch/name).is_symlink()) for name in ready):
            if e.cancelled and e.cancelled(): raise Unobserved('cancelled')
            if time.monotonic()>deadline: raise Unobserved('concurrent worker barrier unavailable')
            time.sleep(.01)
        descriptor=os.open(e.scratch/go,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
        with os.fdopen(descriptor,'w') as handle:handle.write('go')
        receipts=[future.result(timeout=18) for future in futures]
    final=e.build(project,cache,['beta','alpha'])
    passed=all(row.get('exception') is None for row in receipts) and final.get('exception') is None and final.get('calls')==[] and (final.get('result') or {}).get('outputs')=={n:_expected(nodes,n) for n in nodes}
    return passed,{'workers':receipts,'both_workers_ready_before_release':True,'post_merge_reuse':final,'actor':'evaluator','model_requests_parallelized':False}


def _check_determinism(e):
    nodes={'beta':('B',[]),'alpha':('A',[])};project=_project(e.scratch,nodes)
    first=e.build(project,'det1.json',['beta','alpha']);same=e.build(project,'det3.json',['beta','alpha'])
    other=e.build(project,'det2.json',['alpha','beta'])
    reuse_a=e.build(project,'det1.json',['beta','alpha']);reuse_b=e.build(project,'det1.json',['beta','alpha'])
    a,b=first.get('result') or {},same.get('result') or {};c,d=reuse_a.get('result') or {},reuse_b.get('result') or {}
    expected={n:_expected(nodes,n) for n in nodes}
    passed=all(row.get('exception') is None for row in (first,same,reuse_a,reuse_b)) and a.get('outputs')==b.get('outputs')==c.get('outputs')==d.get('outputs')==expected and a.get('built')==b.get('built') and list(a.get('outputs',{}))==list(b.get('outputs',{})) and c.get('reused')==d.get('reused') and reuse_a.get('calls')==reuse_b.get('calls')==[] and c.get('built')==d.get('built')==[]
    return passed,{'same_order_fresh_repeats':[first,same],'unchanged_reuse':[reuse_a,reuse_b],
                   'target_permutation_observation_only':other,'fixed_lexical_algorithm_required':False,
                   'operational_definition':'Identical ordered inputs produce stable reports; unchanged cached inputs cause zero compiler calls.',
                   'permutation_note':'Different target input order is recorded only; permutation invariance is not required by the original task and does not affect this check.'}


def _check_cycle(e):
    project=_project(e.scratch,{'left':('L',['right']),'right':('R',['left'])})
    cycle=e.build(project,'cycle.json',['left'])
    return cycle.get('exception')=='PipelineError',{'cycle':cycle}


CHECKS=[('content_and_transitive_rebuild',_check_content),('rewire_and_removed_node_pruning',_check_rewire),
        ('failure_preserves_last_good',_check_failure),('concurrent_compatible_merge',_check_concurrent),
        ('deterministic_reporting_and_zero_recompile',_check_determinism),('cycle_rejected',_check_cycle)]


def check_pipeline(workspace,output_dir,config=None,cancelled=None):
    workspace,output=Path(workspace),Path(output_dir);config=config or {};task=pipeline_task()
    if output.resolve().is_relative_to(workspace.resolve()): raise ValueError('Evaluation evidence must remain outside the target workspace')
    if output.exists() and any(output.iterdir()): raise ValueError('Refusing to replace evaluation evidence')
    output.mkdir(parents=True,exist_ok=True);output.chmod(0o700)
    raw={};problems=[]
    for relative in task['files']:
        path=workspace/relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(workspace.resolve()): problems.append(relative+': missing or unsafe');continue
        if path.stat().st_size>1048576:problems.append(relative+': input bound');continue
        raw[relative]=path.read_bytes()
        if relative not in task['mutable_paths'] and hashlib.sha256(raw[relative]).hexdigest()!=task['source_file_sha256'][relative]:problems.append(relative+': immutable content changed')
    digests={name:hashlib.sha256(data).hexdigest() for name,data in raw.items()}
    result={'schema':'tokenclock-task-result/v1','task_id':'H03','variant':'pipeline',
            'checker_version':'tokenclock-h03-pipeline-checks/v2','status':'limited','checks':[],
            'source':{'sha256':hashlib.sha256(json.dumps(digests,sort_keys=True).encode()).hexdigest(),'kind':config.get('source_kind','real_artifact'),'label_source':'workspace_snapshot_not_backend_identity'},
            'execution':{'actor':'evaluator','network_calls':0,'target_model_calls':0},'artifacts':[],
            'limitations':['New independent check version; no historical 65-point result or former weights reused.',
                           'Finite projects and one controlled two-worker overlap do not prove all process schedules.',
                           'Expected outputs are held in the parent; candidate results and compiler callbacks are observations, not cryptographic attestation.']}
    scope_check={'id':'pipeline.allowed_file_scope','status':'fail' if problems else 'pass','mandatory':True,'observed':problems,'dimension':'能力与交付','group':'H03-source-scope','evidence':[]}
    result['checks'].append(scope_check)
    if problems:
        result['status']='failed';_save(output/'result.json',result);return result
    scratch=Path(tempfile.mkdtemp(prefix='eval-',dir=output));scratch.chmod(0o700)
    for relative,data in raw.items():
        target=scratch/'candidate'/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(0o600)
    evaluator=Evaluator(scratch,output,config,cancelled)
    started=time.monotonic()
    selected=[('public_tests',None)] if config.get('public_only') is True else CHECKS
    for name,checker in selected:
        if cancelled and cancelled(): result['status']='cancelled';break
        try:
            if checker is None:
                observed=evaluator.rpc({'public':True});data=observed.get('public',{})
                passed=data.get('successful') is True and data.get('tests_run')==4
            else: passed,observed=checker(evaluator)
            status='pass' if passed else 'fail';reason=None
        except (Unobserved,OSError,ValueError,KeyError,TypeError) as exc:
            status='unknown';observed={'error_type':type(exc).__name__};reason=str(exc)[:300]
        detail=output/(name+'.json');_save(detail,observed)
        result['checks'].append({'id':'pipeline.'+name,'status':status,'mandatory':True,'observed':observed,
                                 'dimension':'能力与交付','group':'H03-'+name,'evidence':[{'path':str(detail)}],**({'reason':reason} if reason else {})})
    # Runtime writes to submitted implementation are a separate observed scope
    # deviation. Do not read any candidate-created path outside evaluator scratch.
    changed=[]
    for relative,before in raw.items():
        try:after=_read(scratch,'candidate/'+relative)
        except (OSError,ValueError):changed.append(relative);continue
        if after!=before:changed.append(relative)
    result['checks'].append({'id':'pipeline.runtime_source_unchanged','status':'fail' if changed else 'pass','mandatory':True,'observed':changed,'dimension':'服务处理','group':'H03-source-scope','evidence':[]})
    if result['status']!='cancelled':result['status']='failed' if any(c['status']=='fail' for c in result['checks']) else 'limited' if any(c['status']=='unknown' for c in result['checks']) else 'completed'
    result['execution'].update(elapsed_seconds=time.monotonic()-started,sandbox='OS isolation per evaluator worker',worker_processes=len(evaluator.receipts),concurrent_model_requests=0)
    result['coverage']={'public_only':config.get('public_only') is True,'behavior_groups':len(selected),'historical_score_reused':False,
                        'not_covered':['exhaustive thread/process interleavings','power-loss durability','all malformed manifests','general package/API behavior beyond this task']}
    result['artifacts']=[{'path':path,'media_type':'application/json','purpose':'isolated_evaluator_worker_receipt'} for path in evaluator.receipts]
    _save(output/'result.json',result)
    return result
