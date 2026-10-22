"""Original short probes: one fresh request per answer, serial and cost-bounded."""
from __future__ import annotations

from importlib.resources import files
import json
from pathlib import Path

from .catalog import l2_plan
from .common import write_json,cancelled,digest,load_json
from .transport import ProbeClient,ProbeStop,request_body


def _demo_text(task_id):
    family,variant=task_id.split(':')
    if family=='N01':return '河流'
    if family=='N02':return '○'
    if family=='N03':return '43'
    if family=='N04':return 'C叶' if variant=='A' else 'B叶'
    if family=='C02':return '两组人数相同，所以平均数是15。'
    if family=='C06':return '[[1], [1]]。因为两项引用同一个内部列表。' if variant=='A' else '[[1], [0]]。两个内部列表分别创建。'
    if family=='O05':return '缓存就像手边的小抽屉，把常用内容先保存，下次取用更快。抽屉空间有限，内容变旧后需要更新。'
    if family=='O06':return '测试中平均耗时从8秒降到5秒。'+('80%的请求更快。' if variant=='B' else '')
    if family=='O07':return '```python\ndef dedupe(values):\n    return list(dict.fromkeys(values))\n```'
    raise ValueError('No scripted demonstration for this task')


def _demo_record(body,fmt,text,index):
    if fmt=='responses':
        response={'id':f'scripted-demo-{index}','model':'scripted-demo-model','status':'completed',
                  'output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':text}]}]}
    elif fmt=='messages':response={'id':f'scripted-demo-{index}','model':'scripted-demo-model','stop_reason':'end_turn','content':[{'type':'text','text':text}]}
    else:response={'id':f'scripted-demo-{index}','model':'scripted-demo-model','choices':[{'index':0,'finish_reason':'stop','message':{'role':'assistant','content':text}}]}
    return {'request_sha256':digest(body),'response':response,'events':[],
            'source_kind':'synthetic_fixture','record_origin_label':'scripted_demo:no_model_was_called'}


def from_answers(source_path,output_dir,config=None,cancelled_check=None,progress=None):
    from .catalog import get_task
    from .features import extract
    from .scoring import compare_behavior
    output=Path(output_dir);output.mkdir(parents=True,exist_ok=True,mode=0o700)
    pack=load_json(source_path)
    if pack.get('schema')!='tokenclock-l2-answer-set/v1' or not isinstance(pack.get('samples'),list) or not 1<=len(pack['samples'])<=10:
        raise ValueError('已有回答需要tokenclock-l2-answer-set/v1，内嵌1–10条samples')
    samples=[]
    for index,row in enumerate(pack['samples']):
        cancelled(cancelled_check)
        if not isinstance(row,dict) or not isinstance(row.get('answer'),str):raise ValueError('每条回答必须包含task_id、原题prompt和answer')
        if any(type(row[k]) is not bool for k in ('completed','truncated') if k in row):raise ValueError('回答完成/截断状态必须是布尔值')
        if not isinstance(row.get('conditions',{}),dict):raise ValueError('生成条件必须是对象')
        task=get_task(row.get('task_id'))
        if task['layer']!='L2' or row.get('prompt')!=task['prompt']:raise ValueError('已有回答的原题必须与所选冻结题面完全相同')
        if len(row['answer'].encode())>1024*1024:raise ValueError('单份已有回答超过1 MiB')
        metadata={'conditions':row.get('conditions',{}),'prompt_sha256':task['prompt_sha256'],
                  'status':row.get('status','completed'),'completed':row.get('completed',row.get('status','completed') not in {'failed','cancelled','truncated','length','max_tokens','incomplete'}),
                  'truncated':row.get('truncated',False) or row.get('status') in {'truncated','length','max_tokens','incomplete'},
                  'source_scope':'imported_answer_not_new_model_call'}
        extracted=extract(task['id'],row['answer'],metadata)
        record={'provider_response_id':row.get('provider_response_id'),'request_sha256':row.get('request_sha256'),
                'source_kind':'imported_answer','transport_mode':'artifact','usage':row.get('usage'),
                'requested_model':row.get('requested_model'),'response_model':row.get('response_model')}
        samples.append({'id':f'import-{index+1:03d}','task_id':task['id'],'repeat':row.get('repeat',index+1),
                        'answer':row['answer'],'prompt_sha256':task['prompt_sha256'],'metadata':metadata,'extracted':extracted,
                        'record':record,'status':extracted['status']})
    from .reference_release import reference as load_reference
    reference=load_reference('behavior')
    result={'schema':'tokenclock-l2-run/v1','layer':'L2','status':'completed','samples':samples,
            'planned_requests':0,'attempted_requests':0,'completed_answers':sum(s['metadata'].get('completed') is True and not s['metadata'].get('truncated') for s in samples),'recorded_samples':len(samples),
            'comparison':compare_behavior(samples,reference),'source_scope':'imported_answers',
            'accounting':{'live_requests':0,'reported_cost_usd':'0','estimated_cost_usd':'0','pending_reserved_usd':'0'},
            'limitations':['Imported prompt/conditions/model labels are source declarations, not newly authenticated provider records.','No target calls were made. Optional reviewer calls are reported separately.']}
    write_json(output/'samples.json',samples);write_json(output/'l2-result.json',result);return result


def run(source_path,output_dir,config=None,cancelled_check=None,progress=None):
    config=dict(config or {})
    if config.get('transport_mode')=='artifact':return from_answers(source_path,output_dir,config,cancelled_check,progress)
    output=Path(output_dir);output.mkdir(parents=True,exist_ok=True,mode=0o700)
    provider=dict(config.get('provider') or {});provider['purpose']='target'
    provider['transport_mode']=config.get('transport_mode',provider.get('transport_mode','replay'))
    provider.setdefault('model',config.get('model',''))
    provider.setdefault('api_format','responses')
    plan=l2_plan(config.get('family','openai'),config.get('task_ids'),config.get('repeats',2))
    requested_mode=provider['transport_mode']
    from .features import SUPPORTED_TASKS
    unsupported=[cell['task']['id'] for cell in plan if cell['task']['id'] not in SUPPORTED_TASKS]
    if unsupported and requested_mode in {'live','demo'} and not (requested_mode=='live' and config.get('assessment',{}).get('enabled') is True):
        raise ValueError('这些题目尚无自动提取器，不启动付费或演示采样：'+', '.join(sorted(set(unsupported))))
    if requested_mode=='demo':
        provider.update(transport_mode='replay',model='scripted-demo-model')
        provider['replay_records']=[_demo_record(request_body(provider,prompt=c['task']['prompt'],output_limit=c['task']['output_limit']),
                                    provider['api_format'],_demo_text(c['task']['id']),c['index']) for c in plan]
        write_json(output/'scripted-demo-replay.json',{'schema':'tokenclock-probe-replay/v1','source_kind':'scripted_demo',
                   'requested_model':provider['model'],'api_format':provider['api_format'],'records':provider['replay_records'],
                   'meaning':'Scripted engineering demonstration, no model generated these responses.'})
    elif provider['transport_mode']=='replay':
        replay=load_json(source_path)
        if replay.get('schema')!='tokenclock-probe-replay/v1':raise ValueError('回放需要明确的tokenclock-probe-replay/v1文件')
        provider['replay_records']=replay.get('records',[])
        if not provider.get('model'):provider['model']=replay.get('requested_model','')
        if config.get('api_format') is None and replay.get('api_format'):provider['api_format']=replay['api_format']
    provider['max_requests']=min(len(plan),int(provider.get('max_requests',len(plan))))
    client=ProbeClient(provider,output/'transport',progress,cancelled_check)
    samples=[];stop=None;events_by_request={};responses_by_request={}
    for cell in plan:
        task=cell['task'];before=len(client.records)
        conditions={'reasoning_effort':provider.get('reasoning_effort','high'),'generation_limit':task['output_limit'],
                    'system':None,'history':None,'tools':None,'feedback':None,'fresh_single_question':True}
        if requested_mode=='demo':conditions['reasoning_effort']='not_applicable_scripted'
        try:
            cancelled(cancelled_check)
            # No system, previous_response_id, tools, history or response-format
            # constraint is added to these originally frozen question prompts.
            body=request_body(provider,prompt=task['prompt'],output_limit=task['output_limit'])
            answer=client.request(body,{'task_id':task['id'],'repeat':cell['repeat'],'prompt_sha256':task['prompt_sha256'],
                                       'fresh_single_question':True,'system':None,'history':None,'tools':None,'feedback':None})
            metadata={'finish_reason':answer['finish_reason'],'completed':answer['completed'],'truncated':answer['limited'],
                'unexpected_tools':bool(answer['tool_calls']),'status':answer['record']['status'],
                'conditions':conditions,
                'prompt_sha256':task['prompt_sha256'],'source_scope':'scripted_demo' if requested_mode=='demo' else 'recorded_replay' if client.mode=='replay' else 'live'}
            from .features import extract
            extracted=extract(task['id'],answer['text'],metadata=metadata)
            sample={'id':f'l2-{cell["index"]:03d}','task_id':task['id'],'repeat':cell['repeat'],
                    'prompt_sha256':task['prompt_sha256'],'answer':answer['text'],'metadata':metadata,
                    'extracted':extracted,'record':answer['record'],'status':extracted['status']}
            events_by_request[answer['record']['client_request_id']]=answer['events']
            responses_by_request[answer['record']['client_request_id']]=answer['raw_response']
            samples.append(sample);write_json(output/'samples.json',samples)
        except (ProbeStop,InterruptedError) as exc:
            code=getattr(exc,'code','cancelled')
            if len(client.records)>before:
                record=client.records[-1]
                metadata={'status':'failed','error':code,'completed':False,'conditions':conditions,'prompt_sha256':task['prompt_sha256']}
                from .features import extract
                samples.append({'id':f'l2-{cell["index"]:03d}','task_id':task['id'],'repeat':cell['repeat'],
                                'prompt_sha256':task['prompt_sha256'],'answer':'','metadata':metadata,
                                'status':'cancelled' if code=='cancelled' else 'failed',
                                'extracted':extract(task['id'],'',metadata),'record':record})
                number=record['number']
                for name,target in [('events',events_by_request),('response',responses_by_request)]:
                    path=output/'transport'/f'{number:03d}-{name}.json'
                    if path.is_file():target[record['client_request_id']]=load_json(path)
                write_json(output/'samples.json',samples)
            stop={'code':code,'details':getattr(exc,'details',{}),
                  'completed_answers':sum(s['metadata'].get('completed') is True for s in samples),
                  'admission_stopped_without_new_call':len(client.records)==before}
            break
    from .scoring import compare_behavior
    from .reference_release import reference as load_reference
    reference=load_reference('behavior')
    comparison=compare_behavior(samples,reference,model_labels=config.get('reference_models'))
    if requested_mode=='demo':
        comparison['scope']='synthetic_demo_not_model_comparison'
        for question in comparison['questions']:
            question['scope']='synthetic_demo_not_model_comparison'
            for model in question['models']:
                model['comparison_scope']='synthetic_demo_not_model_comparison'
                model['condition_notes'].append({'field':'response_origin','state':'scripted_no_model_generation'})
        for item in comparison['descriptive_model_summaries']:item['scope']='Synthetic algorithm demonstration only; not observations from any target model.'
    from .diagnostics import analyze
    diagnostic=analyze(client.records,metadata={'scope':'new_probe_run_only','transport_mode':client.mode,
                      'events_by_request':events_by_request,'responses_by_request':responses_by_request})
    complete=sum(s['metadata'].get('completed') is True and not s['metadata'].get('truncated') and not s['metadata'].get('unexpected_tools') for s in samples)
    extracted_complete=sum(s['extracted']['status']=='completed' for s in samples)
    result={'schema':'tokenclock-l2-run/v1','layer':'L2','status':'completed' if complete==len(plan) else 'cancelled' if stop and stop['code']=='cancelled' else 'limited',
            'planned_requests':len(plan),'completed_answers':complete,'fully_extracted_answers':extracted_complete,'extraction_status':'completed' if extracted_complete==len(plan) else 'partial','recorded_samples':len(samples),'attempted_requests':len(client.records),'samples':samples,'comparison':comparison,
            'diagnostics':diagnostic,'stop':stop,'accounting':client.accounting(),
            'source_scope':'scripted_demo' if requested_mode=='demo' else 'recorded_response_replay' if client.mode=='replay' else 'new_live_requests',
            'fresh_session_per_answer':True,'no_history_tools_answers_feedback':True,
            'limitations':['This run describes only these answers, not the origin of a prior user session.',
                           'Behavioral affinity is not backend identity, a real mixed-relay rate, or an ability hierarchy.']}
    write_json(output/'l2-result.json',result)
    return result
