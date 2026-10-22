"""Bounded multi-stage workspace agent, with explicit live/replay/demo modes."""
from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path,PurePosixPath
import shutil
import tempfile
import time

from .common import digest,write_json,load_json,cancelled
from .transport import ProbeClient,ProbeStop,request_body
from .isolation import run_isolated

TOOLS=[
 {'name':'list_files','description':'List files in the supplied task workspace.','parameters':{'type':'object','properties':{},'additionalProperties':False}},
 {'name':'read_file','description':'Read a UTF-8 task file.','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path'],'additionalProperties':False}},
 {'name':'write_file','description':'Replace one file allowed by the task contract.','parameters':{'type':'object','properties':{'path':{'type':'string'},'content':{'type':'string'}},'required':['path','content'],'additionalProperties':False}},
 {'name':'run_checks','description':'Run the task checks inside the isolated workspace.','parameters':{'type':'object','properties':{},'additionalProperties':False}},
]
SYSTEM='Work only in the supplied task workspace through these tools. Follow TASK.md, preserve the stated API, and report actual checks and limits.'
LEDGER_SOLUTION='''def summarize(rows):
    selected = {}
    for row in rows:
        if type(row.get("cents")) is not int:
            raise ValueError("cents must be integer")
        ident, version = row["id"], row.get("version", 1)
        if ident not in selected or version > selected[ident].get("version", 1):
            selected[ident] = dict(row)
        elif version == selected[ident].get("version", 1) and (row["account"], row["cents"]) != (selected[ident]["account"], selected[ident]["cents"]):
            raise ValueError("conflicting records")
    result = {}
    for row in selected.values():
        result[row["account"]] = result.get(row["account"], 0) + row["cents"]
    return result
'''


def ledger_task():
    return {'id':'H03:ledger','title':'有界需求变更演示','task_contract_version':'staged-ledger-v1',
      'reference_scope':'engineering demonstration; no historical model ability reference',
      'files':{'ledger.py':'def summarize(rows):\n    raise NotImplementedError\n',
               'TASK.md':'Implement summarize(rows) in ledger.py. Each record has id, account and integer cents. Sum cents by account; repeated identical IDs must not be counted twice. Use only the Python standard library. Only ledger.py is mutable.\n'},
      'mutable_paths':['ledger.py'],'stages':[
         {'prompt':'读取TASK.md，完成函数并运行检查。'},
         {'prompt':'新增version字段，默认1。相同id以最高version记录为准；同version内容冲突必须抛ValueError。保留已有行为并验证。'},
         {'prompt':'验证一次无效输入后，再处理有效输入不会残留上次状态。cents不接受布尔值；有依据时可保留原实现。'}]}


def task(variant):
    if variant=='ledger':return ledger_task()
    if variant!='pipeline':raise ValueError('Unsupported H03 task variant')
    from .h03_checks import pipeline_task
    return pipeline_task()


def _safe_path(root,relative):
    root=Path(root).resolve()
    if not isinstance(relative,str) or not relative or '\\' in relative:raise ValueError('Invalid task path')
    name=PurePosixPath(relative)
    if name.is_absolute() or '..' in name.parts:raise ValueError('Task path escapes workspace')
    p=root.joinpath(*name.parts)
    current=root
    for part in name.parts:
        current=current/part
        if current.is_symlink():raise ValueError('Symlink task paths are not allowed')
    if not p.resolve().is_relative_to(root.resolve()):raise ValueError('Task path escapes workspace')
    return p


def snapshot(root):
    rows={}
    for p in sorted(root.rglob('*')):
        if p.is_symlink():raise ValueError('Symlink appeared in task workspace')
        if p.is_file():rows[p.relative_to(root).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    return digest(rows)


def _ledger_cases(stage):
    cases=[{'id':'duplicates','input':[{'id':'x','account':'A','cents':10},{'id':'x','account':'A','cents':10},{'id':'y','account':'A','cents':-3}],'expected':{'A':7}},
           {'id':'empty','input':[],'expected':{}}]
    if stage>=1:cases += [
      {'id':'revision','input':[{'id':'x','account':'A','cents':10,'version':1},{'id':'x','account':'B','cents':14,'version':2}],'expected':{'B':14}},
      {'id':'conflict','input':[{'id':'x','account':'A','cents':10},{'id':'x','account':'A','cents':11}],'error':'ValueError'}]
    if stage>=2:cases += [{'id':'boolean','input':[{'id':'b','account':'A','cents':True}],'error':'ValueError'},
                          {'id':'after_invalid','input':[{'id':'z','account':'Z','cents':9}],'expected':{'Z':9}}]
    return cases


def check_ledger(workspace,out,stage,cancelled_check=None):
    out=Path(out);out.mkdir(parents=True,exist_ok=True,mode=0o700)
    cases=_ledger_cases(stage)
    with tempfile.TemporaryDirectory(prefix='tc-h03-check-') as td:
        scratch=Path(td);shutil.copyfile(Path(workspace)/'ledger.py',scratch/'ledger.py')
        inputs=[{'id':c['id'],'input':c['input']} for c in cases]
        worker='import json\nfrom ledger import summarize\nrows='+repr(inputs)+'\nout=[]\nfor case in rows:\n    try: out.append({"id":case["id"],"value":summarize(case["input"])})\n    except Exception as exc: out.append({"id":case["id"],"error":type(exc).__name__})\nprint(json.dumps({"results":out},sort_keys=True))\n'
        (scratch/'check.py').write_text(worker)
        execution=run_isolated(scratch,'check.py',cancelled=cancelled_check)
    write_json(out/'execution.json',execution)
    checks=[];actual={}
    if execution['status']=='completed' and execution['returncode']==0:
        try:
            parsed=json.loads(execution['stdout']);actual={r['id']:r for r in parsed['results']}
        except (ValueError,KeyError,TypeError):pass
    for c in cases:
        observed=actual.get(c['id']);unknown=observed is None
        expected={'error':c['error']} if 'error' in c else {'value':c['expected']}
        passed=bool(observed) and all(observed.get(k)==v for k,v in expected.items())
        checks.append({'id':'ledger.'+c['id'],'status':'unknown' if unknown else 'pass' if passed else 'fail','observed':observed,'expected':expected,
                       'dimension':'capability_delivery','group':'ledger.'+c['id'],'mandatory':True,'evidence':[{'path':'execution.json'}]})
    return {'schema':'tokenclock-task-result/v1','task_id':'H03:ledger','status':'failed' if any(c['status']=='fail' for c in checks) else 'completed' if actual else 'limited','checks':checks,
            'source':{'sha256':snapshot(Path(workspace)),'kind':'synthetic_fixture'},'execution':{'actor':'evaluator',**execution},
            'artifacts':[],'limitations':['Staged-ledger engineering task; not an enrolled model-identity benchmark.']}


class Workspace:
    def __init__(self,root,out,spec,config,cancelled_check):
        self.root=Path(root).resolve();self.out=Path(out).resolve();self.spec=spec;self.config=config;self.cancelled=cancelled_check
        if self.out.is_relative_to(self.root):raise ValueError('Evaluation evidence must be outside the target workspace')
        self.stage=0;self.events=[];self.check_results=[];self.limit=config.get('file_bytes',1024*1024);self.request_number=None
        if type(self.limit) is not int or not 1<=self.limit<=4*1024*1024:raise ValueError('Invalid file byte allowance')
    def invoke(self,name,args,call_id):
        cancelled(self.cancelled)
        before=snapshot(self.root)
        event={'id':f'tool-{len(self.events)+1:04d}','name':name,'arguments':args,'call_id':call_id,'stage':self.stage,
               'actor':'target' if self.config.get('transport_mode')=='live' else 'simulated_target',
               'request_number':self.request_number,'workspace_before':before}
        try:
            if not isinstance(args,dict) or '__invalid_arguments__' in args:raise ValueError('Tool arguments must be valid JSON object')
            expected={'list_files':set(),'read_file':{'path'},'write_file':{'path','content'},'run_checks':set()}
            if name not in expected or set(args)!=expected[name]:raise ValueError('Tool arguments do not match the allowed schema')
            if name=='list_files':value={'files':[p.relative_to(self.root).as_posix() for p in sorted(self.root.rglob('*')) if p.is_file()]}
            elif name=='read_file':
                path=_safe_path(self.root,args['path'])
                if not path.is_file() or path.stat().st_size>self.limit:raise ValueError('File missing or exceeds read allowance')
                value={'path':args['path'],'text':path.read_text(),'complete':True}
            elif name=='write_file':
                path=_safe_path(self.root,args['path']);content=args['content']
                if args['path'] not in self.spec['mutable_paths']:raise ValueError('File is not mutable under this task')
                if not isinstance(content,str) or len(content.encode())>self.limit:raise ValueError('Write exceeds file allowance')
                path.parent.mkdir(parents=True,exist_ok=True);path.write_text(content,encoding='utf-8',newline='');path.chmod(0o600)
                value={'written':args['path'],'sha256':hashlib.sha256(content.encode()).hexdigest()}
            elif name=='run_checks':
                out=self.out/f'checks-{len(self.check_results)+1:03d}'
                if self.spec.get('id')=='H03:ledger':r=check_ledger(self.root,out,self.stage,self.cancelled)
                else:
                    from .h03_checks import check_pipeline
                    r=check_pipeline(self.root,out,config={'public_only':True},cancelled=self.cancelled)
                self.check_results.append(r)
                # Feedback is actual public test status, not hidden solutions.
                value={'status':r['status'],'checks':[{'id':c['id'],'status':c['status']} for c in r['checks']]}
            else:raise ValueError('Unknown tool; no host shell is available')
            event.update(status='completed',output=value)
        except (ValueError,KeyError,OSError) as exc:
            value={'error':type(exc).__name__,'message':str(exc)[:500]};event.update(status='error',output=value)
        event['workspace_after']=snapshot(self.root);self.events.append(event);write_json(self.out/'tool-events.json',self.events)
        return json.dumps(value,ensure_ascii=False,sort_keys=True)


def _demo_response(fmt,step,stage,model):
    if stage==0 and step==0:tool={'id':'demo-write','name':'write_file','arguments':{'path':'ledger.py','content':LEDGER_SOLUTION}}
    elif (stage==0 and step==1) or (stage>0 and step==0):tool={'id':f'demo-check-{stage}','name':'run_checks','arguments':{}}
    else:tool=None
    text='已完成当前阶段，检查结果保留在工具记录中。' if tool is None else ''
    usage={'input_tokens':0,'output_tokens':0,'cache_read_input_tokens':0,'cache_creation_input_tokens':0}
    if fmt=='messages':return {'model':model,'stop_reason':'tool_use' if tool else 'end_turn','usage':usage,'content':[{'type':'tool_use','id':tool['id'],'name':tool['name'],'input':tool['arguments']}] if tool else [{'type':'text','text':text}]}
    if fmt=='responses':return {'model':model,'status':'completed','usage':{'input_tokens':0,'output_tokens':0,'total_tokens':0},'output':[{'type':'function_call','call_id':tool['id'],'name':tool['name'],'arguments':json.dumps(tool['arguments'])}] if tool else [{'type':'message','role':'assistant','content':[{'type':'output_text','text':text}]}]}
    return {'model':model,'usage':{'prompt_tokens':0,'completion_tokens':0,'total_tokens':0},'choices':[{'finish_reason':'tool_calls' if tool else 'stop','message':{'role':'assistant','content':text,'tool_calls':[{'id':tool['id'],'type':'function','function':{'name':tool['name'],'arguments':json.dumps(tool['arguments'])}}] if tool else []}}]}


def _write_initial(workspace,spec):
    for relative,content in spec['files'].items():
        path=_safe_path(workspace,relative);path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(content,encoding='utf-8',newline='');path.chmod(0o600)


def _check_artifact(workspace,out,variant,config,cancelled_check):
    if variant=='ledger':return check_ledger(workspace,out,2,cancelled_check)
    from .h03_checks import check_pipeline
    return check_pipeline(workspace,out,config=config,cancelled=cancelled_check)


def _result_status(checks,stop=None,is_cancelled=False):
    if is_cancelled:return 'cancelled'
    if stop and str(stop.get('code','')).startswith('replay_'):return 'replay_mismatch'
    if stop:return 'limited'
    if any(check.get('status')=='fail' for check in checks):return 'failed'
    if any(check.get('mandatory',True) and check.get('status')=='unknown' for check in checks):return 'limited'
    return 'completed'


def evaluate(source_path,output_dir,config=None,cancelled=None,progress=None):
    """Evaluate embedded known-task files; never dereference paths in the JSON."""
    config=dict(config or {});source_path=Path(source_path);out=Path(output_dir)
    from scripts.model_integrity.l1.ingest import strict_loads
    limit=8*1024*1024
    if source_path.stat().st_size>limit:raise ValueError('Artifact exceeds byte allowance')
    with source_path.open('rb') as handle:source_bytes=handle.read(limit+1)
    if len(source_bytes)>limit:raise ValueError('Artifact grew beyond byte allowance')
    bundle=strict_loads(source_bytes.decode('utf-8-sig'))
    if not isinstance(bundle,dict) or set(bundle)-{'schema','files','task_variant','workspace_sha256'}:
        raise ValueError('Artifact must contain embedded files, not host file references')
    if bundle.get('schema','tokenclock-h03-final-workspace/v1')!='tokenclock-h03-final-workspace/v1':
        raise ValueError('Unsupported final-workspace schema')
    variant=bundle.get('task_variant')
    if variant not in {'pipeline','ledger'} or config.get('variant',variant)!=variant:raise ValueError('Unknown or conflicting H03 task variant')
    spec=task(variant);embedded=bundle.get('files')
    if not isinstance(embedded,dict) or set(embedded)!=set(spec['files']):raise ValueError('Embedded file set must match the known task exactly')
    total=0
    for name,content in embedded.items():
        if not isinstance(content,str):raise ValueError('Embedded task file must be UTF-8 text')
        size=len(content.encode());total+=size
        if size>1024*1024:raise ValueError('Embedded file exceeds byte allowance')
        if name not in spec['mutable_paths'] and content!=spec['files'][name]:raise ValueError('Immutable task file was changed')
    if total>4*1024*1024:raise ValueError('Embedded workspace exceeds byte allowance')
    if out.exists() and any(out.iterdir()):raise ValueError('Refusing to replace existing evaluation evidence')
    out.mkdir(parents=True,exist_ok=True,mode=0o700);out.chmod(0o700)
    with tempfile.TemporaryDirectory(prefix='tc-h03-artifact-') as td:
        workspace=Path(td).resolve();_write_initial(workspace,{**spec,'files':embedded})
        actual_hash=snapshot(workspace)
        if bundle.get('workspace_sha256') is not None and bundle['workspace_sha256']!=actual_hash:raise ValueError('Embedded workspace hash mismatch')
        if progress:progress({'stage':'h03_artifact_evaluation','message':'在独立隔离副本核验嵌入的任务文件'})
        result=_check_artifact(workspace,out/'final-checks',variant,config,cancelled)
        result.update(task_id='H03',variant=variant,workflow_mode='artifact')
        result['source']={'sha256':hashlib.sha256(source_bytes).hexdigest(),'workspace_sha256':actual_hash,
                          'kind':config.get('source_kind','real_artifact'),'label_source':'embedded_workspace_file_no_backend_identity_proof'}
        result['execution'].update(actor='evaluator',target_model_calls=0,network_calls=0)
        result.setdefault('limitations',[]).append('Artifact evaluation does not reconstruct the original model/tool trajectory.')
        from .scoring import score_checks
        result['score']=score_checks(result['checks']);write_json(out/'h03-result.json',result)
        return result


def run(source_path,output_dir,config=None,cancelled_check=None,progress=None):
    config=dict(config or {})
    mode=config.get('transport_mode','replay')
    if mode=='artifact':return evaluate(source_path,output_dir,config,cancelled_check,progress)
    if mode not in {'live','replay','demo'}:raise ValueError('Unsupported H03 transport mode')
    out=Path(output_dir)
    if out.exists() and any(out.iterdir()):raise ValueError('Refusing to replace existing H03 evidence')
    out.mkdir(parents=True,exist_ok=True,mode=0o700);out.chmod(0o700)
    variant=config.get('variant','ledger' if mode=='demo' else 'pipeline')
    if mode=='demo' and variant!='ledger':raise ValueError('Scripted demo is only the explicitly labelled engineering ledger task')
    spec=task(variant);provider=dict(config.get('provider') or {});provider['purpose']='target';replay=None
    if mode=='replay':
        replay=load_json(source_path)
        if not isinstance(replay,dict) or replay.get('schema')!='tokenclock-probe-replay/v1' or replay.get('task_variant')!=variant:raise ValueError('H03 replay task contract mismatch')
        entries=replay.get('records')
        if not isinstance(entries,list):raise ValueError('H03 replay requires a records array')
        for entry in entries:
            if not isinstance(entry,dict) or any(not isinstance(entry.get(key),str) or not re.fullmatch('[0-9a-f]{64}',entry[key]) for key in ('request_sha256','workspace_sha256')):
                raise ValueError('Every H03 replay record requires exact request and workspace hashes')
        provider.update(replay_records=entries);provider.setdefault('model',replay.get('requested_model',''))
        provider.setdefault('api_format',replay.get('api_format','responses'))
        settings=replay.get('request_settings',{})
        if not isinstance(settings,dict):raise ValueError('Invalid replay request settings')
        for key in ('stream','reasoning_effort'):
            if key in settings:provider.setdefault(key,settings[key])
        if 'output_limit' in settings:config.setdefault('output_limit',settings['output_limit'])
    if mode=='demo':provider.update(model='scripted-demo',api_format='responses',stream=False,replay_records=[])
    provider.update(transport_mode='replay' if mode=='demo' else mode)
    provider.setdefault('max_requests',24);provider.setdefault('wall_seconds',900)
    if type(provider['wall_seconds']) is not int or not 1<=provider['wall_seconds']<=3600:raise ValueError('Invalid total wall-time allowance')
    client=ProbeClient(provider,out/'transport',progress,cancelled_check)
    history=[];stages=[];stop=None;started=time.monotonic()
    cap=config.get('output_limit',65536 if variant=='pipeline' else 24576)
    if type(cap) is not int or not 256<=cap<=262144:raise ValueError('Invalid output token allowance')
    max_tools=config.get('max_tool_calls',80);no_progress=config.get('no_progress_requests',4)
    if type(max_tools) is not int or type(no_progress) is not int or not 1<=max_tools<=200 or not 1<=no_progress<=8:raise ValueError('Invalid tool/no-progress allowance')
    with tempfile.TemporaryDirectory(prefix='tc-h03-workspace-') as td:
        workspace=Path(td).resolve();_write_initial(workspace,spec)
        env=Workspace(workspace,out,spec,{**config,'transport_mode':mode},cancelled_check)
        before=snapshot(workspace)
        try:
            for stage_number,stage_spec in enumerate(spec['stages']):
                env.stage=stage_number;history.append({'role':'user','content':stage_spec['prompt']});step=0;done=False;stale=0;seen=set()
                while not done:
                    cancelled(cancelled_check)
                    if time.monotonic()-started>=provider['wall_seconds']:raise ProbeStop('run_wall_limit')
                    state=snapshot(workspace);body=request_body(provider,history=history,tools=TOOLS,output_limit=cap,system=SYSTEM)
                    if mode=='demo':client.replay.append({'request_sha256':digest(body),'workspace_sha256':state,'source_kind':'synthetic_fixture',
                        'record_origin_label':'scripted-demo','response':_demo_response(provider['api_format'],step,stage_number,provider['model'])})
                    answer=client.request(body,{'task_id':'H03','variant':variant,'stage':stage_number,'workspace_sha256':state})
                    history.append(answer['assistant_message']);step+=1;env.request_number=answer['record']['number']
                    if answer['limited'] or not answer['completed']:raise ProbeStop('generation_incomplete')
                    calls=answer['tool_calls'];novel=False
                    for call in calls:
                        if len(env.events)>=max_tools:raise ProbeStop('tool_count_limit')
                        value=env.invoke(call['name'],call['arguments'],call['id'])
                        history.append({'role':'tool','tool_call_id':call['id'],'content':value})
                        key=digest([call['name'],call['arguments'],value])
                        if env.events[-1]['status']=='completed':novel |= key not in seen;seen.add(key)
                    changed=snapshot(workspace)!=state
                    stale=0 if changed or novel else stale+1
                    write_json(out/'history.json',history)
                    if not calls:
                        if not answer['text'].strip():raise ProbeStop('empty_final_response')
                        done=True
                    elif stale>=no_progress:raise ProbeStop('no_progress_limit')
                stages.append({'stage':stage_number,'completed':done,'requests':step,'workspace_sha256':snapshot(workspace)})
                write_json(out/'stages.json',stages)
        except (ProbeStop,InterruptedError) as exc:stop={'code':getattr(exc,'code','cancelled'),'stage':env.stage}
        write_json(out/'history.json',history);write_json(out/'stages.json',stages);write_json(out/'tool-events.json',env.events)
        final_hash=snapshot(workspace)
        after={p.relative_to(workspace).as_posix():p.read_text() for p in workspace.rglob('*') if p.is_file()}
        write_json(out/'final-workspace.json',{'schema':'tokenclock-h03-final-workspace/v1','files':after,'task_variant':variant,'workspace_sha256':final_hash})
        is_cancelled=bool(cancelled_check and cancelled_check())
        skip_final=is_cancelled or (stop and stop.get('code') in ('run_wall_limit','cancelled'))
        final_check=None if skip_final else _check_artifact(workspace,out/'final-checks',variant,{},cancelled_check)
        checks=copy.deepcopy(final_check['checks']) if final_check else []
        checks.append({'id':'h03.stages_complete','status':'pass' if len(stages)==len(spec['stages']) else 'unknown',
                       'observed':len(stages),'expected':len(spec['stages']),'dimension':'delivery','group':'h03.delivery','mandatory':True,'evidence':[{'path':'stages.json'}]})
        if final_check is None:checks.append({'id':'h03.final_evaluation','status':'unknown','mandatory':True,'observed':'not_run_after_stop','dimension':'delivery','group':'h03.delivery','evidence':[]})
        synthetic=mode=='demo' or (mode=='replay' and all(entry.get('source_kind')=='synthetic_fixture' for entry in client.replay))
        result={'schema':'tokenclock-task-result/v1','task_id':'H03','variant':variant,
                'status':_result_status(checks,stop,is_cancelled),'checks':checks,
                'source':{'sha256':final_hash,'initial_workspace_sha256':before,'kind':'synthetic_fixture' if synthetic else 'real_artifact',
                          'label_source':'scripted_demo' if mode=='demo' else 'stored_response_replay_not_new_model_call' if mode=='replay' else 'explicit_live_requests'},
                'execution':{'actor':'target' if mode=='live' else 'evaluator','action_origin':'live_target' if mode=='live' else 'replayed_or_scripted_target_actions',
                             'elapsed_seconds':time.monotonic()-started,'network_calls':client.accounting()['live_requests'],'target_model_calls':client.accounting()['live_requests'],
                             'limits':{'wall_seconds':provider['wall_seconds'],'requests':provider['max_requests'],'tool_calls':max_tools,'no_progress_requests':no_progress,'output_tokens':cap}},
                'stages':stages,'tool_events':env.events,'stop':stop,'accounting':client.accounting(),
                'final_evaluation':final_check,'artifacts':[{'path':'final-workspace.json','media_type':'application/json','purpose':'actual final files'}],
                'limitations':['Scripted and recorded replay actions are not new model samples or mixed-relay identity truth.',
                               'New task stages/graders do not inherit historical model scores or identify real backend weights.']}
    from .scoring import score_checks
    result['score']=score_checks(result['checks']);write_json(out/'h03-result.json',result);return result
