"""Read-only, zero-dispatch task preview. The dispatcher shares its quote function."""
from __future__ import annotations
from copy import deepcopy
from decimal import Decimal
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit
from ..probes.catalog import get_task,l2_plan
from ..probes.transport import quote_request,request_body,money,ProbeStop
from ..probes.common import digest


def _source(path):
    if not isinstance(path,str) or not path:raise ValueError('请先选择会话或待核验文件')
    source=Path(path).expanduser().absolute()
    fd=os.open(source,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size>64*1024*1024:raise ValueError('请选择64 MiB以内的普通文本文件')
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(64*1024*1024+1)
        if len(raw)>64*1024*1024:raise ValueError('文件在读取中超过大小上限')
        after=os.fstat(fd)
        if (st.st_mtime_ns,st.st_size)!=(after.st_mtime_ns,after.st_size):raise ValueError('源文件仍在变化，请选择稳定快照')
        return source,raw.decode('utf-8')
    finally:os.close(fd)


def _provider(value,role):
    if not isinstance(value,dict):raise ValueError('请填写'+role+'连接')
    p=deepcopy(value);p.pop('api_key',None)
    if not p.get('endpoint') or not p.get('model'):raise ValueError('请填写'+role+'接口地址和型号')
    u=urlsplit(p['endpoint'])
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment:raise ValueError(role+'接口需为不含密钥或查询参数的HTTPS地址')
    for key in ('input_usd_per_million','output_usd_per_million','max_cost_usd'):
        if p.get(key) is None:raise ValueError('请填写'+role+'的输入、输出单价和本次费用上限')
        try:p[key]=str(money(p[key]))
        except ValueError:raise ValueError(role+'的费用配置必须是有效的非负数字') from None
    if money(p['max_cost_usd'])<=0:raise ValueError(role+'费用上限必须大于0')
    for key,default,minimum,maximum in [('max_requests',20,1,64),('wall_seconds',900,1,3600),('max_output_tokens',24576,256,262144)]:
        n=p.get(key,default)
        if type(n) is not int or not minimum<=n<=maximum:raise ValueError(role+'的'+key+'设置无效')
    p['transport_mode']='live'
    request_body(p,prompt='',output_limit=p.get('max_output_tokens',24576))
    return p


def _role(name,provider,quotes,count,sends,*,complete=True,kind='exact_first_request',notes=()):
    budget=money(provider['max_cost_usd']);amounts=[money(q['reserved_usd']) for q in quotes]
    first=amounts[0] if amounts else None
    total=sum(amounts,Decimal(0)) if complete else None
    return {'role':name,'enabled':True,'max_requests':count,'budget_usd':str(budget),
            'per_request_reserve_usd':str(first) if first is not None else None,
            'whole_run_upper_usd':str(total) if total is not None else None,
            'budget_may_be_insufficient':total>budget if total is not None else None,
            'first_request_affordable':first<=budget if first is not None else None,
            'reservation_kind':kind,'sends':list(sends),'notes':list(notes),
            'wall_seconds':provider.get('wall_seconds',900),'automatic_retries':0}


def preview(config,source_path=None):
    if isinstance(config,dict) and config.get('workflow_mode')=='codex':
        from ..probes.codex_local import preview as local_preview
        return local_preview(config)
    result={'schema':'tokenclock-task-preview/v1','valid':False,'errors':[],'warnings':[],
            'roles':[],'local_only':True,'total_upper_usd':None,'total_budget_usd':'0',
            'network_requests':0,'model_requests':0,'creates_job':False}
    try:
        if not isinstance(config,dict):raise ValueError('检测配置无效')
        def without_keys(value):
            if isinstance(value,dict):return {k:without_keys(v) for k,v in value.items() if str(k).lower().replace('-','_') not in {'api_key','authorization','password','secret','access_token'}}
            if isinstance(value,list):return [without_keys(v) for v in value]
            return value
        from ..probes.review_config import resolve_shared_review
        cfg=resolve_shared_review(without_keys(config),include_secret=False);lane=cfg.get('workflow_mode','l1');mode=cfg.get('transport_mode','artifact' if lane=='l3' else 'replay')
        if lane not in {'l1','l2','l3','diagnostics','combined'}:raise ValueError('请选择已支持的检测方式')
        result['workflow_mode']=lane;result['transport_mode']=mode
        source,text=(None,None)
        if lane not in {'l2','l3'} or mode not in {'live','demo'}:source,text=_source(source_path)
        if lane=='l1':
            from .ingest import load_observation
            try:load_observation(source_path,max_bytes=64*1024*1024)
            except (ValueError,KeyError,TypeError):raise ValueError('未识别为受支持的会话记录；程序、网页或SVG请使用“核验文件”') from None
        if lane in {'diagnostics','combined'}:
            from .ingest import strict_loads
            pack=strict_loads(text)
            if not isinstance(pack,dict):raise ValueError('请导入JSON对象形式的记录')
            if lane=='combined' and (pack.get('schema')!='tokenclock-combined-input/v1' or not isinstance(pack.get('reports'),list) or not 1<=len(pack['reports'])<=12):raise ValueError('合并文件需内嵌1–12份报告')
        if lane in {'l2','l3'} and mode not in {'live','demo','artifact','replay'}:raise ValueError('请选择已支持的执行方式')
        assessment=cfg.get('assessment') or {}
        if not isinstance(assessment,dict):raise ValueError('评审配置无效')
        reviewing=assessment.get('enabled') is True
        if reviewing and lane not in {'l2','l3'}:raise ValueError('此处的模型评审只适用于轻量回答或重型任务')
        judge_live=reviewing and assessment.get('transport_mode','replay')=='live'
        if reviewing and assessment.get('transport_mode','replay') not in {'live','replay'}:raise ValueError('评审执行模式无效')
        plan=[];imported=[];task=None
        numeric=lane=='l2' and cfg.get('l2_method')=='numeric'
        if numeric:
            from ..probes.numeric_fingerprint import plan as numeric_plan,provider as numeric_provider,ensure_runtime
            ensure_runtime();plan=numeric_plan(cfg)
            if reviewing:raise ValueError('数字指纹在本地评分，无需模型辅助解析。')
            if mode=='artifact':
                from .ingest import strict_loads
                pack=strict_loads(text)
                if pack.get('schema')!='tokenclock-numeric-answer-set/v1' or len(pack.get('samples',[]))!=3:raise ValueError('数字指纹回答包需要三份原题和回答。')
                for cell,row in zip(plan,pack['samples']):
                    if row.get('prompt')!=cell['task']['prompt'] or not isinstance(row.get('answer'),str):raise ValueError('回答包题面与冻结数字题不一致。')
        if lane=='l2':
            if numeric:pass
            elif mode=='artifact':
                from .ingest import strict_loads
                pack=strict_loads(text)
                if not isinstance(pack,dict) or pack.get('schema')!='tokenclock-l2-answer-set/v1' or not isinstance(pack.get('samples'),list) or not 1<=len(pack['samples'])<=10:
                    raise ValueError('轻量回答文件需包含1–10份原题和回答；请选择回答包或改用会话分析')
                for sample in pack['samples']:
                    if not isinstance(sample,dict) or not isinstance(sample.get('answer'),str):raise ValueError('每份回答需包含原题与文本')
                    if any(type(sample[k]) is not bool for k in ('completed','truncated') if k in sample):raise ValueError('回答完成与截断标记应为布尔值')
                    t=get_task(sample.get('task_id'))
                    if t['layer']!='L2' or t['prompt']!=sample.get('prompt'):raise ValueError('回答包的题干与当前题库不一致')
                    if len(sample['answer'].encode())>1024*1024:raise ValueError('单份回答超过1 MiB')
                    if sample.get('completed',True) and not sample.get('truncated') and sample.get('status','completed') not in {'failed','cancelled','incomplete','truncated','length','max_tokens'}:imported.append(sample)
            else:
                plan=l2_plan(cfg.get('family','openai'),cfg.get('task_ids'),cfg.get('repeats',2))
                from ..probes.features import SUPPORTED_TASKS
                if mode in {'live','demo'} and not reviewing and any(c['task']['id'] not in SUPPORTED_TASKS for c in plan):
                    raise ValueError('所选题目需要模型辅助提取；请启用评审或选择支持本地提取的题目')
                if mode=='demo':
                    from ..probes.l2 import _demo_text
                    for cell in plan:_demo_text(cell['task']['id'])
        if lane=='l3':
            task=get_task(cfg.get('task_id','H01'))
            if task['layer']!='L3':raise ValueError('请选择重型任务')
            if mode=='demo' and task['id']!='H03':raise ValueError('此重型任务没有脚本演示')
        if lane in {'l2','l3'} and mode=='live':
            p=_provider(numeric_provider(cfg) if numeric else cfg.get('provider'),'待测');quotes=[]
            if lane=='l2':
                count=min(len(plan),p.get('max_requests',len(plan)))
                quotes=[quote_request(p,request_body(p,prompt=c['task']['prompt'],output_limit=c['task']['output_limit'])) for c in plan[:count]]
                role=_role('target',p,quotes,count,['所选原题，每题使用全新上下文'],notes=['报价为这些请求在生成上限内的保守预留之和，实际费用通常较少。'])
            elif task['id']=='H03':
                from ..probes.h03 import task as h03_task,TOOLS,SYSTEM
                spec=h03_task(cfg.get('variant','pipeline'));cap=cfg.get('output_limit',65536)
                body=request_body(p,history=[{'role':'user','content':spec['stages'][0]['prompt']}],tools=TOOLS,output_limit=cap,system=SYSTEM)
                role=_role('target',p,[quote_request(p,body)],min(p.get('max_requests',24),64),
                           ['原题、受控工作区文件及本任务工具返回'],complete=False,
                           notes=['首请求可预留；后续上下文随工具操作增长，无法预先给出整轮准确上界。每次发送前仍重新检查预算。'])
            else:
                body=request_body(p,prompt=task['prompt'],output_limit=cfg.get('output_limit',task['output_limit']))
                role=_role('target',p,[quote_request(p,body)],1,['所选原题；不发送旧会话'])
            result['roles'].append(role)
        if judge_live:
            if lane=='l2' and mode=='artifact' and not imported:raise ValueError('输入中没有可用于评审的完整回答，请关闭付费评审并保留未完成记录')
            if mode=='demo':raise ValueError('演示使用固定脚本回答，请关闭付费评审')
            if lane=='l3' and (task['id'] in {'H01','H02'} or (task['id']=='H03' and mode=='artifact')):
                raise ValueError('此方式由本地检查核验，没有可发送的评审内容；请关闭模型评审')
            p=_provider(assessment.get('provider'),'评审');batch=assessment.get('batch_once',False)
            if type(batch) is not bool or (batch and lane!='l2'):raise ValueError('一次批量解析仅用于轻量回答')
            repeat=assessment.get('repeats',1 if batch else 2)
            if type(repeat) is not int or repeat not in {1,2}:raise ValueError('评审次数应为1或2')
            if batch and repeat!=1:raise ValueError('一次批量解析只发送一次请求')
            from ..probes.assessment import build_body,OPENAI_PATCH_MODELS
            count=min((len(imported) if mode=='artifact' and lane=='l2' else len(plan) if lane=='l2' else 1)*repeat,p.get('max_requests',20))
            if batch:count=1
            if lane=='l3' and task['id'].startswith('H04'):
                allowance=p.get('image_tokens_upper_per_image');registered=p['model'].split('/')[-1] in OPENAI_PATCH_MODELS and p.get('api_format','responses') in {'responses','chat_completions'}
                if allowance is not None and (type(allowance) is not int or not 1<=allowance<=1000000):raise ValueError('每张图像的token预留设置无效')
                if not registered and allowance is None:raise ValueError('该评审型号尚无图像计量登记，请设置每张图像的token预留上限')
            quotes=[]
            if lane=='l2' and mode=='artifact':
                if batch:
                    from ..probes.batch_assessment import build_language_batch_request
                    payload=build_language_batch_request([{'id':f'preview-{i+1:03d}','task_id':sample['task_id'],'answer':sample['answer']} for i,sample in enumerate(imported)])
                    quotes=[quote_request(p,build_body(p,payload))]
                else:
                    from ..probes.assessment_specs import build_request
                    for sample in imported:
                        q=quote_request(p,build_body(p,build_request(sample['task_id'],sample['answer'])))
                        quotes.extend([q]*repeat)
                quotes=quotes[:count]
            role=_role('judge',p,quotes,count,['经隐藏型号标签的回答片段' if lane=='l2' else '实际渲染的图像和原题判据' if task['id'].startswith('H04') else '目标工具轨迹及返回内容'],
                       complete=lane=='l2' and mode=='artifact',kind='exact_first_request' if quotes else 'unavailable_until_content',
                       notes=['重复两次使用同一个评审型号，不等于两位独立评审者。' if repeat==2 else '单次评审仅提供一份辅助意见。',
                              '待回答或图像生成后，才有足够内容计算实际请求的完整预留。'] if not quotes else ['评审不接收历史参考答案；引用通过仍不保证解释正确。'])
            result['roles'].append(role)
            if batch:role['notes'].append('先收集并冻结全部可解析回答，之后一次请求解析；不反馈给待测过程，不自动拆批或重试。')
            if assessment.get('connection_source')=='target':role['notes'].append('复用待测API承担解析；职责与账本分开，解析不构成独立来源证明。')
        if lane=='l1' and (cfg.get('external') or {}).get('enabled'):
            p=_provider({**cfg['external'],'api_format':'chat_completions'},'语义增强')
            if not 256<=p.get('max_output_tokens',4096)<=32768:raise ValueError('会话语义评审的输出上限应在256–32768 token内')
            from .ingest import load_observation
            from .semantic import prepare_external_request
            observation=load_observation(source_path,max_bytes=64*1024*1024)
            prepared=prepare_external_request(observation,max_records=min(64,max(1,int(p.get('max_records',40)))),
                max_record_characters=min(16000,max(1,int(p.get('max_record_characters',6000)))),max_input_tokens=p.get('max_input_tokens',16000))
            if not prepared['payload']['records']:raise ValueError('当前范围没有适合发送的完整文本片段，请改用本地分析')
            # This older L1 transport has its own recorded bound, not ProbeClient's image accounting.
            upper=prepared['input_token_admission_upper_bound'];cap=p.get('max_output_tokens',4096)
            reserve=(Decimal(upper)*money(p['input_usd_per_million'])+Decimal(cap)*money(p['output_usd_per_million']))/Decimal(1000000)+Decimal('.01')
            result['roles'].append(_role('judge',p,[{'reserved_usd':str(reserve)}],1,['所选范围内经隐藏型号标签的会话文本']))
        for role in result['roles']:
            if role['first_request_affordable'] is False:result['errors'].append(('待测' if role['role']=='target' else '评审')+'预算不足以预留第一条完整请求；请调整本次预算或检测方式')
            elif role['budget_may_be_insufficient']:result['warnings'].append(('待测' if role['role']=='target' else '评审')+'预算未覆盖整组最坏用量，可能在部分完成后停止；不会自行缩短生成上限')
        result['local_only']=not bool(result['roles'])
        if all(role['whole_run_upper_usd'] is not None for role in result['roles']):result['total_upper_usd']=str(sum((money(role['whole_run_upper_usd']) for role in result['roles']),Decimal(0)))
        result['total_budget_usd']=str(sum((money(role['budget_usd']) for role in result['roles']),Decimal(0)))
        from ..probes.reference_readiness import readiness
        result['reference_readiness']=readiness(cfg)
        result['valid']=not result['errors']
        result['configuration_sha256']=digest(cfg) # opaque; never an authorization token
    except (ValueError,TypeError,KeyError,OSError,UnicodeError,ProbeStop) as exc:
        from .render import redact
        message=exc.code if isinstance(exc,ProbeStop) else str(exc)
        result['errors'].append(redact(message));result['valid']=False
    return result
