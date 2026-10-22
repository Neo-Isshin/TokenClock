"""Local reference coverage before purchase; no scoring or network calls."""
from importlib.resources import files
import json
from .catalog import get_task, l2_plan
from .common import digest
from .fingerprints import measurement_contract
from .reference_labels import reference_label, MODEL_FAMILIES
from .features import SUPPORTED_TASKS


def load_reference():
    from .reference_release import reference
    return reference('fingerprint')


def conditions(task, provider):
    return {'system':None,'history':None,'tools':None,'feedback':None,
            'reasoning_effort':provider.get('reasoning_effort','high'),
            'generation_limit':task['output_limit'],'fresh_single_question':True}


def _descriptors(cell):
    output={}
    for key,row in cell.get('descriptors',{}).items():
        n=row.get('known_n');counts=row.get('counts')
        if (type(n)is int and n>=2 and isinstance(counts,dict) and counts
                and all(type(v)is int and v>0 for v in counts.values()) and sum(counts.values())==n
                and row.get('unknown_or_missing_n',0)==0):output[key]=row
    return output


def readiness(config, reference=None):
    lane=config.get('workflow_mode','l1');provider=config.get('provider') or {}
    base={'schema':'tokenclock-reference-readiness/v1','status':'local_only','tasks':[],
          'network_requests':0,'model_requests':0,'identity_accuracy_validated':False,
          'title':'先检查已有记录','summary':'这一步在本机完成，不会证明历史会话的真实型号。'}
    if lane not in {'l2','l3'}:return base
    if lane=='l2' and config.get('l2_method')=='numeric':
        from .numeric_fingerprint import reference as numeric_reference,overview
        ref=numeric_reference();label=str(provider.get('model','')).split('/')[-1]
        covered=label in {m['id'] for m in ref['bank']['models']}
        base.update(status='external_reference',title='数字串指纹 · 59个参考型号',
            summary='三次独立请求，在本机自动给出最接近的型号。'+('填写的型号暂无参考，结果仅作候选比较。' if not covered else ''),
            reference_provenance='external_method_not_independent_local_validation',
            external_reference=overview(),target_reference=label if covered else None)
        return base
    ref=reference if reference is not None else load_reference()
    base['reference_snapshot']=digest(ref);base['reference_version']=ref.get('version')
    base['coverage_basis']='recorded_conditions_and_registered_task_version'
    base['reference_provenance']='historical_declared_labels_not_backend_authentication'
    label=reference_label(provider.get('model'));base['target_reference']=label
    if config.get('transport_mode')!='live':
        base.update(status='existing_input',title='核验已有内容',summary='可检查已有内容；不会把导入材料当成新发生的模型调用。');return base
    if lane=='l3':
        base.update(status='delivery_only',title='先看这次任务是否做好',summary='任务检查可以进行；一次任务表现不足以确认型号。')
        base['tasks']=[{'task_id':config.get('task_id','H01'),'status':'delivery_only'}];return base
    tasks={c['task']['id']:c['task'] for c in l2_plan(config.get('family','openai'),config.get('task_ids'),config.get('repeats',2))}
    family=next((v for v in MODEL_FAMILIES.values() if label in v),())
    for task_id,task in tasks.items():
        row={'task_id':task_id,'title':task['title'],'status':'missing','candidates':[], 'has_observed_separation':False}
        eligible=[c for c in ref.get('cells',[]) if c.get('bank')=='behavior' and c.get('dimension')=='behavior'
                  and c.get('origin')=='deterministic_extractor' and c.get('task_id')==task_id and c.get('model_label') in family]
        compatible=[c for c in eligible if c.get('conditions')==conditions(task,provider)
                    and c.get('measurement_contract')==measurement_contract(task_id)]
        grouped={}
        for cell in compatible:grouped.setdefault(cell['model_label'],[]).append(cell)
        # Duplicate strata are not silently pooled into extra reference samples.
        models={m:cells[0] for m,cells in grouped.items() if len(cells)==1}
        target=_descriptors(models.get(label,{}))
        if task_id not in SUPPORTED_TASKS:row['status']='needs_interpretation'
        elif target:
            for model,cell in models.items():
                if model==label:continue
                for name,prior in _descriptors(cell).items():
                    if name not in target or prior.get('encoding')!=target[name].get('encoding'):continue
                    a,b=target[name],prior
                    separated=any(a['counts'].get(k,0)*b['known_n'] != b['counts'].get(k,0)*a['known_n'] for k in a['counts'].keys()|b['counts'].keys())
                    row['has_observed_separation'] |= separated
                    if model not in row['candidates']:row['candidates'].append(model)
            row['status']='comparable' if row['candidates'] and row['has_observed_separation'] else 'no_separation' if row['candidates'] else 'target_only'
        elif any(c.get('model_label')==label for c in eligible):row['status']='conditions_or_samples_missing'
        base['tasks'].append(row)
    ready=sum(r['status']=='comparable' for r in base['tasks']);total=len(tasks)
    base.update(comparable_tasks=ready,total_tasks=total)
    if ready==total:
        base.update(status='ready',title='这些题有可对照的参考',summary=f'{total} 道题都有目标型号与其他型号的参考。是否能区分，还要看这次的重复回答。')
    elif ready:
        base.update(status='partial',title='部分题目有可对照的参考',summary=f'{total} 道题中有 {ready} 道可作型号间对照，其余只保留本次观察。')
    elif not label:
        base.update(status='no_reference',title='这个型号暂时没有参考',summary='仍可收集回答，但本轮不能据此判断它更像哪个型号。')
    elif any(r['status']=='no_separation' for r in base['tasks']):
        base.update(status='no_separation',title='这些题的参考暂时分不出差别',summary='不建议为区分型号重复购买这组题；可以改选有参考差异的题。')
    else:
        base.update(status='conditions_or_samples_missing',title='当前条件下，参考还不够',summary='题目、生成条件或参考数量未满足对照要求；重复发送也不能补齐参考库。')
    return base
