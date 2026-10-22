"""Deterministic quality accounting for fallible model observations.

Bindings establish the input/contract being interpreted, not semantic truth.
No network, credential lookup, evidence-path reading, or identity probabilities.
"""
from copy import deepcopy
import math
import re
from urllib.parse import urlsplit, urlunsplit
from .common import digest

SCHEMA = 'tokenclock-assessment-quality/v1'
BINDING_SCHEMA = 'tokenclock-assessment-input-binding/v1'
RELATIONSHIP_SCHEMA = 'tokenclock-assessment-relationship/v1'


def assessment_relationship(target_connection=None, reviewer_connection=None):
    """Controller-only runtime comparison. Never consumes model response fields.

    No endpoint/key text is retained or sent to a reviewer. Paths remain exact;
    a different API path is not guessed to be the same endpoint or supplier.
    """
    def identifiers(connection):
        value=connection if isinstance(connection,dict) else {}
        endpoint=value.get('endpoint');endpoint_id=origin_id=None
        if isinstance(endpoint,str):
            try:
                parsed=urlsplit(endpoint.strip())
                if parsed.scheme in {'http','https'} and parsed.hostname and not (parsed.username or parsed.password or parsed.query or parsed.fragment):
                    host=parsed.hostname.casefold();port=parsed.port
                    if ':' in host:host='['+host+']'
                    authority=host+(':'+str(port) if port is not None and port!={'http':80,'https':443}[parsed.scheme] else '')
                    origin=urlunsplit((parsed.scheme,authority,'','',''))
                    endpoint_id=digest(urlunsplit((parsed.scheme,authority,parsed.path or '/','','')))
                    origin_id=digest(origin)
            except ValueError:pass
        model=value.get('model')
        model_id=digest(model) if isinstance(model,str) and model and not any(ord(c)<32 for c in model) else None
        return {'endpoint_fingerprint':endpoint_id,'origin_fingerprint':origin_id,'model_fingerprint':model_id}
    result={'schema':RELATIONSHIP_SCHEMA,'basis':'controller_runtime_configuration',
            'target':identifiers(target_connection),'reviewer':identifiers(reviewer_connection)}
    return relationship_policy(result)


def relationship_policy(value):
    """Recompute the policy from controller fingerprints; ignore asserted flags."""
    valid=isinstance(value,dict) and value.get('schema')==RELATIONSHIP_SCHEMA and value.get('basis')=='controller_runtime_configuration'
    def fields(name):
        raw=value.get(name,{}) if valid else {}
        return {k:(raw.get(k) if isinstance(raw,dict) and isinstance(raw.get(k),str) and re.fullmatch('[a-f0-9]{64}',raw[k]) else None)
                for k in ('endpoint_fingerprint','origin_fingerprint','model_fingerprint')}
    target,reviewer=fields('target'),fields('reviewer')
    def same(field):return target[field]==reviewer[field] if target[field] and reviewer[field] else None
    endpoint,model,origin=same('endpoint_fingerprint'),same('model_fingerprint'),same('origin_fingerprint')
    relation=('same_endpoint_same_model' if model else 'same_endpoint_different_model') if endpoint is True and model is not None else \
             'different_endpoint_declared_model' if endpoint is False and model is not None else 'unknown'
    return {'schema':RELATIONSHIP_SCHEMA,'basis':'controller_runtime_configuration' if valid else 'unavailable',
            'relation':relation,'same_endpoint':endpoint,'same_declared_model':model,'same_origin':origin,
            'target':target,'reviewer':reviewer,'independent_supplier_established':False,
            'eligible_as_independent_identity_evidence':False,'reference_bank_admission':'explicit_review_required_no_automatic_write',
            'comparison_policy':'descriptive_auxiliary_features_allowed_not_independent_vote',
            'raw_assisted_observations_preserved':True}


def relationship_label(value):
    value=relationship_policy(value)
    return {'same_endpoint_same_model':'同一端点、同一申报型号',
            'same_endpoint_different_model':'同一端点、不同申报型号',
            'different_endpoint_declared_model':'不同端点（供应商独立性未确认）',
            'unknown':'待测与辅助解析连接关系未知'}[value['relation']]


def relationships_from_result(result):
    """Display existing controller metadata; never inspect endpoint/model prose."""
    if not isinstance(result,dict):return []
    values=[]
    direct=result.get('assessment_relationship')
    if isinstance(direct,dict):values.append(direct)
    for name in ('assessment_quality','quality'):
        item=result.get(name,{})
        if isinstance(item,dict):
            if isinstance(item.get('relationship'),dict):values.append(item['relationship'])
            values.extend(r for r in item.get('relationships',[]) if isinstance(r,dict))
    for name in ('reviewer_assessment','visual_assessment','process_assessment','semantic_assessment'):
        item=result.get(name,{})
        if isinstance(item,dict):
            if isinstance(item.get('assessment_relationship'),dict):values.append(item['assessment_relationship'])
            if isinstance(item.get('quality',{}),dict):
                value=item.get('quality',{}).get('relationship')
                if isinstance(value,dict):values.append(value)
    for sample in result.get('samples',[]) if isinstance(result.get('samples'),list) else []:
        if isinstance(sample,dict):values.extend(relationships_from_result({k:sample[k]for k in ('semantic_assessment','assessment_relationship')if k in sample}))
    distinct={digest(relationship_policy(v)):relationship_policy(v) for v in values}
    return list(distinct.values())


def request_binding(request):
    """Hash the exact review view, excluding only controller-only locators/time."""
    value = deepcopy(request)
    for key in ('request_binding', 'cancelled', 'remaining_wall_seconds'):
        value.pop(key, None)
    if isinstance(value.get('images'), list):
        value['images'] = [{k:v for k,v in row.items() if k != 'path'} for row in value['images']]
    contract = {k:value[k] for k in ('schema','task_id','task','task_prompt','prompt_sha256',
                'spec_version','features','response_contract','review_contract') if k in value}
    spec = value.get('spec_version') or value.get('task', {}).get('version') or 'unknown'
    return {'schema': BINDING_SCHEMA, 'input_sha256': digest(value), 'contract_sha256': digest(contract),
            'spec_version': spec,
            'source_sha256': value.get('answer_sha256') or value.get('source_sha256') or value.get('evidence_sha256'),
            'review_view_sha256': value.get('review_text_sha256') or value.get('review_evidence_sha256') or
                                 digest({'images': value.get('images'), 'frames': value.get('frames'), 'inventory': value.get('inventory'), 'view_coverage': value.get('view_coverage')})}


def validate_binding(provided, request):
    expected = request_binding(request)
    if provided is None:
        return {'state':'legacy_contract_unbound', 'claimed':None, 'expected':expected,
                'validated_spec_version':None, 'eligible_for_current_contract':False}
    matched = isinstance(provided, dict) and provided == expected
    return {'state':'bound' if matched else 'mismatch', 'claimed':deepcopy(provided), 'expected':expected,
            'validated_spec_version':expected['spec_version'] if matched else None,
            'eligible_for_current_contract':matched}


def _observations(assessment, lane):
    if lane == 'visual':
        return {x['feature_id']:x for x in assessment.get('observations', []) if isinstance(x,dict) and isinstance(x.get('feature_id'),str)}
    return {k:(v if lane == 'process' and isinstance(v,dict) else {'value':v})
            for k,v in (assessment.get('features') or {}).items()}


def _disjoint(a, b):
    if not isinstance(a,dict) or not isinstance(b,dict):return False
    keys=('x','y','right','bottom')
    if any(type(box.get(k)) not in (int,float) or not math.isfinite(box[k]) for box in (a,b) for k in keys):return False
    if any(box['x']>=box['right'] or box['y']>=box['bottom'] for box in (a,b)):return False
    return a['right']<b['x'] or b['right']<a['x'] or a['bottom']<b['y'] or b['bottom']<a['y']


def local_conflicts(observations, checks, source_sha256):
    """Only contradictions with a sufficient condition, never inverse shortcuts."""
    conflicts=[]
    for check in checks or []:
        if not isinstance(check,dict):continue
        if check.get('id') != 'h04.reflection_in_mirror' or check.get('geometry_roles_origin') != 'prior_sha_bound_review':continue
        if check.get('source_sha256') != source_sha256 or not source_sha256:continue
        observed = check.get('observed') or {}
        if not isinstance(observed,dict):continue
        if observations.get('reflection_relation',{}).get('value') != 'satisfied':continue
        if check.get('metric_status',check.get('status')) != 'fail':continue
        if _disjoint(observed.get('reflection_head_bounds'), observed.get('mirror_bounds')):
            conflicts.append({'feature_id':'reflection_relation','check_id':check['id'],
                'kind':'trusted_reflection_role_completely_outside_mirror_bounds',
                'source_sha256':source_sha256,'local_observation':deepcopy(observed),
                'evidence':deepcopy(check.get('evidence',[])),
                'action':'exclude_semantic_item_from_automatic_comparison_preserve_both_originals',
                'reason':'A source-bound trusted reflection role is wholly outside the source-bound mirror region. The satisfied judgment conflicts with this local relation; no generating-model conclusion follows.'})
    return conflicts


def summarize(assessment, *, lane=None, controller_reviews=None, requested_reviews=None,
              reviewer=None, objective_checks=None, source_sha256=None, relationship=None):
    if not isinstance(assessment,dict):assessment={}
    lane=lane or ('visual' if 'observations' in assessment else 'process' if 'process' in assessment.get('schema','') else 'language')
    if 'assessment' in assessment and isinstance(assessment['assessment'],dict):
        wrapper=assessment;assessment=wrapper['assessment']
        relationship=relationship or wrapper.get('assessment_relationship')
        controller_reviews=controller_reviews if controller_reviews is not None else wrapper.get('reviews')
        reviewer=reviewer or wrapper.get('reviewer')
    observations=_observations(assessment,lane)
    relationship=relationship_policy(relationship or assessment.get('assessment_relationship'))
    unknown_ids=assessment.get('unknowns',assessment.get('unknown_features',[])) or []
    ids=set(observations)|set(unknown_ids)
    disagreements=assessment.get('disagreements',[]) or []
    disputed={r['feature_id'] for r in disagreements if isinstance(r,dict) and isinstance(r.get('feature_id'),str)}
    disputed|={k for k,v in observations.items() if v.get('agreement')=='disagreement'}
    ids|=disputed
    criteria=assessment.get('criteria_ids')
    if isinstance(criteria,list):ids|=set(criteria)
    binding=assessment.get('input_binding') or {'state':'legacy_contract_unbound','eligible_for_current_contract':False}
    current=binding.get('state')=='bound'
    conflicts=deepcopy(assessment.get('local_conflicts',[]))+local_conflicts(observations,objective_checks,source_sha256 or assessment.get('source_sha256'))
    excluded={r['feature_id'] for r in conflicts}
    features={};counts={'criteria':len(ids),'usable':0,'contextual':0,'unknown':0,'no_opportunity':0,'disputed':0,'excluded_by_local_conflict':0}
    for key in sorted(ids):
        row=observations.get(key);value=row.get('value') if row else None
        if key in excluded:state='excluded_local_conflict';counts['excluded_by_local_conflict']+=1
        elif key in disputed:state='disputed';counts['disputed']+=1
        elif row is None or (lane in {'visual','process'} and value=='unknown'):state='unknown';counts['unknown']+=1
        elif lane=='process' and value=='no_opportunity':state='no_opportunity';counts['no_opportunity']+=1
        elif current:state='eligible';counts['usable']+=1
        else:state='contextual_only';counts['contextual']+=1
        features[key]={'automatic_use':state,'raw_value_retained':row is not None or any(c.get('feature_id')==key for c in assessment.get('conflicting_observations',[]))}
    controller_reviews=controller_reviews if isinstance(controller_reviews,list) else assessment.get('controller_reviews',[])
    controller_reviews=controller_reviews if isinstance(controller_reviews,list) else []
    declared=assessment.get('requested_reviews',assessment.get('reviews'))
    requested=requested_reviews if type(requested_reviews)is int else declared if type(declared)is int else len(controller_reviews) or 1
    requested=max(requested,len(controller_reviews))
    received=sum(r.get('response_received',r.get('outcome') in {'parsed','invalid_format','limited'} or r.get('status')=='received') is True for r in controller_reviews if isinstance(r,dict))
    parsed=sum(r.get('outcome')=='parsed' or ('proposal' in r and r.get('status')=='received') for r in controller_reviews if isinstance(r,dict))
    failures=sum(r.get('outcome')=='transport_failed' for r in controller_reviews if isinstance(r,dict))
    limited=sum(r.get('outcome')=='limited' for r in controller_reviews if isinstance(r,dict))
    invalid_format=sum(r.get('outcome')=='invalid_format' for r in controller_reviews if isinstance(r,dict))
    not_started=sum(r.get('outcome')=='not_started' for r in controller_reviews if isinstance(r,dict))
    diagnostics=assessment.get('review_diagnostics',[])
    if lane=='visual':diagnostics=assessment.get('reviews',[]) if isinstance(assessment.get('reviews'),list) else diagnostics
    rejections=[]
    for d in diagnostics:
        if isinstance(d,dict):rejections.extend(d.get('rejected',[]))
    if not diagnostics:rejections.extend(assessment.get('rejected',[]))
    rejections.extend(assessment.get('errors',[]))
    def reason(r):return r.get('reason','') if isinstance(r,dict) else str(r)
    binding_rejections=sum(any(token in reason(r) for token in ('binding','bound','quote','reference','evidence','source')) for r in rejections)
    format_items=sum(any(token in reason(r) for token in ('schema','observation_count','invalid_review_fields','invalid_value','invalid_observation_fields','invalid_scene','non_object')) for r in rejections)
    keys={r.get('reviewer_key') for r in controller_reviews if isinstance(r,dict) and r.get('reviewer_key')}
    opinions=parsed if controller_reviews else sum(bool(d.get('observations')) or bool(d.get('observed')) for d in diagnostics if isinstance(d,dict))
    if not controller_reviews and not diagnostics:opinions=1 if observations else 0
    if opinions==0:independence='no_parsed_opinion'
    elif opinions==1:independence='single_opinion'
    elif len(keys)==1 and controller_reviews:independence='repeated_same_reviewer'
    elif len(keys)>1:independence='different_declared_reviewers_not_statistically_independent'
    else:independence='unknown'
    total_observed=counts['usable']+counts['contextual']+counts['no_opportunity']
    if not total_observed:status='no_usable_observations'
    elif counts['usable']==counts['criteria'] and counts['criteria']>0:status='usable_observations'
    else:status='partial_observations'
    return {'schema':SCHEMA,'status':status,'lane':lane,'coverage':counts,
            'usable_for_automatic_comparison':counts['usable']>0,
            'features':features,'binding':deepcopy(binding),'conflicts':conflicts,
            'relationship':relationship,'independent_identity_evidence':False,
            'reviews':{'requested':requested,'received':received,'parsed':parsed,'limited':limited,'failed':failures,'not_started':not_started,
                'missing':max(0,requested-len(controller_reviews)),'invalid_format':invalid_format,
                'invalid_format_items':format_items,'invalid_binding':binding_rejections,'invalid_binding_items':binding_rejections,'rejected_items':len(rejections),
                'single_opinion':independence=='single_opinion','repeated_same_reviewer':independence=='repeated_same_reviewer',
                'reviewer_independence':independence},
            'descriptive_only':True,'semantic_accuracy_estimated':False,
            'raw_observations_retained':True,'objective_checks_modified':False}


def eligible_features(assessment):
    """Projection gate, with contextual observations retained separately."""
    quality=assessment.get('quality') or summarize(assessment)
    return {k:v for k,v in (assessment.get('features') or {}).items()
            if quality.get('features',{}).get(k,{}).get('automatic_use')=='eligible'}


def aggregate(qualities):
    values=[q for q in qualities if isinstance(q,dict) and q.get('schema')==SCHEMA]
    coverage={k:sum(q.get('coverage',{}).get(k,0) for q in values) for k in
              ('criteria','usable','contextual','unknown','no_opportunity','disputed','excluded_by_local_conflict')}
    reviews={k:sum(q.get('reviews',{}).get(k,0) for q in values) for k in
             ('requested','received','parsed','limited','failed','not_started','missing','invalid_format','invalid_format_items','invalid_binding','invalid_binding_items','rejected_items')}
    reviews.update(single_opinion_assessments=sum(q.get('reviews',{}).get('single_opinion') is True for q in values),
                   repeated_same_reviewer_assessments=sum(q.get('reviews',{}).get('repeated_same_reviewer') is True for q in values))
    relationships={digest(relationship_policy(q.get('relationship'))):relationship_policy(q.get('relationship')) for q in values}
    return {'schema':SCHEMA,'status':'no_usable_observations' if not (coverage['usable']+coverage['contextual']+coverage['no_opportunity']) else
            'usable_observations' if coverage['criteria'] and coverage['usable']==coverage['criteria'] else 'partial_observations',
            'coverage':coverage,'assessment_count':len(values),'usable_for_automatic_comparison':coverage['usable']>0,
            'descriptive_only':True,'semantic_accuracy_estimated':False,
            'reviews':reviews,
            'relationships':list(relationships.values()),'independent_identity_evidence':False,
            'conflicts':[c for q in values for c in q.get('conflicts',[])]}
