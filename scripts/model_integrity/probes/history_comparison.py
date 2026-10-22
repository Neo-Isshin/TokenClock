"""Compare two immutable locally recorded runs; never merge them into a verdict."""
from collections import Counter, defaultdict
from importlib.resources import files
from urllib.parse import urlsplit
import uuid
import re
import hashlib
from .common import digest
from .catalog import get_task,l2_plan
from .fingerprints import measurement_contract,observations_from_result,encoded_value,_known
from .transport import request_body

SCHEMA='tokenclock-history-context/v1'


def make_context(report,config):
    lane=report.get('workflow_mode');p=config.get('provider') or {};r=report.get('result',{})
    value={'schema':SCHEMA,'eligible':False,'workflow_mode':lane,'reason':'此类记录只作并列查看。'}
    if r.get('l2_method')=='numeric':
        value.update(reason='数字指纹保留各次型号结果，暂按原报告并列查看。',
                     external_numeric_reference=r.get('numeric_fingerprint',{}).get('reference',{}))
        return value
    if lane not in {'l2','l3'} or config.get('transport_mode')!='live':return value
    try:
        url=urlsplit(p.get('endpoint',''))
        if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment: return value
        binding={k:p.get(k,'responses' if k=='api_format' else '') for k in ('endpoint','model','api_format')}
        if not binding['model']:return value
        tasks={c['task']['id']:c['task'] for c in l2_plan(config.get('family','openai'),config.get('task_ids'),config.get('repeats',2))} if lane=='l2' else {config.get('task_id','H01'):get_task(config.get('task_id','H01'))}
        profiles=[]
        for task_id,task in sorted(tasks.items()):
            cap=task['output_limit'] if lane=='l2' else config.get('output_limit',task['output_limit'])
            profile={'task_id':task_id,'prompt_sha256':task['prompt_sha256'],'measurement_contract':measurement_contract(task_id,config.get('variant')),
                     'request_shape':digest(request_body(p,prompt=task['prompt'],output_limit=cap))}
            if lane=='l2':
                from .reference_readiness import conditions
                profile['conditions']=conditions(task,p)
            if task_id=='H03':
                from .h03 import task as h03_task,TOOLS,SYSTEM
                spec=h03_task(config.get('variant','pipeline'))
                profile['request_shape']=digest(request_body(p,history=[{'role':'user','content':spec['stages'][0]['prompt']}],tools=TOOLS,system=SYSTEM,output_limit=config.get('output_limit',65536)))
                profile['task_contract']=spec.get('contract_sha256') or digest(spec)
            profiles.append(profile)
        reference=r.get('fingerprints',{}).get('reference_identity')
        if not reference:return value
        modules=['features.py'] if lane=='l2' else ['scoring.py']+[task_id.split(':')[0].lower()+'.py' for task_id in tasks]
        if lane=='l3' and any(t.startswith(('H02','H04')) for t in tasks):modules.append('browser_driver.cjs')
        analysis_identity=digest({name:hashlib.sha256(files('scripts.model_integrity.probes').joinpath(name).read_bytes()).hexdigest() for name in sorted(set(modules))})
        request_limit=min(p.get('max_requests',len(tasks)*2),len(tasks)*2) if lane=='l2' else p.get('max_requests',24) if 'H03' in tasks else 1
        value.update(eligible=True,reason='',run_id=uuid.uuid4().hex,target_binding=binding,tasks=profiles,reference_identity=reference,
                     execution_limits=({'max_tool_calls':config.get('max_tool_calls',80),'no_progress_requests':config.get('no_progress_requests',4),'variant':config.get('variant','pipeline')} if 'H03' in tasks else {}) | {'wall_seconds':p.get('wall_seconds',900),'max_requests':request_limit},
                     assessment_enabled=(config.get('assessment') or {}).get('enabled') is True,
                     analysis_identity=analysis_identity,
                     comparison_scope='local_recorded_runs_not_backend_identity')
    except (ValueError,TypeError,KeyError,OSError):pass
    return value


def compare_history(left,right):
    """Return small public summaries only; callers load reports by local job ID."""
    def brief(report):
        from .user_summary import summarize
        from .result_brief import build_brief
        try:
            view=dict(report);view['user_summary']=summarize(report)
            return build_brief(view)['display']
        except (ValueError,TypeError,KeyError,AttributeError):return {'title':'这份记录不完整','summary':'请打开原始报告查看。'}
    out={'schema':'tokenclock-history-comparison/v1','status':'not_comparable','title':'这两次暂时不能直接比较',
         'summary':'','reasons':[],'changes':[],'left':brief(left),'right':brief(right),'model_requests':0,
         'identity_change_inferred':False,'raw_reports_modified':False}
    def stop(message):out['summary']=message;out['reasons'].append(message);return out
    if not all(isinstance(r,dict) and isinstance(r.get('result',{}),dict) for r in (left,right)):return stop('记录格式不完整，暂时只能分别查看。')
    a=left.get('history_context') or {};b=right.get('history_context') or {}
    def valid(c):
        return (isinstance(c,dict) and c.get('schema')==SCHEMA and c.get('eligible') is True
                and isinstance(c.get('run_id'),str) and re.fullmatch(r'[a-f0-9]{32}',c['run_id'])
                and isinstance(c.get('target_binding'),dict) and all(c['target_binding'].get(k) for k in ('endpoint','model','api_format'))
                and c.get('workflow_mode') in {'l2','l3'} and isinstance(c.get('tasks'),list) and c['tasks']
                and all(isinstance(t,dict) and isinstance(t.get('task_id'),str) and t.get('request_shape') and t.get('measurement_contract') for t in c['tasks'])
                and isinstance(c.get('reference_identity'),dict) and c['reference_identity'].get('sha256') and isinstance(c.get('execution_limits'),dict))
    if not all(valid(c) for c in (a,b)):
        return stop('缺少完整的历史条件，或这两份是已有会话/导入材料；可以分别查看结论。')
    if not a.get('run_id') or not b.get('run_id') or a['run_id']==b['run_id']:return stop('这是同一次运行的记录，不算一次新的复测。')
    if a.get('target_binding')!=b.get('target_binding'):return stop('接口、型号或调用格式不同，不把差异解释成同一对象的变化。')
    if a.get('workflow_mode')!=b.get('workflow_mode') or a.get('tasks')!=b.get('tasks'):return stop('题目、生成条件或检查方法不同，不能直接比较前后表现。')
    if a.get('execution_limits')!=b.get('execution_limits'):return stop('两次运行的时间或执行限制不同，暂不直接比较。')
    if not a.get('analysis_identity') or a.get('analysis_identity')!=b.get('analysis_identity'):return stop('两次使用的检查程序不同，暂不把检查方式的变化当作模型表现变化。')
    if not a.get('reference_identity') or a.get('reference_identity')!=b.get('reference_identity'):return stop('两次使用的参考版本不同，不能据此判断表现发生了变化。')
    if a.get('assessment_enabled') or b.get('assessment_enabled'):return stop('其中包含模型辅助判断，本版暂不把它与历史结果合成变化结论。')
    for report in (left,right):
        result=report.get('result',{})
        if (report.get('scope',{}).get('synthetic') or result.get('source_scope') in {'scripted_demo','imported_answers','recorded_response_replay'}
                or result.get('source',{}).get('kind') in {'scripted_demo','synthetic_fixture','controlled_variant'}):return stop('演示、回放或导入结果不计为两次新的独立测试。')
        if result.get('status')!='completed' or result.get('fingerprints',{}).get('reference_overlap',{}).get('sample_identity_overlap'):
            return stop('有测试未完成，或样本曾作为参考使用；先分别查看各自记录。')
    if a['workflow_mode']=='l2':
        groups=[];identities=[]
        for report in (left,right):
            result=report['result'];samples=result.get('samples',[])
            if not samples or any(s.get('metadata',{}).get('source_scope')!='live' or s.get('metadata',{}).get('completed')is not True or s.get('metadata',{}).get('truncated') or s.get('metadata',{}).get('unexpected_tools') for s in samples):
                return stop('有回答不完整或完成状态缺失，暂不比较回答分布。')
            counts=Counter(s.get('task_id') for s in samples)
            if set(counts)!={t['task_id'] for t in a['tasks']} or any(n<2 for n in counts.values()):return stop('两次都需要覆盖相同题目，并保留每题的独立重复回答。')
            specs={t['task_id']:t for t in a['tasks']};call_ids=[]
            for sample in samples:
                record=sample.get('record') or {};spec=specs[sample['task_id']]
                if (sample.get('metadata',{}).get('conditions')!=spec.get('conditions')
                    or sample.get('prompt_sha256')!=spec.get('prompt_sha256')
                    or record.get('request_sha256')!=spec.get('request_shape')):return stop('实际回答记录与保存的测试条件不一致，需要先核对。')
                call_ids.append(record.get('client_request_id') or record.get('provider_response_id') or record.get('response_id'))
            if any(not isinstance(x,str) or not x for x in call_ids) or len(set(call_ids))!=len(call_ids):return stop('调用标识缺失或重复，不能把这些记录当作独立重复回答。')
            observations,_=observations_from_result(report)
            data=defaultdict(Counter);ids=set()
            for row in observations:
                if row.get('origin')!='deterministic_extractor' or row.get('dimension')!='behavior':continue
                if row.get('identity_kind') not in {'response_and_request_bound','controller_request_bound'}:
                    return stop('缺少可区分原始调用的记录，无法排除同一批回答被重复导入。')
                ids.add(row['sample_hash'])
                for name,value in row.get('features',{}).items():
                    if not _known(value,name):return stop('回答中有未能核验的项目，暂不将缺测算作变化。')
                    data[(row['task_id'],name)][encoded_value(name,value,'behavior')]+=1
            if not data or not ids:return stop('缺少可对照的回答特征。')
            for sample in samples:
                record=sample.get('record') or {}
                for key in ('client_request_id','provider_response_id','response_id'):
                    if record.get(key):ids.add(digest([key,record[key],record.get('request_sha256')]))
            groups.append(data);identities.append(ids)
        if identities[0]&identities[1]:return stop('两份记录含有相同的原始调用，不算一次新的复测。')
        if groups[0].keys()!=groups[1].keys():return stop('两次实际核验到的项目不同，不能把缺少项目当作表现变化。')
        for key in sorted(groups[0]):
            x,y=groups[0][key],groups[1][key];nx,ny=sum(x.values()),sum(y.values())
            if any(x.get(k,0)*ny!=y.get(k,0)*nx for k in x.keys()|y.keys()):
                from .recommendations import FEATURE_LABELS
                out['changes'].append({'task_id':key[0],'feature':key[1],'text':key[0]+' · '+FEATURE_LABELS.get(key[1],'回答表现')+'：两次记录的回答分布不同。'})
    else:
        checks=[]
        for report in (left,right):
            result=report['result'];rows=result.get('checks',[])
            if result.get('score',{}).get('mandatory_unknown') or result.get('score',{}).get('invalid_checks'):return stop('仍有必需检查未完成或记录不完整，暂不比较完成情况。')
            if not rows or any(c.get('status') not in {'pass','fail'} or not isinstance(c.get('id'),str) for c in rows):return stop('仍有任务检查没有完成，暂不比较完成情况。')
            if len({c['id'] for c in rows})!=len(rows):return stop('检查记录有重复，需先核对。')
            checks.append({c['id']:c['status'] for c in rows})
        if checks[0].keys()!=checks[1].keys():return stop('两次任务的实际检查项不同。')
        for key in sorted(checks[0]):
            if checks[0][key]!=checks[1][key]:out['changes'].append({'check':key,'before':checks[0][key],'after':checks[1][key],'text':key+'：'+('这次通过了检查。' if checks[1][key]=='pass' else '这次没有通过检查。')})
    changed=len(out['changes']);out.update(status='comparable',title='这两次结果有差别' if changed else '已比较的结果没有变化',
        summary=f'已记录条件相同，有 {changed} 项记录不同。差别不等于模型更换，也不代表长期趋势。' if changed else '已记录条件相同，已核验项目的结果相同；这只说明这两次观察。')
    out['changes_total']=changed;out['changes']=out['changes'][:20]
    return out
