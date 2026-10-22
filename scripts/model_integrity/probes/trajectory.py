"""Observable tool chains. Evaluator actions and task stages stay separate."""
from __future__ import annotations
from collections import Counter
import hashlib


def analyze(events):
    counts=Counter();reads={};rows=[];recoveries=[];pending_failure={}
    for index,event in enumerate(events):
        actor=event.get('actor','unknown');name=event.get('name');stage=event.get('stage')
        output=event.get('output') or {};args=event.get('arguments') or {}
        if actor not in {'target','simulated_target'}:continue
        counts[name]+=1
        evidence={'pointer':'/tool_events/'+str(index),'event_id':event.get('id')}
        row={'event_id':event.get('id'),'stage':stage,'actor':actor,'action':name,'status':event.get('status'),
             'workspace_changed':event.get('workspace_before')!=event.get('workspace_after'),'evidence':evidence}
        if name=='read_file' and isinstance(output.get('text'),str):
            path=output.get('path',args.get('path'));reads[(actor,stage,path)]=event.get('id')
            row.update(path=path,delivered_bytes=len(output['text'].encode()),complete_read_reported=output.get('complete'),
                       delivered_sha256=hashlib.sha256(output['text'].encode()).hexdigest())
        if name=='write_file':
            row.update(path=args.get('path'),prior_read_event=reads.get((actor,stage,args.get('path'))))
            if row['workspace_changed']:
                for key,value in pending_failure.items():
                    if key[:2]==(actor,stage):value['intervening_changes'].append(event.get('id'))
        if name=='run_checks' and isinstance(output.get('checks'),list):
            failed=[c['id'] for c in output['checks'] if c.get('status')=='fail']
            passed=[c['id'] for c in output['checks'] if c.get('status')=='pass']
            row.update(failed_check_ids=failed,passed_check_ids=passed)
            for check_id in passed:
                old=pending_failure.pop((actor,stage,check_id),None)
                if old:recoveries.append({**old,'subsequent_check_event':event.get('id'),'now_passing_ids':[check_id],
                    'meaning':'Same-actor same-stage check changed from fail to pass; intervening changes are observed, not a proven causal explanation.'})
            for check_id in failed:
                key=(actor,stage,check_id)
                pending_failure.setdefault(key,{'actor':actor,'stage':stage,'failure_event':event.get('id'),
                                               'failed_check_ids':[check_id],'intervening_changes':[]})
        rows.append(row)
    return {'schema':'tokenclock-probe-trajectory/v1','tool_counts':dict(counts),'events':rows,'observed_recovery_chains':recoveries,
            'unresolved_visible_failures':list(pending_failure.values()),'internal_reasoning_steps':None,
            'limitations':['Only delivered tool inputs/outputs and file-state changes are counted.',
                           'New requirements create a new stage and are not classified as repairing an earlier mistake.',
                           'No observed failure means no measurable recovery opportunity; it does not imply a 100% recovery rate.',
                           'Read-before-write is descriptive, not a required workflow or an ability ranking.']}
