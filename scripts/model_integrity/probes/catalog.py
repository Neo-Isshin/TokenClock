"""Versioned original prompt catalog. Gold never enters request construction."""
from importlib.resources import files
import json

DEFAULTS={'openai':['O07:A','C06:A','O05:A'],'anthropic':['O06:B','C02:B','O05:A']}


def catalog():
    result=json.loads(files('scripts.model_integrity.probes').joinpath('resources/catalog.json').read_text())
    from .features import SUPPORTED_TASKS
    for task in result['tasks']:
        if task['layer']=='L2':task['automatic_extraction']='supported' if task['id'] in SUPPORTED_TASKS else 'partial'
    return result


def get_task(task_id):
    matches=[x for x in catalog()['tasks'] if x['id']==task_id]
    if len(matches)!=1:raise ValueError('Unknown task: '+str(task_id))
    return matches[0]


def l2_plan(family='openai',task_ids=None,repeats=2):
    if family not in DEFAULTS:raise ValueError('选择openai或anthropic题包，或提供已有任务ID')
    selected=task_ids or DEFAULTS[family]
    if not isinstance(selected,list) or not 1<=len(selected)<=5 or len(set(selected))!=len(selected):
        raise ValueError('L2每次选择1–5个不同题目')
    if type(repeats) is not int or repeats!=2:raise ValueError('当前L2协议每题独立重复2次')
    tasks=[get_task(x) for x in selected]
    if any(t['layer']!='L2' for t in tasks):raise ValueError('Not an L2 question')
    return [{'index':i*len(tasks)+j+1,'repeat':i+1,'task':t} for i in range(repeats) for j,t in enumerate(tasks)]
