"""Versioned language observation contracts, source binding and safe projection."""
from __future__ import annotations
import copy
import hashlib
from importlib.resources import files
import json
import math
import re
from .catalog import get_task
from .common import digest
from .assessment_quality import request_binding, validate_binding, summarize, eligible_features

SCHEMA='tokenclock-language-proposal/v1'
BINDING_VERSION='exact-quote-binding/v2'
MODEL_RE=re.compile(r'(?i)(?<!\w)(?:gpt-\d[\w.\-]*|claude-(?:opus|sonnet|fable)-[\w.\-]+|(?:opus|sonnet|fable|astra)\s*[56](?:\.\d+)?)(?!\w)')
SECRET_RE=re.compile(r"(?i)sk-(?:or-v\d+-)?[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._-]{8,}|[\"']?(?:api[ _-]?key|access[ _-]?token|password|secret|authorization)[\"']?\s*[:=：]\s*[^\r\n,}]+")


def load_spec(task_id):
    book=json.loads(files(__package__).joinpath('resources/assessment-specs.json').read_text())
    spec=next((x for x in book['tasks'] if x['task_id']==task_id),None)
    if spec is None:raise ValueError('Unknown assessment task')
    if spec['prompt_sha256']!=get_task(task_id)['prompt_sha256']:raise ValueError('Assessment prompt contract changed')
    return copy.deepcopy(spec)


def _view(answer):
    if not isinstance(answer,str) or len(answer)>262144:raise ValueError('Whole-answer assessment view exceeds 262144 codepoints')
    spans=[]
    for regex in (MODEL_RE,SECRET_RE):
        for m in regex.finditer(answer):spans.append((m.start(),m.end()))
    chars=list(answer)
    for start,end in spans:
        for i in range(start,end):
            if chars[i] not in '\r\n':chars[i]='█'
    return ''.join(chars),spans


def build_request(task_id,answer):
    spec=load_spec(task_id);view,spans=_view(answer)
    features=[{k:v for k,v in f.items() if k not in {'reference_projection'}} for f in spec['features']]
    result={'schema':'tokenclock-language-assessment-request/v1','task_id':task_id,'task_prompt':get_task(task_id)['prompt'],
            'prompt_sha256':spec['prompt_sha256'],'spec_version':spec['version'],
            'answer_sha256':hashlib.sha256(answer.encode()).hexdigest(),'review_text_sha256':hashlib.sha256(view.encode()).hexdigest(),
            'answer':view,'complete_answer_view':True,'features':features,
            'response_contract':{'schema':SCHEMA,'task_id':task_id,'prompt_sha256':'copy supplied prompt_sha256',
                'answer_sha256':'copy supplied answer_sha256','review_text_sha256':'copy supplied review_text_sha256',
                'spec_version':spec['version'],'request_binding':'copy the complete supplied request_binding object','observations':[{'feature_id':'one declared feature id','status':'observed or unknown','value':'typed value allowed by this feature; null for unknown',
                    'evidence':[{'start':'0-based Unicode codepoint offset','end':'exclusive codepoint offset','quote':'exact substring from supplied answer','role':'asserted|conditional|quoted|negated|example'}],
                    'whole_answer_reviewed':'boolean, required for absence and exhaustive counts/collections','reason':'short interpretation; not model identity or confidence'}]},
            'citation_instructions': ['Copy quote character-for-character from the supplied answer, preserving punctuation and spaces.',
                'start/end are Unicode codepoint indices, not bytes or UTF-16 units. Prefer accurate offsets; the client may relocate an exact quote only when it occurs once in the whole supplied answer.',
                'Do not shorten an ambiguous quote to evade source binding; include enough original context to identify the intended occurrence.'],
            'privacy':{'target_metadata_supplied':False,'reference_answers_supplied':False,'reference_distributions_supplied':False,
                       'same_length_redacted_spans':len(spans),'offset_unit':'unicode_codepoints'}}
    result['request_binding']=request_binding(result)
    return result


def _valid_value(value,feature):
    typ=feature['type'];allowed=feature.get('allowed_values',[])
    if typ=='boolean':return type(value) is bool
    if typ=='integer':return type(value) is int and feature.get('minimum',0)<=value<=feature.get('maximum',1000)
    if typ=='number':return type(value) in {int,float} and math.isfinite(value) and abs(value)<=1e12
    if typ=='enum':return any(type(value) is type(v) and value==v for v in allowed)
    if not isinstance(value,list) or len(value)>100:return False
    if typ=='enum_array':return all(any(type(x) is type(v) and x==v for v in allowed) for x in value) and len({digest(x) for x in value})==len(value)
    if typ=='integer_array':return all(type(x) is int and -1e9<=x<=1e9 for x in value)
    if typ=='string_array':return all(isinstance(x,str) and 0<len(x)<=200 for x in value)
    return False


def validate_proposal(task_id,answer,proposal, *, controller_binding=None):
    request=build_request(task_id,answer);spec=load_spec(task_id);definitions={f['id']:f for f in spec['features']}
    result={'schema':'tokenclock-validated-language-assessment/v1','task_id':task_id,'spec_version':spec['version'],
            'answer_sha256':request['answer_sha256'],'status':'model_assessed','features':{},'evidence':{},'unknowns':[],
            'rejected':[],'origin':'model_assessed','semantic_certification':False}
    result['binding_policy_version']=BINDING_VERSION
    result['validator_version']='language-contract-and-evidence/v3'
    result['criteria_ids']=list(definitions)
    supplied=proposal.get('request_binding') if isinstance(proposal,dict) else None
    result['input_binding']=validate_binding(controller_binding if controller_binding is not None else supplied,request)
    def finish():
        result['coverage']={'observed':len(result['features']),'total':len(definitions),'semantic_verification':'citation_binding_only',
            'relocated_citations':sum(c['binding_method']=='unique_exact_quote_relocated' for cs in result['evidence'].values() for c in cs)}
        result['quality']=summarize(result,lane='language')
        return result
    fields={'schema','task_id','prompt_sha256','answer_sha256','review_text_sha256','spec_version','observations','request_binding'}
    expected={k:request[k] for k in ('task_id','prompt_sha256','answer_sha256','review_text_sha256','spec_version')};expected['schema']=SCHEMA
    if not isinstance(proposal,dict) or set(proposal)-fields or any(proposal.get(k)!=v for k,v in expected.items()):
        result['rejected'].append('schema_or_source_binding');result['unknowns']=list(definitions);return finish()
    if result['input_binding']['state']=='mismatch' or (supplied is not None and validate_binding(supplied,request)['state']!='bound'):
        result['rejected'].append('input_or_contract_binding');result['unknowns']=list(definitions);return finish()
    rows=proposal.get('observations')
    if not isinstance(rows,list) or len(rows)>len(definitions):
        result['rejected'].append('observation_count');result['unknowns']=list(definitions);return finish()
    seen=set();view=request['answer']
    for row in rows:
        if not isinstance(row,dict):result['rejected'].append('non_object');continue
        key=row.get('feature_id')
        if not isinstance(key,str) or key not in definitions or key in seen or set(row)-{'feature_id','status','value','evidence','whole_answer_reviewed','reason'}:
            if isinstance(key,str) and key in seen:result['features'].pop(key,None);result['evidence'].pop(key,None)
            result['rejected'].append('unknown_duplicate_or_extra_fields');continue
        seen.add(key);feature=definitions[key];value=row.get('value')
        if row.get('status')=='unknown':continue
        if row.get('status')!='observed' or not _valid_value(value,feature):result['rejected'].append(key+':invalid_value');continue
        citations=row.get('evidence',[]);valid=isinstance(citations,list) and len(citations)<=100;bound=[]
        if valid:
            for citation in citations:
                if not isinstance(citation,dict) or set(citation)!={'start','end','quote','role'}:valid=False;break
                start,end=citation['start'],citation['end'];quote=citation['quote'];role=citation['role']
                if type(start) is not int or type(end) is not int or not isinstance(quote,str) or not quote or not isinstance(role,str) or role not in {'asserted','conditional','quoted','negated','example'}:valid=False;break
                if '█' in quote:valid=False;break # masked identity/credentials are not semantic evidence
                supplied={'start':start,'end':end}
                method='supplied_exact_offsets'
                if not 0<=start<end<=len(view) or quote!=view[start:end]:
                    found=view.find(quote)
                    if found<0 or view.find(quote,found+1)>=0:valid=False;break
                    start,end=found,found+len(quote);method='unique_exact_quote_relocated'
                bound.append({**citation,'start':start,'end':end,'original_quote':answer[start:end],
                              'supplied_offsets':supplied,'binding_method':method,'quote_text_modified':False})
        if not valid:result['rejected'].append(key+':unbound_quote');continue
        absent=(value is False or value is None or value==0 or value==[] or (isinstance(value,str) and value in {'UNCLASSIFIED','no_choice','none','silent'}))
        policy=feature.get('evidence_policy',{})
        complete=row.get('whole_answer_reviewed') is True
        if (absent or feature['type'] in {'integer','integer_array','string_array','enum_array'} or policy.get('complete_collection_review_required')) and not complete:
            result['rejected'].append(key+':whole_answer_review_required');continue
        if not absent and not bound:result['rejected'].append(key+':positive_evidence_required');continue
        if policy.get('stance')=='primary_choice' and not absent and not any(c['role']=='asserted' for c in bound):
            result['rejected'].append(key+':no_asserted_primary_choice');continue
        result['features'][key]=value;result['evidence'][key]=bound
    result['unknowns']=[k for k in definitions if k not in result['features']]
    return finish()


def merge_proposals(proposals):
    if not isinstance(proposals,list) or not 1<=len(proposals)<=2:raise ValueError('Expected one or two independent proposal slots')
    first=proposals[0];result={k:first[k] for k in ('schema','task_id','spec_version','answer_sha256','origin','semantic_certification')}
    result.update(features={},evidence={},disagreements=[],rejected=[],status='model_assessed',reviews=len(proposals))
    spec=load_spec(result['task_id'])
    bindings=[p.get('input_binding',{}) for p in proposals]
    result['input_binding']=copy.deepcopy(bindings[0])
    if any(b.get('state')!='bound' or b.get('expected')!=bindings[0].get('expected') for b in bindings):
        result['input_binding']={'state':'mixed_or_legacy_unbound','eligible_for_current_contract':False,
                                 'review_bindings':copy.deepcopy(bindings)}
    result['criteria_ids']=[f['id'] for f in spec['features']]
    result['review_diagnostics']=[{'rejected':p.get('rejected',[]),'input_binding':p.get('input_binding'),'observed':len(p.get('features',{}))}for p in proposals]
    for p in proposals:
        if any(p.get(k)!=result[k] for k in ('task_id','spec_version','answer_sha256')):raise ValueError('Cannot merge different answer/spec assessments')
        result['rejected'].extend(p.get('rejected',[]))
    for feature in spec['features']:
        key=feature['id'];values=[p.get('features',{}).get(key,'__UNKNOWN__') for p in proposals]
        if any(v=='__UNKNOWN__' for v in values):continue
        if len({digest(v) for v in values})!=1:
            result['disagreements'].append({'feature_id':key,'values':values});continue
        result['features'][key]=values[0];result['evidence'][key]=[c for p in proposals for c in p.get('evidence',{}).get(key,[])]
    result['unknowns']=[f['id'] for f in spec['features'] if f['id'] not in result['features']]
    result['review_agreement']='single_review' if len(proposals)==1 else 'same_reviewer_repeated_agreement_where_values_match'
    result['status']='model_assessed' if result['features'] else 'unknown'
    result['quality']=summarize(result,lane='language',requested_reviews=len(proposals))
    return result


def project_features(validated):
    spec=load_spec(validated['task_id']);reference={'claude-base':{},'four-model-extension':{}};unmapped=[]
    values=eligible_features(validated)
    for feature in spec['features']:
        key=feature['id']
        if key not in values:continue
        mappings=feature.get('reference_projection',{})
        if not mappings:unmapped.append(key)
        for origin,mapping in mappings.items():
            value=values[key];transform=mapping.get('transform')
            if mapping.get('verified',True) is not True:unmapped.append(key+':'+origin);continue
            if transform=='bool_yes_no':value='yes' if value else 'no'
            elif transform=='singleton':value=[value]
            elif transform!='identity':raise ValueError('Unknown projection transform')
            reference.setdefault(origin,{})[mapping['field']]=value
    # Same feature definitions already used in the deterministic extraction.
    if 'capacity_caveat' in values and 'staleness_caveat' in values:
        reference['four-model-extension']['capacity_or_staleness_caveat']=values['capacity_caveat'] or values['staleness_caveat']
        reference['claude-base']['caveats']='yes' if values['capacity_caveat'] or values['staleness_caveat'] else 'no'
    return {'features':copy.deepcopy(values),'reference_features':reference,'unmapped':sorted(set(unmapped)),
            'origin':'model_assessed','spec_version':validated['spec_version'],'coverage':{'observed':len(values),'total':len(spec['features'])},
            'raw_features_retained':copy.deepcopy(validated.get('features',{})),
            'automatic_projection_gated_by_quality':True,'input_binding':copy.deepcopy(validated.get('input_binding',{})),
            'limits':['Projection preserves observation definitions; citation validity does not verify semantics.']}
