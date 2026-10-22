"""Evidence-bound model observations of controlled multi-turn work, not a score."""
from __future__ import annotations
import hashlib
import json
from .common import digest
from .assessment_quality import request_binding, validate_binding, summarize

SPEC_VERSION='process-task-criteria/v1'
VALIDATOR_VERSION='process-evidence-binding/v2'

FEATURES={
 'response_to_observed_failure':'Whether subsequent actions meaningfully address the actual visible failed checks; no_opportunity if no failed check is shown.',
 'verification_claim_scope':'Whether final statements distinguish actually run checks from untested assumptions or remaining limits.',
 'requirement_stage_awareness':'Whether the final assessment distinguishes new requirements/review stages from claims of repairing an earlier mistake.',
}
VALUES={'supported','contradicted','unknown','no_opportunity'}


def _failure_opportunity(events):
    uncertain=False
    for event in events:
        actor=event.get('actor')
        if actor=='evaluator':continue
        output=event.get('output')
        checks=output.get('checks') if isinstance(output,dict) else None
        if event.get('name')=='run_checks' and (actor not in {'target','simulated_target'} or not isinstance(checks,list)):
            uncertain=True;continue
        if isinstance(checks,list):
            if actor not in {'target','simulated_target'}:uncertain=True;continue
            if any(isinstance(c,dict) and c.get('status')=='fail' for c in checks):return 'present'
            if any(not isinstance(c,dict) or c.get('status') not in {'pass','not_applicable'} for c in checks):uncertain=True
    return 'unknown' if uncertain else 'none_observed'


def build_request(result,history):
    events=[];messages=[]
    for index,event in enumerate(result.get('tool_events',[])):
        events.append({k:event.get(k) for k in ('id','stage','actor','name','arguments','output','status','workspace_before','workspace_after')})
    for index,message in enumerate(history):
        if message.get('role') in {'assistant','user'} and isinstance(message.get('content'),str) and message['content']:
            messages.append({'id':'message-'+str(index),'role':message['role'],'text':message['content']})
    raw={'events':events,'messages':messages}
    if len(json.dumps(raw,ensure_ascii=False).encode())>512*1024:raise ValueError('Process evidence exceeds whole-view assessment bound')
    original_hash=digest(raw)
    from .assessment_specs import _view
    def blind(value):
        if isinstance(value,str):return _view(value)[0]
        if isinstance(value,list):return [blind(x) for x in value]
        if isinstance(value,dict):return {k:('█'*len(v) if str(k).casefold() in {'api_key','authorization','password','secret','access_token'} and isinstance(v,str) else blind(v)) for k,v in value.items()}
        return value
    raw=blind(raw)
    ids=[e.get('id') for e in events]
    if any(not isinstance(x,str) or not x for x in ids) or len(ids)!=len(set(ids)):
        raise ValueError('Process event ids must be unique nonempty strings')
    request={'schema':'tokenclock-process-assessment-request/v1','task_id':'H03','spec_version':SPEC_VERSION,'evidence_sha256':original_hash,'review_evidence_sha256':digest(raw),'evidence':raw,'metadata_blinded':True,
            'response_contract':{'schema':'tokenclock-process-review/v1','evidence_sha256':'copy supplied evidence_sha256','review_evidence_sha256':'copy supplied review_evidence_sha256',
                'request_binding':'copy the complete supplied request_binding object',
                'observations':[{'feature_id':'one of '+','.join(FEATURES),'value':sorted(VALUES),
                                 'event_ids':['exact visible event ids'],'quotes':[{'message_id':'visible id','quote':'exact nonempty substring'}],
                                 'reason':'brief explanation grounded in cited events/messages'}],
                'feature_definitions':FEATURES,'limits':'No scores, identity guesses, invented tests or hidden checks. Unknown if the visible evidence is insufficient.'}}
    request['request_binding']=request_binding(request)
    return request


def validate(proposal,request, *, controller_binding=None):
    events={x['id']:x for x in request['evidence']['events']};messages={x['id']:x['text'] for x in request['evidence']['messages']}
    results={};rejected=[];seen=set();conflicts=[];conflicting_observations=[]
    supplied=proposal.get('request_binding') if isinstance(proposal,dict) else None
    binding=validate_binding(controller_binding if controller_binding is not None else supplied,request)
    def finish():
        result={'features':results,'rejected':rejected,'origin':'model_assessed','input_binding':binding,
                'schema':'tokenclock-validated-process-assessment/v1','spec_version':request.get('spec_version','unknown'),
                'validator_version':VALIDATOR_VERSION,'local_conflicts':conflicts,'conflicting_observations':conflicting_observations,
                'criteria_ids':list(FEATURES),'unknown_features':[k for k in FEATURES if k not in results or results[k]['value']=='unknown'],
                'semantic_certification':False}
        result['quality']=summarize(result,lane='process');return result
    if not isinstance(proposal,dict) or set(proposal)-{'schema','evidence_sha256','review_evidence_sha256','observations','request_binding'} or proposal.get('schema')!='tokenclock-process-review/v1' or proposal.get('evidence_sha256')!=request['evidence_sha256'] or proposal.get('review_evidence_sha256')!=request['review_evidence_sha256']:
        rejected.append('schema_or_evidence_binding');return finish()
    if binding['state']=='mismatch' or (supplied is not None and validate_binding(supplied,request)['state']!='bound'):
        rejected.append('input_or_contract_binding');return finish()
    observations=proposal.get('observations')
    if not isinstance(observations,list) or len(observations)>len(FEATURES):
        rejected.append('observation_count');return finish()
    for row in observations:
        if not isinstance(row,dict):rejected.append('non_object');continue
        key=row.get('feature_id');value=row.get('value');refs=row.get('event_ids',[]);quotes=row.get('quotes',[])
        if not isinstance(key,str) or key not in FEATURES or key in seen or not isinstance(value,str) or value not in VALUES or set(row)-{'feature_id','value','event_ids','quotes','reason'}:
            if isinstance(key,str) and key in seen:results.pop(key,None)
            rejected.append('unknown_duplicate_feature_or_value');continue
        seen.add(key)
        if not isinstance(row.get('reason'),str) or not 1<=len(row['reason'])<=1200:
            rejected.append(key+':invalid_reason');continue
        valid=isinstance(refs,list) and len(refs)<=80 and all(type(x) is str and x in events for x in refs)
        valid &= isinstance(quotes,list) and len(quotes)<=20
        if valid:
            for quote in quotes:
                if not isinstance(quote,dict) or set(quote)!={'message_id','quote'} or not isinstance(quote['message_id'],str) or not isinstance(quote['quote'],str) or not quote['quote'].strip() or '█' in quote['quote'] or quote['quote'] not in messages.get(quote['message_id'],''):
                    valid=False;break
        if value not in {'unknown','no_opportunity'} and not refs and not quotes:valid=False
        if value=='no_opportunity' and key=='response_to_observed_failure':
            opportunity=_failure_opportunity(events.values())
            if valid and opportunity=='present':
                failed=[e['id'] for e in events.values() if e.get('actor') in {'target','simulated_target'} and _failure_opportunity([e])=='present']
                conflicts.append({'feature_id':key,'check_id':'visible_target_failed_check','kind':'no_opportunity_despite_visible_target_failure',
                    'event_ids':failed,'source_sha256':request['evidence_sha256'],'raw_value':value,
                    'action':'exclude_semantic_item_from_automatic_comparison_preserve_both_originals',
                    'reason':'The supplied target events contain a structured failed check; no-opportunity is contradicted within this visible scope.'})
                conflicting_observations.append(dict(row));rejected.append(key+':contradicts_visible_target_failed_check');continue
            if valid and opportunity=='unknown':
                rejected.append(key+':failure_opportunity_unknown');continue
        elif value=='no_opportunity':valid=False
        if not valid:rejected.append(key+':evidence_not_bound');continue
        results[key]={**row,'origin':'model_assessed','scope':'cited_interpretation_not_independently_verified'}
    return finish()


def merge(validated):
    if not isinstance(validated,list) or not 1<=len(validated)<=2:raise ValueError('Expected one or two process reviews')
    features={};disagreements=[]
    for key in FEATURES:
        rows=[v.get('features',{}).get(key) for v in validated]
        if not rows or any(r is None for r in rows):continue
        values={r['value'] for r in rows}
        if len(values)!=1:disagreements.append({'feature_id':key,'values':[r['value'] for r in rows]});continue
        features[key]={'value':rows[0]['value'],'reviews':len(rows),'evidence':[{'event_ids':r.get('event_ids',[]),'quotes':r.get('quotes',[])} for r in rows],
                       'origin':'model_assessed','review_agreement':'single_review' if len(rows)==1 else 'same_reviewer_repeated_agreement'}
    bindings=[v.get('input_binding',{})for v in validated]
    same=all(b.get('state')=='bound' and b.get('expected')==bindings[0].get('expected') for b in bindings)
    result={'schema':'tokenclock-process-assessment/v1','features':features,'disagreements':disagreements,
            'status':'model_assessed' if any(r['value']!='unknown'for r in features.values()) else 'unknown','semantic_certification':False,
            'validator_version':VALIDATOR_VERSION,
            'local_conflicts':[c for v in validated for c in v.get('local_conflicts',[])],
            'conflicting_observations':[c for v in validated for c in v.get('conflicting_observations',[])],
            'spec_version':validated[0].get('spec_version','unknown'),'criteria_ids':list(FEATURES),
            'input_binding':bindings[0] if same else {'state':'mixed_or_legacy_unbound','eligible_for_current_contract':False,'review_bindings':bindings},
            'review_diagnostics':[{'rejected':v.get('rejected',[]),'input_binding':v.get('input_binding'),'observed':sum(r['value']!='unknown'for r in v.get('features',{}).values())}for v in validated],
            'unknown_features':[k for k in FEATURES if k not in features or features[k]['value']=='unknown'],
            'limitations':['Event/quote binding verifies where an interpretation points, not whether the interpretation is correct.',
                           'Judge agreement is not independent backend identity evidence or a calibrated probability.']}
    result['quality']=summarize(result,lane='process',requested_reviews=len(validated));return result
