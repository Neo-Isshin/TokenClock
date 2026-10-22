"""Product dispatch: only explicit configuration selects active execution."""
from __future__ import annotations
import copy
import hashlib
import importlib
import json
from pathlib import Path
import zipfile
from .common import write_json, load_json, digest, cancelled as check_cancelled
from .catalog import get_task
from .scoring import score_checks


def validate_config(config):
    config=copy.deepcopy(config or {'mode':'local'})
    from .review_config import resolve_shared_review
    config=resolve_shared_review(config)
    from .assessment import validate_config as validate_assessment,live as assessment_live
    config['assessment']=validate_assessment(config.get('assessment'))
    workflow=config.get('workflow_mode','l1')
    if workflow not in {'l1','l2','l3','diagnostics','combined'}:raise ValueError('未知的评估流程')
    if workflow=='l2' and config.get('l2_method','behavior') not in {'behavior','numeric'}:raise ValueError('未知的轻量检测方法')
    if workflow in {'l2','l3'}:
        mode=config.get('transport_mode','artifact' if workflow=='l3' else 'replay')
        if mode not in ({'live','replay','demo','artifact'} if workflow=='l2' else {'live','replay','demo','artifact'}):raise ValueError('未知的执行模式')
        if workflow=='l3' and config.get('task_id','H01') not in {'H01','H02','H03','H04','H04:ascii'}:raise ValueError('未知的重型任务')
        if mode=='demo' and workflow=='l3' and config.get('task_id')!='H03':raise ValueError('重型演示仅提供H03受控任务')
        if mode=='live':
            if config.get('allow_live') is not True:raise ValueError('真实调用需要明确开启，并配置本次预算')
            provider=config.get('provider')
            if not isinstance(provider,dict):raise ValueError('缺少本次接口配置')
            provider.update(transport_mode='live',allow_live=True)
            config['mode']='external'
        else:config['mode']='local'
    if config['assessment']['enabled'] and workflow not in {'l2','l3'}:raise ValueError('新评审配置仅适用于L2/L3，L1语义增强使用原配置')
    if config['assessment'].get('batch_once') and workflow!='l2':raise ValueError('批量一次解析目前仅用于已收集的轻量回答')
    if workflow=='l2' and config.get('l2_method')=='numeric':
        from .numeric_fingerprint import reference,ensure_runtime,plan
        reference();ensure_runtime();plan(config)
        if config['assessment']['enabled']:raise ValueError('数字指纹在本地评分，无需模型辅助解析。')
    if assessment_live(config['assessment']):config['mode']='external'
    return config


def _normalize_paths(value,root):
    if isinstance(value,dict):return {k:_normalize_paths(v,root) for k,v in value.items()}
    if isinstance(value,list):return [_normalize_paths(v,root) for v in value]
    if isinstance(value,str) and value.startswith(str(root)+'/'):return value[len(str(root))+1:]
    return value


def _artifact(source,out,config,cancelled,progress):
    task_id=config.get('task_id','H01')
    if task_id=='H03':
        from .h03 import evaluate
        return evaluate(source,out,config=config,cancelled=cancelled,progress=progress)
    module=importlib.import_module('scripts.model_integrity.probes.'+task_id.split(':')[0].lower())
    options=dict(config.get('evaluation') or {})
    if config.get('_judge') is not None and task_id.startswith('H04'):
        options.update(semantic_proposer=config['_judge'].visual,semantic_proposer_authorized=True)
    if task_id.startswith('H04'):options['variant']='ascii' if task_id.endswith(':ascii') else 'svg'
    return module.evaluate(source,out,config=options,cancelled=cancelled,progress=progress)


def _single_generation(source,out,config,cancelled,progress):
    from .transport import ProbeClient,ProbeStop,request_body
    task=get_task(config.get('task_id','H01'));provider=dict(config.get('provider') or {});provider['purpose']='target'
    mode=config.get('transport_mode','replay');provider['transport_mode']=mode
    if mode=='replay':
        pack=load_json(source)
        if pack.get('schema')!='tokenclock-probe-replay/v1':raise ValueError('需要明确的请求绑定回放文件')
        provider['replay_records']=pack.get('records',[])
        provider.setdefault('model',pack.get('requested_model',''))
        provider.setdefault('api_format',pack.get('api_format','responses'))
    provider['max_requests']=1
    client=ProbeClient(provider,out/'transport',progress,cancelled)
    cap=config.get('output_limit',task['output_limit'])
    body=request_body(provider,prompt=task['prompt'],output_limit=cap)
    try:
        answer=client.request(body,{'task_id':task['id'],'prompt_sha256':task['prompt_sha256'],'fresh_single_question':True})
    except ProbeStop as exc:
        return {'schema':'tokenclock-task-result/v1','task_id':task['id'],'status':'limited','checks':[{
            'id':'generation.complete','status':'unknown','mandatory':True,'group':'delivery.complete','dimension':'能力与交付','reason':exc.code}],
            'accounting':client.accounting(),'source':{'kind':'live_probe' if mode=='live' else 'replay_record'},
            'stop':{'code':exc.code},'limitations':['No complete artifact was received. This is not an ability failure.']}
    generated=out/'received-answer.txt';generated.write_text(answer['text']);generated.chmod(0o600)
    if answer['limited'] or not answer['completed'] or answer['tool_calls']:
        return {'schema':'tokenclock-task-result/v1','task_id':task['id'],'status':'limited',
                'checks':[{'id':'generation.complete','status':'unknown','mandatory':True,'dimension':'能力与交付','group':'delivery.complete',
                           'observed':answer['finish_reason'],'reason':'Generation did not deliver a complete artifact under the configured limits; capability scoring was not run.'}],
                'source':{'kind':'live_probe' if mode=='live' else 'replay_record','requested_model':provider.get('model'),'response_model':answer.get('response_model')},
                'generation':{'record':answer['record'],'prompt_sha256':task['prompt_sha256'],'output_limit':cap},
                'accounting':client.accounting(),'artifacts':[{'path':str(generated),'purpose':'partial received answer; not ability graded'}],
                'limitations':['This sample remains incomplete under the recorded generation conditions. Partial text is preserved, not used as an ability failure.']}
    if config.get('_judge') and float(client.accounting().get('pending_reserved_usd','0'))>0:
        config['_judge'].stop={'code':'target_request_unsettled','detail':'待测调用费用未结，不追加评审请求'}
    result=_artifact(generated,out/'evaluation',config,cancelled,progress)
    result['source']['kind']='live_probe' if mode=='live' else 'replay_record'
    result['source']['requested_model']=provider.get('model');result['source']['response_model']=answer.get('response_model')
    result['generation']={'record':answer['record'],'prompt_sha256':task['prompt_sha256'],'output_limit':cap,
                          'conditions':{'system':None,'history':None,'tools':None,'fresh_single_question':True}}
    result['accounting']=client.accounting()
    result['checks'].append({'id':'generation.complete','status':'pass' if answer['completed'] and not answer['limited'] and not answer['tool_calls'] else 'unknown',
                            'mandatory':True,'dimension':'能力与交付','group':'delivery.complete','observed':answer['finish_reason'],
                            'reason':'Transport-limited completion is separate from artifact correctness.'})
    if answer['limited'] or not answer['completed']:result['status']='limited'
    from .diagnostics import analyze
    result['diagnostics']=analyze(client.records,metadata={'scope':'new_probe_run_only'})
    return result


def _combined(source):
    """Embedded report data only; never follow source refs or execute report config."""
    pack=load_json(source)
    if pack.get('schema')!='tokenclock-combined-input/v1' or not isinstance(pack.get('reports'),list) or not 1<=len(pack['reports'])<=12:
        raise ValueError('综合报告需要1–12份内嵌报告')
    components=[];seen=set();duplicate=0
    for item in pack['reports']:
        if not isinstance(item,dict):raise ValueError('无效的报告对象')
        key=digest(item)
        if key in seen:duplicate+=1;continue
        seen.add(key)
        components.append({'sha256':key,'report':item,'evidence_authority':'imported_report_claims_unverified'})
    return {'schema':'tokenclock-combined-result/v1','status':'completed','components':components,
            'duplicate_reports_ignored':duplicate,'identity_probability':None,'mixture_proportion':None,
            'limitations':['Layers describe acquisition cost, not evidence strength.',
                           'Reports are shown side by side; scores and correlated observations are never summed into identity probability.',
                           'Imported reports and their source claims are not authenticated backend truth. No referenced path was read.']}


def _bind_subjects(result,config,source_path):
    """Group only the declared testing subject; this is not backend attestation."""
    root_hash=hashlib.sha256(Path(source_path).read_bytes()).hexdigest()
    if config.get('transport_mode')=='live':
        p=config.get('provider',{});subject={'id':'endpoint-'+digest({'endpoint':p.get('endpoint'),'model':p.get('model'),'api_format':p.get('api_format','responses')}),
            'label':str(p.get('model','未提供型号'))[:200],'scope':'configured_endpoint_and_requested_model_not_attestation'}
    else:subject={'id':'input-'+root_hash,'label':'已有输入 '+root_hash[:8],'scope':'input_group_without_live_subject_binding'}
    result['subject']=subject
    for sample in result.get('samples',[]):
        record=sample.get('record',{});declared=record.get('requested_model') or record.get('response_model')
        if config.get('transport_mode')=='live':sample['subject']=subject
        elif declared:
            sample['subject']={'id':'declared-'+digest({'input_group':root_hash,'declared_model':declared}),
                'label':str(declared)[:200],'scope':'imported_model_declaration_within_input_group_not_attestation'}
        else:sample['subject']=subject


def _group_comparisons(result):
    from .scoring import compare_behavior
    from importlib.resources import files
    groups={}
    for sample in result.get('samples',[]):
        subject=sample.get('subject',{'id':'unbound','label':'未绑定输入组'})
        groups.setdefault(subject['id'],{'subject':subject,'samples':[]})['samples'].append(sample)
    from .reference_release import reference as load_reference
    reference=load_reference('behavior')
    comparisons=[]
    for group in groups.values():
        comparison=compare_behavior(group['samples'],reference)
        if any(s.get('semantic_assessment') for s in group['samples']):
            comparison['assessment_scope']='Includes explicitly marked model-assessed interpretations; not deterministic certification.'
            for question in comparison['questions']:
                for model in question['models']:
                    model['comparison_scope']='model_assisted_descriptive_comparison'
                    model['condition_notes'].append({'field':'extraction_method','state':'model_assessed_not_certified'})
        comparisons.append({'subject':group['subject'],'comparison':comparison})
    result['subject_comparisons']=comparisons
    if len(comparisons)==1:result['comparison']=comparisons[0]['comparison']
    else:result['comparison']={'schema':'tokenclock-behavior-comparison/v1','questions':[],'descriptive_model_summaries':[],
                              'scope':'separate_subjects_no_pooling','identity_probability':None,'mixture_proportion':None,
                              'limitations':['See subject_comparisons; different declared subjects are not pooled.']}


def _assess_language(result,judge,freeze_path=None):
    from .assessment_specs import project_features
    from .scoring import compare_behavior
    from importlib.resources import files
    batch_once=getattr(judge,'config',{}).get('batch_once',False)
    eligible=[]
    for sample in result.get('samples',[]):
        metadata=sample.get('metadata',{})
        if metadata.get('truncated') or metadata.get('completed') is False or metadata.get('unexpected_tools') or sample.get('status') in {'failed','cancelled','truncated','incomplete','limited'} or not sample.get('answer','').strip():
            sample['assessment_skipped']='generation_incomplete_or_no_reviewable_answer'
            continue
        eligible.append(sample)
    frozen=[{'id':s['id'],'task_id':s['task_id'],'answer':s['answer']} for s in eligible]
    frozen_hash=digest(frozen)
    if freeze_path is not None:write_json(freeze_path,{'schema':'tokenclock-frozen-answer-collection/v1','sha256':frozen_hash,'items':frozen,'feedback_to_target':False})
    parsed=judge.language_batch(frozen) if frozen and batch_once else None
    for sample in eligible:
        assessment=parsed[sample['id']] if parsed is not None else judge.language(sample['task_id'],sample['answer'])
        sample['semantic_assessment']=assessment
        projection=assessment['projection'];original=sample['extracted'];conflicts=[]
        for field in ('features','reference_features'):
            addition=projection.get(field,{})
            if field=='reference_features':
                for source,values in addition.items():
                    target=original.setdefault(field,{}).setdefault(source,{})
                    for key,value in values.items():
                        if key not in target or target[key]=='UNKNOWN':target[key]=value
                        elif target[key]!=value:conflicts.append({'feature':key,'scope':source,'local_value':target[key],'model_value':value})
            else:
                for key,value in addition.items():
                    target=original.setdefault(field,{})
                    if key not in target or target[key]=='UNKNOWN':target[key]=value
                    elif target[key]!=value:conflicts.append({'feature':key,'local_value':target[key],'model_value':value})
        sample['assessment_conflicts']=conflicts
        original['model_assessed_fields']=projection.get('features',{})
        original['assessment_origin']=assessment['origin']
        if projection.get('features') and sample.get('status')=='partial':original['status']=sample['status']='partial_model_assessed'
    if digest([{'id':s['id'],'task_id':s['task_id'],'answer':s['answer']} for s in eligible])!=frozen_hash:raise ValueError('Collected answers changed during interpretation')
    result['interpretation_phase']={'mode':'single_post_collection_batch' if batch_once else 'post_collection_per_answer',
        'frozen_answer_count':len(frozen),'frozen_answers_sha256':frozen_hash,'feedback_to_target':False,'automatic_retry_or_split':False}
    from .reference_release import reference as load_reference
    reference=load_reference('behavior')
    result['comparison']=compare_behavior(result.get('samples',[]),reference)
    result['assessment_status']='model_assisted_with_evidence_not_independently_certified'


def _transport_diagnostics(work):
    """Read only this controller's fixed capture paths, never source.refs."""
    root=Path(work)/'transport'
    if not root.exists() and (Path(work)/'task'/'transport').exists():root=Path(work)/'task'/'transport'
    calls_path=root/'calls.json'
    if not calls_path.is_file():return None
    records=load_json(calls_path);api_pairs=[];events={};responses={};total=0;omitted=0
    for row in records:
        n=row.get('number');rid=row.get('client_request_id')
        if type(n) is not int or not 1<=n<=64:continue
        request=root/f'{n:03d}-request.json';response=root/f'{n:03d}-response.json';event=root/f'{n:03d}-events.json'
        paths=[p for p in (request,response,event) if p.is_file() and not p.is_symlink()]
        size=sum(p.stat().st_size for p in paths)
        if total+size>64*1024*1024:omitted+=1;continue
        total+=size
        if response in paths:responses[rid]=load_json(response)
        if event in paths:events[rid]=load_json(event)
        if request in paths and response in paths:api_pairs.append({'request_id':rid,'request':load_json(request),'response':responses[rid]})
    from .diagnostics import analyze
    from .service_details import analyze as details
    result=analyze(records,metadata={'scope':'this_controller_run_only','events_by_request':events,'responses_by_request':responses})
    extra=details({'api_pairs':api_pairs})
    result['observations'].extend(extra['observations']);result['limitations'].extend(extra['limitations'])
    if omitted:result['limitations'].append(f'{omitted} raw pairs omitted by 64MiB diagnostic processing limit; raw evidence remains separately stored.')
    return result


def _role_progress(callback,purpose):
    def emit(*args,**kwargs):
        if args and isinstance(args[0],dict):
            event=dict(args[0])
            if event.get('billing_schema')=='tokenclock-probe-billing-checkpoint/v1':
                if event.get('purpose',purpose)!=purpose:raise ValueError('Billing role conflicts with executing client')
                event['purpose']=purpose
            return callback(event) if callback else None
        return callback(*args,**kwargs) if callback else None
    return emit


def run_analysis(source_path,comparison_model=None,semantic_config=None,progress=None,cancelled=None,output_dir=None):
    config=validate_config(semantic_config);mode=config.get('workflow_mode','l1')
    from .reference_release import overview
    release=overview()  # Verify before constructing a paid target or judge client.
    if mode=='l1':
        from ..l1.pipeline import run_analysis as l1
        return l1(source_path,comparison_model,config,progress,cancelled,output_dir)
    out=Path(output_dir).absolute()
    out.mkdir(mode=0o700,exist_ok=False)
    check_cancelled(cancelled)
    if progress:progress(stage='probe_preparing',message='准备已选任务与固定输入',fraction=.05)
    work=out/'evidence';work.mkdir(mode=0o700)
    if config['assessment']['enabled']:
        from .assessment import JudgeRunner
        config['_judge']=JudgeRunner(config['assessment'],work/'assessment',work,_role_progress(progress,'judge'),cancelled,
            target_connection=config.get('provider') if config.get('transport_mode')=='live' else None)
        if mode=='l3' and config.get('task_id','').startswith('H04'):config['_judge'].ensure_visual_configuration()
    progress=_role_progress(progress,'target')
    if mode=='l2':
        if config.get('l2_method')=='numeric':
            from .numeric_fingerprint import run
        else:
            from .l2 import run
        result=run(source_path,work,config,cancelled,progress)
    elif mode=='l3':
        task_id=config.get('task_id','H01');transport=config.get('transport_mode','artifact')
        if transport=='artifact':result=_artifact(source_path,work/'evaluation',config,cancelled,progress)
        elif task_id=='H03':
            from .h03 import run
            result=run(source_path,work/'task',config,cancelled,progress)
        else:result=_single_generation(source_path,work,config,cancelled,progress)
    elif mode=='diagnostics':
        from .diagnostics import analyze
        capture=load_json(source_path)
        result=analyze(capture,metadata={'scope':'supplied_capture_only'})
        from .service_details import analyze as details
        detail_capture=capture
        if isinstance(capture,dict) and 'api_pairs' not in capture and (isinstance(capture.get('request'),dict) or isinstance(capture.get('response'),dict)):
            detail_capture={**capture,'api_pairs':[{'request_id':capture.get('request_id'),'request':capture.get('request'),'response':capture.get('response')}]}
        extra=details(detail_capture);result['observations'].extend(extra['observations']);result['limitations'].extend(extra['limitations'])
    else:result=_combined(source_path)
    check_cancelled(cancelled)
    judge=config.get('_judge')
    if judge and float(result.get('accounting',{}).get('pending_reserved_usd','0'))>0:
        judge.stop={'code':'target_request_unsettled','detail':'待测调用费用未结，不追加评审请求'}
    if judge and mode=='l2':
        _assess_language(result,judge,work/'answers-before-interpretation.json')
    if judge and mode=='l3' and config.get('task_id')=='H03' and (work/'task'/'history.json').is_file():
        result['process_assessment']=judge.process(result,load_json(work/'task'/'history.json'))
    if judge:
        result['assessment_relationship']=judge.relationship
        if result.get('visual_assessment'):
            result['visual_assessment']['assessment_relationship']=judge.relationship
            if result['visual_assessment'].get('quality'):result['visual_assessment']['quality']['assessment_relationship']=judge.relationship
        result['reviewer_assessment']=judge.summary()
        if result.get('assessment_quality'):
            result['reviewer_assessment']['quality']=result['assessment_quality']
            if result['assessment_quality']['status']!='usable_observations':result['reviewer_assessment']['status']='limited'
        else:result['assessment_quality']=result['reviewer_assessment']['quality']
        write_json(work/'reviewer-result.json',result['reviewer_assessment'])
    if mode=='l3':
        from .fingerprints import measurement_contract
        result['measurement_contract']=measurement_contract(result.get('task_id',config.get('task_id')),result.get('variant'))
        if config.get('transport_mode','artifact')=='artifact' and config.get('task_id')!='H03':
            result.setdefault('measurement_context',{})['answer_characters']=len(Path(source_path).read_text())
    if mode in {'l2','l3'}:
        diagnostic=_transport_diagnostics(work)
        if diagnostic is not None:result['diagnostics']=diagnostic
    if result.get('tool_events'):
        from .trajectory import analyze as analyze_trajectory
        result['trajectory']=analyze_trajectory(result['tool_events'])
    if 'checks' in result and mode!='diagnostics':result['score']=score_checks(result['checks'])
    if mode in {'l2','l3'}:_bind_subjects(result,config,source_path)
    if mode=='l2' and config.get('l2_method')!='numeric':_group_comparisons(result)
    result=_normalize_paths(result,out)
    report={'schema':'tokenclock-product-report/v1','workflow_mode':mode,'result':result,
            'summary':{'status':result.get('status','completed'),'scope':mode,'identity_status':'not_authenticated',
                       'full_task_pass':result.get('score',{}).get('full_task_pass')},
            'source':{'sha256':hashlib.sha256(Path(source_path).read_bytes()).hexdigest(),'name':Path(source_path).name},
            'identity_probability':None,'mixture_proportion':None}
    from ..l1.render import redact
    def scrub(v):
        if isinstance(v,dict):return {k:scrub(x) for k,x in v.items()}
        if isinstance(v,list):return [scrub(x) for x in v]
        return redact(v) if isinstance(v,str) else v
    from .fingerprints import compare as compare_fingerprints
    report['result']['fingerprints']=compare_fingerprints(report)
    report['reference_release']={k:release[k] for k in ('release_id','manifest_sha256','data_version','verified_on')}
    from .history_comparison import make_context
    report['history_context']=make_context(report,config)
    from .fingerprint_summary import summarize
    report['result']['fingerprint_interpretation']=summarize(report['result']['fingerprints'])
    from .user_summary import summarize as user_summary
    report['user_summary']=user_summary(report)
    from .recommendations import recommend
    report['user_summary']['recommendation']=recommend(report,config)
    from .result_brief import build_brief
    report['user_summary']['brief']=build_brief(report)
    report=scrub(report)
    write_json(out/'observation.json',report['result'])
    write_json(out/'report.json',report)
    from .report import render_report
    (out/'report.html').write_text(render_report(report,out));(out/'report.html').chmod(0o600)
    # Raw artifacts are only available as an attachment, never active UI content.
    from .common import archive_evidence
    archive_evidence(work,out/'evidence.zip')
    if progress:progress(stage='reporting',message='评估与证据已整理',fraction=1)
    return report
