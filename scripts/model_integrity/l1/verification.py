"""History-aware summaries of visible checks, without inferring hidden repairs."""
from __future__ import annotations

import copy
import json

from .engine import _arguments, _command, _name, _path_kind, _paths
from scripts.model_integrity.m10_features import command_segments


def attach_verification(document, report):
    result=copy.deepcopy(report)
    records=document.get('records',[])
    index=result.get('record_index',{})
    snapshot_changes=set()
    previous_snapshots={}
    for n,r in enumerate(records):
        if not isinstance(r,dict) or r.get('kind')!='artifact_snapshot':continue
        d=r.get('data',{})
        if not isinstance(d,dict) or not isinstance(d.get('path'),str) or not isinstance(d.get('content'),str):continue
        key=(d['path'],r.get('generation_id'),r.get('stage'))
        if key in previous_snapshots and previous_snapshots[key]!=d['content']:snapshot_changes.add(n)
        previous_snapshots[key]=d['content']

    def locate(eid):
        entry=index.get(eid)
        if isinstance(entry,dict):
            pointer=entry.get('pointer','')
            if pointer.startswith('/records/'):
                try:
                    n=int(pointer.split('/')[-1]);r=records[n]
                    if n>=0 and isinstance(r,dict):return n,r
                except (ValueError,IndexError):pass
        found=[(i,r) for i,r in enumerate(records) if isinstance(r,dict) and r.get('id')==eid]
        return found[0] if len(found)==1 else (None,None)

    groups={}
    for fact in result.get('facts',[]):
        if fact.get('code')!='process.test_result':continue
        pointers=[locate(eid) for eid in fact.get('evidence',[])]
        calls=[(n,r) for n,r in pointers if r and r.get('kind')=='tool_call']
        outputs=[(n,r) for n,r in pointers if r and r.get('kind')=='tool_result']
        if len(calls)!=1 or len(outputs)!=1:continue
        cn,call=calls[0];on,output=outputs[0]
        command=_command(call)
        args=_arguments(call)
        signature={'tool':_name(call),'command':command_segments(command) if command else None,
                   'arguments':args if not command else {k:v for k,v in args.items() if k not in {'cmd','command','yield_time_ms','max_output_tokens','timeout','timeout_ms'}}}
        generation=output.get('generation_id',call.get('generation_id'))
        stage=output.get('stage',call.get('stage'))
        actor=fact.get('actor','unknown')
        key=json.dumps([signature,generation,stage,actor],ensure_ascii=False,sort_keys=True)
        group=groups.setdefault(key,{'signature':signature,'generation_id':generation,'stage':stage,'actor':actor,
            'checks':[],'historical_failures':[],'resolved_failure_ids':[],'evidence':[]})
        check={'result':fact['value'],'record_id':output['id'],'order':on,'evidence':fact['evidence']}
        group['checks'].append(check)
        group['evidence'].extend(fact['evidence'])
    for group in groups.values():
        checks=sorted(group['checks'],key=lambda c:c['order']);last=checks[-1]
        failures=[c for c in checks if c['result']=='fail']
        group['historical_failures']=[c['record_id'] for c in failures]
        group['last_result']=last['result']
        later=records[last['order']+1:]
        gaps=[r for r in later if isinstance(r,dict) and r.get('kind')=='gap']
        changes=[]
        for offset,r in enumerate(later,last['order']+1):
            if not isinstance(r,dict):continue
            if group['generation_id'] and r.get('generation_id') and group['generation_id']!=r['generation_id']:continue
            if group['stage'] and r.get('stage') and group['stage']!=r['stage']:continue
            if r.get('kind')=='artifact_snapshot' and isinstance(r.get('data'),dict):
                if offset in snapshot_changes and _path_kind(r['data'].get('path',''))=='other_or_production':changes.append(r)
            elif r.get('kind')=='tool_call' and r.get('role')==group['actor'] and _name(r) in {'edit','write','apply_patch','patch','multiedit','edit_file','write_file'}:
                if any(_path_kind(p)=='other_or_production' for p in _paths(r)):changes.append(r)
        if last['result']=='pass':
            group['resolved_failure_ids']=[c['record_id'] for c in failures if c['order']<last['order']]
        group['evidence']=list(dict.fromkeys(group['evidence']))
        if gaps:
            group['state']='unknown_after_gap';group['evidence'] += [r['id'] for r in gaps]
        elif changes:
            group['state']='latest_change_unverified';group['evidence'] += [r['id'] for r in changes]
        elif last['result']=='fail':group['state']='observed_failure'
        elif group['resolved_failure_ids']:group['state']='recovered_checks'
        else:group['state']='observed_pass'
        group['interpretation']='Only the same visible check and recorded scope are summarized; a later pass is not proof of all task correctness or of a production-code repair.'
    values=list(groups.values())
    target=[g for g in values if g['actor']=='assistant']
    states={g['state'] for g in target}
    if not target:current='no_checks'
    elif 'observed_failure' in states:current='observed_failure'
    elif 'unknown_after_gap' in states:current='mixed_or_unknown'
    elif 'latest_change_unverified' in states:current='latest_change_unverified'
    elif 'recovered_checks' in states:current='recovered_checks'
    else:current='observed_pass'
    result['verification_history']={'schema':'tokenclock-visible-verification-history/v1','groups':values,
        'current_status':current,'scope':'visible_checks_only','production_repair_success_rate':None,
        'limitations':['Different commands, actors, generations or explicit stages do not silently clear each other.',
                      'Missing later history is unknown. Reported passing checks do not establish overall correctness.']}
    source_diff=result.get('summary',{}).get('source_status')=='declaration_difference'
    if not source_diff and current in {'recovered_checks','observed_pass'}:
        other_issues=any(f.get('code') in {'process.edit_outside_explicit_scope','process.unverified_completion_claim','process.latest_change_unverified'} for f in result.get('facts',[]))
        if not other_issues:
            result['summary']['quality_status']='visible_checks_recovered' if current=='recovered_checks' else 'visible_checks_passed'
            result['summary']['headline']='已见同项检查后续通过，历史失败已保留' if current=='recovered_checks' else '可见检查已通过，其他约束按证据范围判断'
    elif not source_diff and current=='latest_change_unverified':
        result['summary']['quality_status']='latest_version_unverified'
        result['summary']['headline']='有后续修改尚未见对应验证'
    elif not source_diff and current=='no_checks' and result.get('semantic',{}).get('coverage',{}).get('explicit_observations',0):
        result['summary']['quality_status']='semantic_observations_only'
        result['summary']['headline']='已整理会话中的要求、条件与判断变化'
    return result
