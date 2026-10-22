"""Versioned descriptive fingerprints with equal panels and honest missingness.

All comparison is local. Sample hashes identify observations, never backend
weights. Shared task families remain shared evidence, not independent votes.
"""
from __future__ import annotations
from collections import Counter, defaultdict
from copy import deepcopy
from .assessment_quality import relationship_policy
from importlib.resources import files
import hashlib
import json
import math
import re

SCHEMA = 'tokenclock-fingerprint-reference/v1'
DIMENSIONS = ('behavior', 'capability_delivery', 'process', 'resources')
UNKNOWN = {'state': 'unknown'}
NULLABLE_DESCRIPTOR_FIELDS = {'explicit_final_recommendation', 'selected_label'}
RESOURCE_BINS = (0, 16, 64, 256, 1024, 4096, 8192, 16384, 32768, 65536, 262144, 1048576, 10**12)


def stable_hash(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def _resource_bytes(name):
    return files('scripts.model_integrity.probes').joinpath('resources', name).read_bytes()


def measurement_contract(task_id, variant=None):
    """Public measurement definitions, independent of UI/judge plumbing edits."""
    task = str(task_id)
    if re.fullmatch(r'[NCO]\d\d:[AB]', task):
        definition = {'type': 'bounded_short_answer_descriptors', 'version': 1,
                      'first_strategy': 'first concrete Python function; presentation-order strategy is separately named',
                      'optional_expansion': 'explicit clauses with local negation/conditional scope',
                      'neutral_choice': 'explicit primary choice; no-choice is behavioral noncompliance',
                      'resources': 'Unicode codepoint answer length; native reported tokens retain schema'}
        grader = 'bounded-short-features-v1'; version = 'short-behavior-bank-v1'
    elif task == 'H01':
        definition = {'type': 'integer_cent_settlement', 'cases_sha256': hashlib.sha256(_resource_bytes('h01_cases.json')).hexdigest(),
                      'minimum': 'zero-sum partition optimum; valid remainder allocations allowed', 'checks': 'format/net/minimum/reported-net separate'}
        grader = 'h01-settlement-v2'; version = 'OA04-v1'
    elif task == 'H02':
        definition = {'type': 'three-step-form', 'version': 1, 'checks': ['actual-entry', 'backward-retention', 'forward-retention', 'restart-persistence', 'completion-feedback'],
                      'execution': 'observed controls, stable disposable HTTP origin, no injected storage'}
        grader = 'h02-interaction-v2'; version = 'OA01-v1'
    elif task.startswith('H03'):
        actual = variant or ('ledger' if task.endswith(':ledger') else 'pipeline')
        definition = {'type': 'shared-pipeline' if actual == 'pipeline' else 'staged-ledger', 'version': 2 if actual == 'pipeline' else 1,
                      'determinism': 'same input repeated; input permutation is observational only'}
        if actual == 'pipeline': definition['task_sha256'] = json.loads(_resource_bytes('h03_pipeline.json'))['contract_sha256']
        grader = 'h03-pipeline-v2' if actual == 'pipeline' else 'h03-ledger-v1'; version = actual + '-v1'
    elif task.startswith('H04'):
        actual = variant or ('ascii' if task.endswith(':ascii') else 'svg')
        if actual not in {'ascii', 'svg'}: actual = 'ascii' if actual == 'OA12' else 'svg'
        definition = {'type': actual, 'version': 1, 'role_basis': 'prior hash-bound annotation or explicitly conditional role map; model assessment remains separate',
                      'checks': ['tie contact', 'reflection inside mirror', 'reflection correspondence'] if actual == 'svg' else ['frame structure', 'identity', 'uphill motion', 'contact and support']}
        grader = 'h04-' + actual + '-geometry-v1'; version = 'OA12-v1' if actual == 'ascii' else 'OA11-v1'
    else:
        return {'task_version': 'unknown', 'grader_version': 'unknown', 'definition_sha256': None}
    return {'task_version': version, 'grader_version': grader, 'definition_sha256': stable_hash(definition)}


def _task_key(task, variant=None):
    if task == 'H03': return 'H03:' + (variant or 'pipeline')
    if task == 'H04': return 'H04:' + ('ascii' if variant in {'ascii', 'OA12'} else 'svg')
    return str(task)


def _family(task):
    return {'H01': 'OA04', 'H02': 'OA01', 'H04:svg': 'OA11', 'H04:ascii': 'OA12'}.get(task, task.split(':')[0])


def _known(value, name=None):
    if value is None:return name in NULLABLE_DESCRIPTOR_FIELDS
    return value != 'UNKNOWN' and not (isinstance(value, dict) and value.get('state') in {'unknown', 'not_applicable', 'conflict'})


def encoded_value(name, value, dimension):
    if dimension == 'resources' and type(value) in {int, float} and math.isfinite(value) and value >= 0:
        for left, right in zip(RESOURCE_BINS, RESOURCE_BINS[1:]):
            if left <= value < right: return stable_hash({'fixed_bin': [left, right]})
        return stable_hash({'fixed_bin': 'overflow'})
    return stable_hash(value)


def _identity(sample, answer_hash=None):
    record = sample.get('record', {}) or {}
    supplied = record.get('original_sample_sha256') or sample.get('original_sample_sha256')
    if isinstance(supplied, str) and re.fullmatch(r'[a-f0-9]{64}', supplied): return supplied, 'declared_original_sample_hash'
    response_id = record.get('provider_response_id') or record.get('response_id')
    request_hash = record.get('request_sha256') or sample.get('prompt_sha256')
    if response_id:
        return stable_hash({'response_id': response_id, 'request_hash': request_hash, 'answer_hash': answer_hash}), 'response_and_request_bound'
    if record.get('transport_mode') == 'live' and record.get('client_request_id'):
        return stable_hash({'client_request_id': record['client_request_id'], 'request_hash': request_hash, 'answer_hash': answer_hash}), 'controller_request_bound'
    return answer_hash or stable_hash(sample), 'content_fallback_may_merge_independent_identical_outputs'


def _usage_feature(record):
    usage = record.get('usage')
    if not isinstance(usage, dict): return {}, {}
    output = usage.get('output_tokens', usage.get('completion_tokens'))
    if type(output) is not int or output < 0: return {}, {}
    fmt = record.get('api_format')
    if not fmt:
        fmt = 'chat_completions' if 'completion_tokens' in usage else 'messages' if 'cache_read_input_tokens' in usage else 'responses' if 'output_tokens_details' in usage else 'unknown'
    return {'reported_output_tokens': output}, {'usage_schema': fmt, 'resource_scope': 'provider_reported_output_tokens_not_internal_reasoning_steps'}


def observations_from_result(report_or_result):
    """Read only passed result data, never filenames or source.refs."""
    observations, warnings = [], []
    seen_containers = set()
    def assessment_meta(assessment, base, inherited=None):
        assessment=assessment if isinstance(assessment,dict) else {}
        relation=relationship_policy(assessment.get('assessment_relationship') or (assessment.get('quality') or {}).get('relationship') or inherited)
        return {'assessment_relationship':relation,'source_evidence_group':stable_hash([base.get('subject_id'),base['sample_hash'],base['task_family']]),
                'no_additional_independent_vote':True,'eligible_as_independent_identity_evidence':False,
                'reference_bank_admission':'explicit_review_required_no_automatic_write'}
    def subject_for(item,inherited=None):
        declared=item.get('subject')
        if isinstance(declared,dict) and isinstance(declared.get('id'),str) and declared['id']:
            return {'id':declared['id'],'label':declared.get('label','已声明输入组'),'scope':declared.get('scope','declared_unverified')}
        if item.get('subject_id'):
            return {'id':str(item['subject_id']),'label':item.get('subject_label','已声明输入组'),'scope':'declared_unverified'}
        if inherited:return inherited
        identity=stable_hash({k:v for k,v in item.items() if k not in {'fingerprint','fingerprints'}})
        return {'id':stable_hash({'unbound_input_group':identity}),'label':'未绑定来源的独立输入组','scope':'unbound_report_group'}

    def visit(item, depth=0,inherited_subject=None):
        if not isinstance(item, dict) or depth > 6: return
        if id(item) in seen_containers:
            warnings.append('Repeated/cyclic report container ignored'); return
        seen_containers.add(id(item))
        subject=subject_for(item,inherited_subject)
        if isinstance(item.get('result'), dict): visit(item['result'], depth+1,subject); return
        if isinstance(item.get('components'), list):
            for component in item['components']: visit(component.get('report'), depth+1,None)
            return
        sample_rows=item.get('samples', []) if isinstance(item.get('samples'), list) else []
        import_namespace=stable_hash([{'task_id':s.get('task_id'),'answer':s.get('answer'),'prompt_sha256':s.get('prompt_sha256'),
                                       'conditions':s.get('metadata',{}).get('conditions',s.get('conditions'))} for s in sample_rows if isinstance(s,dict)]) if sample_rows else None
        for ordinal,sample in enumerate(sample_rows):
            if not isinstance(sample, dict): continue
            extracted = sample.get('extracted', {}) or {}
            current_subject=subject_for(sample,subject)
            if not sample.get('subject') and not sample.get('subject_id') and subject['scope']=='unbound_report_group':
                requested=(sample.get('record') or {}).get('requested_model')
                if requested:current_subject={'id':stable_hash({'input_group':subject['id'],'requested_model':requested}),
                                              'label':str(requested),'scope':'declared_model_within_unbound_input_group'}
            task = sample.get('task_id', extracted.get('task_id', 'unknown'))
            answer = sample.get('answer')
            content_hash = extracted.get('answer_sha256') or (hashlib.sha256(answer.encode()).hexdigest() if isinstance(answer, str) else None)
            identity, identity_kind = _identity(sample, content_hash)
            if identity_kind.startswith('content_fallback'):
                identity=stable_hash({'answer_set':import_namespace,'sample_position':ordinal,'content_hash':content_hash})
                identity_kind='declared_sample_position_without_original_call_identity'
            meta = sample.get('metadata', {}) or {}
            contract = sample.get('measurement_contract') or extracted.get('measurement_contract') or measurement_contract(task)
            base = {'bank': 'behavior', 'task_id': task, 'task_family': _family(task), 'sample_hash': identity,
                    'subject_id':current_subject['id'],'subject_label':current_subject['label'],'subject_scope':current_subject['scope'],
                    'content_sha256': content_hash, 'identity_kind': identity_kind, 'measurement_contract': contract,
                    'conditions': dict(meta.get('conditions') or {}), 'source_scope': meta.get('source_scope', item.get('source_scope', 'unknown')),
                    'origin': 'deterministic_extractor', 'status': extracted.get('status', sample.get('status', 'unknown'))}
            if base['source_scope'] == 'scripted_demo': base['origin'] = 'scripted_demo'
            features = deepcopy(extracted.get('features', {}))
            assessment = sample.get('semantic_assessment') or sample.get('assessment') or extracted.get('assessment')
            if isinstance(assessment,dict) and isinstance(answer,str):
                # Current orchestration may fill unknown local fields from a
                # judge. Recompute the bounded local projection rather than
                # relabel model-assessed additions as deterministic evidence.
                from .features import extract
                try:features=extract(task,answer,meta).get('features',{})
                except ValueError:features={}
            if not isinstance(features, dict): features = {}
            if base['status'] in {'failed', 'truncated', 'cancelled','incomplete','limited'} or meta.get('completed') is False: features = {}
            features.pop('extraction_category', None)
            observations.append({**base, 'dimension': 'behavior', 'features': features})
            if isinstance(answer, str) and base['status'] not in {'failed', 'cancelled'}:
                observations.append({**base, 'dimension': 'resources', 'features': {'visible_answer_characters': len(answer)},
                                     'conditions': {**base['conditions'], 'resource_scope': 'visible_unicode_characters'}})
            values, usage_conditions = _usage_feature(sample.get('record', {}) or {})
            if values: observations.append({**base, 'dimension': 'resources', 'features': values, 'conditions': {**base['conditions'], **usage_conditions}})
            if isinstance(assessment, dict) and meta.get('completed') is not False and base['status'] not in {'failed','truncated','cancelled','incomplete','limited'}:
                projection=assessment.get('projection',assessment)
                proposed = projection.get('features', projection.get('projected_features', {}))
                if isinstance(proposed, list): proposed = {r.get('id', r.get('feature_id')): r.get('value', UNKNOWN) for r in proposed if isinstance(r, dict)}
                if isinstance(proposed, dict):
                    observations.append({**base, 'dimension': 'behavior', 'origin': 'model_assessed', 'features': proposed,
                                         **assessment_meta(assessment,base,item.get('assessment_relationship')),
                                         'assessment_version': projection.get('spec_version', assessment.get('version', 'unknown'))})
        if isinstance(item.get('checks'), list) and item.get('task_id'):
            task = _task_key(item['task_id'], item.get('variant'))
            source = item.get('source', {}) or {}
            content_hash = source.get('sha256') or source.get('workspace_sha256')
            identity = source.get('original_sample_sha256') or content_hash or stable_hash(item['checks'])
            context = item.get('measurement_context', {}) or {}
            contract = item.get('measurement_contract') or {'task_version': 'unknown', 'grader_version': 'unknown', 'definition_sha256': None}
            conditions = dict(context.get('generation_conditions', item.get('generation', {}).get('conditions', {})) or {})
            base = {'bank': 'heavy', 'task_id': task, 'task_family': _family(task), 'sample_hash': identity,
                    'subject_id':subject['id'],'subject_label':subject['label'],'subject_scope':subject['scope'],
                    'content_sha256': content_hash, 'identity_kind': 'original_artifact_hash', 'measurement_contract': contract,
                    'conditions': conditions, 'source_scope': source.get('kind', 'unknown'), 'origin': 'deterministic_grader', 'status': item.get('status')}
            descriptors = {}
            for check in item['checks']+item.get('model_assessed_checks',[]):
                if not isinstance(check, dict): continue
                identifier = str(check.get('id', ''))
                dim = str(check.get('dimension', '')).casefold()
                if dim in {'来源声明', 'provenance'} or dim.startswith('source') or identifier.startswith(('source_', 'source.')): continue
                origin = check.get('origin', '')
                # Uncertified conditional geometry is still measured geometry;
                # that flag alone is not evidence that a model was a judge.
                if identifier.startswith('h04.assessed.') or origin == 'model_assessed':
                    observations.append({**base, 'origin': 'model_assessed', 'dimension': 'capability_delivery',
                                         **assessment_meta(item.get('visual_assessment'),base,item.get('assessment_relationship')),
                                         'features': {identifier: check.get('status') if check.get('status') in {'pass','fail'} else UNKNOWN}}); continue
                state = check.get('status')
                descriptors['check:' + identifier] = state if state in {'pass', 'fail'} else {'state': state if state in {'unknown', 'not_applicable'} else 'unknown'}
            known_fails = any(v == 'fail' for v in descriptors.values())
            all_known = bool(descriptors) and all(_known(v) for v in descriptors.values())
            descriptors['observed_check_failure_present'] = True if known_fails else False if all_known else UNKNOWN
            observations.append({**base, 'dimension': 'capability_delivery', 'features': descriptors})
            chars = context.get('answer_characters')
            if type(chars) is int and chars >= 0:
                observations.append({**base, 'dimension': 'resources', 'features': {'visible_answer_characters': chars},
                                     'conditions': {**conditions, 'resource_scope': 'visible_unicode_characters'}})
            generation = item.get('generation', {}).get('record', {})
            values, usage_conditions = _usage_feature(generation)
            if values: observations.append({**base, 'dimension': 'resources', 'features': values, 'conditions': {**conditions, **usage_conditions}})
            # Evaluator wall time and evaluator actions are deliberately absent.
            if item.get('process_assessment'):
                assessment = item['process_assessment']
                values = assessment.get('automatic_features', {}) if isinstance(assessment,dict) and assessment.get('quality') else assessment.get('features', {}) if isinstance(assessment,dict) else {}
                if isinstance(values, list): values = {x.get('id', x.get('feature_id', str(i))): x.get('value', UNKNOWN) for i, x in enumerate(values) if isinstance(x, dict)}
                observations.append({**base, 'dimension': 'process', 'origin': 'model_assessed', 'features': values if isinstance(values, dict) else {},
                                     **assessment_meta(assessment,base,item.get('assessment_relationship')),
                                     'measurement_contract': {'task_version': contract.get('task_version'), 'grader_version': 'process_assessment_unregistered', 'definition_sha256': None}})
        # Process references use target-issued tool observations only. Final
        # evaluator checks and their CPU/browser activity never become process.
        from .process_reference import profile_from_h03, fingerprint_observation
        process_profile=item.get('process_profile') or profile_from_h03(item)
        process_row=fingerprint_observation(process_profile,subject)
        if process_row is not None:observations.append(process_row)
        if not item.get('task_id') and item.get('facts') and not process_row:
            values = {f.get('code', str(i)): f.get('value', UNKNOWN) for i, f in enumerate(item['facts']) if isinstance(f, dict) and str(f.get('code', '')).startswith(('process.', 'semantic.'))}
            if values: observations.append({'bank': 'natural_session', 'task_id': 'unmatched-session', 'task_family': 'unmatched-session',
                                           'subject_id':subject['id'],'subject_label':subject['label'],'subject_scope':subject['scope'],
                                           'sample_hash': stable_hash(values), 'content_sha256': None, 'identity_kind': 'unmatched_session_facts',
                                           'dimension': 'process', 'origin': 'unregistered_session_observation', 'measurement_contract': {}, 'conditions': {}, 'features': values})
    visit(report_or_result)
    return observations, warnings


def aggregate_reference(observations, *, banks=None, source_audit=None, allow_model_assessed=False):
    """Builder helper: aggregate values, never store private answer text."""
    cells = defaultdict(dict)
    candidates=list(observations)
    observations=[o for o in candidates if o.get('origin')!='model_assessed' or allow_model_assessed is True]
    for observation in observations:
        key = stable_hash({k: observation.get(k) for k in ('bank', 'task_id', 'model_label', 'dimension', 'measurement_contract', 'conditions', 'origin')})
        sample = observation['sample_hash']
        if sample not in cells[key]:cells[key][sample]=deepcopy(observation)
        else:
            prior=cells[key][sample]['features']
            for name,value in observation.get('features',{}).items():
                if name in prior and prior[name]!=value:prior[name]={'state':'conflict'}
                else:prior[name]=value
    aggregated = []
    for key, by_sample in sorted(cells.items()):
        rows=list(by_sample.values())
        first = rows[0]
        names = sorted({k for row in rows for k in row.get('features', {})})
        descriptors = {}
        for name in names:
            known = [row['features'][name] for row in rows if name in row.get('features', {}) and _known(row['features'][name],name)]
            descriptors[name] = {'counts': dict(Counter(encoded_value(name, value, first['dimension']) for value in known)),
                                 'known_n': len(known), 'unknown_or_missing_n': len(rows) - len(known),
                                 'encoding': 'fixed_resource_bins_v1' if first['dimension'] == 'resources' else 'canonical_json_sha256'}
        aggregated.append({**{k: first.get(k) for k in ('bank', 'task_id', 'task_family', 'model_label', 'dimension', 'measurement_contract', 'conditions', 'origin')},
                           'id': key, 'n': len(rows), 'sample_hashes': sorted(by_sample),
                           'content_hashes': sorted({r['content_sha256'] for r in rows if r.get('content_sha256')}), 'descriptors': descriptors})
    return {'schema': SCHEMA, 'version': 'fingerprint-reference-v1', 'model_labels': sorted({r['model_label'] for r in observations}),
            'cells': aggregated, 'banks': banks or {}, 'source_audit': source_audit or {},
            'reference_admission':{'model_assessed_explicitly_allowed':allow_model_assessed is True,
                                   'model_assessed_rows_omitted':len(candidates)-len(observations),'automatic_runtime_update':False},
            'resource_bins': list(RESOURCE_BINS), 'identity_probability': None, 'mixture_proportion': None,
            'limits': ['Only aggregates, definitions and hashes are bundled.', 'Historical labels are source declarations, not authenticated weights.',
                       'Banks and repeated measurements do not add to a single model-sample N.', 'Calibration/replay on reference samples is not independent identification accuracy.']}


def _contract_notes(current, prior):
    notes = []
    for key in ('task_version', 'grader_version', 'definition_sha256'):
        if current.get(key) is None or current.get(key) == 'unknown': notes.append({'field': key, 'state': 'missing'})
        elif current.get(key) != prior.get(key): notes.append({'field': key, 'state': 'different'})
    return notes


def _tv(left, right):
    n, m = sum(left.values()), sum(right.values())
    return sum(abs(left.get(k, 0)/n - right.get(k, 0)/m) for k in set(left)|set(right))/2 if n and m else None


def _distance_bounds(left,right,left_total,right_total):
    base=sum(abs(left.get(k,0)/left_total-right.get(k,0)/right_total) for k in set(left)|set(right))/2
    missing=(1-sum(left.values())/left_total)+(1-sum(right.values())/right_total)
    return [max(0,base-missing/2),min(1,base+missing/2)]


def compare(report_or_result, reference=None):
    if reference is None:
        from .reference_release import reference as load_reference
        reference = load_reference('fingerprint')
        from .process_reference import merge_reference
        reference = merge_reference(reference)
    if reference.get('schema') != SCHEMA: raise ValueError('Unsupported fingerprint reference schema')
    observed, warnings = observations_from_result(report_or_result)
    dedup, conflicts, duplicates = {}, [], 0
    for row in observed:
        key = (row['subject_id'],row['sample_hash'], row['bank'], row['task_id'], row['dimension'], row['origin'], stable_hash(row.get('measurement_contract', {})), stable_hash(row.get('conditions', {})))
        if key not in dedup: dedup[key] = deepcopy(row); continue
        duplicates += 1
        existing = dedup[key]
        if row.get('origin')=='model_assessed':
            combined=existing.get('assessment_relationships',[existing.get('assessment_relationship')])+[row.get('assessment_relationship')]
            existing['assessment_relationships']=list({stable_hash(relationship_policy(v)):relationship_policy(v)for v in combined}.values())
        for feature, value in row.get('features', {}).items():
            if feature in existing['features'] and existing['features'][feature] != value:
                conflicts.append({'sample_hash': row['sample_hash'], 'feature': feature, 'task_id': row['task_id'], 'reason': 'Same original sample and measurement carries conflicting values'})
                existing['features'][feature] = {'state': 'conflict'}
            else: existing['features'][feature] = value
    observations = list(dedup.values())
    labels = reference.get('model_labels', [])
    cells = reference.get('cells', [])
    strata = defaultdict(list)
    for row in observations: strata[(row['subject_id'],row['bank'], row['task_id'], row['dimension'], row['origin'])].append(row)
    panels, unreferenced = [], []
    descriptor_total = Counter()
    for (subject_id,bank, task, dimension, origin), rows in sorted(strata.items()):
        relations=list({stable_hash(relationship_policy(v)):relationship_policy(v) for row in rows
                        for v in row.get('assessment_relationships',[row.get('assessment_relationship')])}.values()) if origin=='model_assessed' else []
        names = sorted({name for row in rows for name in row.get('features', {})})
        descriptor_total[(subject_id,dimension)] += len(names)
        data = {'strict': defaultdict(dict), 'contextual': defaultdict(dict)}
        available = {'strict': defaultdict(set), 'contextual': defaultdict(set)}
        for name in names:
            known_rows = [row for row in rows if name in row['features'] and _known(row['features'][name],name)]
            if not known_rows:
                unreferenced.append({'subject_id':subject_id,'task_id': task, 'dimension': dimension, 'feature': name, 'state': 'current_unknown', 'origin': origin}); continue
            any_reference = False
            for label in labels:
                matching = [c for c in cells if c['bank'] == bank and c['task_id'] == task and c['dimension'] == dimension and c['model_label'] == label and name in c['descriptors'] and c['descriptors'][name]['known_n']]
                for mode in ('strict', 'contextual'):
                    ref_counts, selected_rows, condition_notes, ref_ids = Counter(), {}, [], set()
                    reference_total=0
                    for cell in matching:
                        contract_notes = _contract_notes(known_rows[0].get('measurement_contract', {}), cell.get('measurement_contract', {}))
                        # A changed definition is shown as missing rather than
                        # calculating a distance between different quantities.
                        changed_definition = any(n['field'] in {'task_version','definition_sha256'} and n['state']=='different' for n in contract_notes)
                        if changed_definition and dimension!='process': continue
                        accepted_rows = []
                        for row in known_rows:
                            if dimension=='process':
                                current_contract=row.get('measurement_contract',{});prior_contract=cell.get('measurement_contract',{})
                                if not current_contract.get('definition_sha256') or current_contract.get('definition_sha256')!=prior_contract.get('definition_sha256') or current_contract.get('task_version')!=prior_contract.get('task_version'):continue
                                notes=_contract_notes(current_contract,prior_contract)
                            else:notes = list(contract_notes)
                            for key, value in cell.get('conditions', {}).items():
                                if key not in row.get('conditions', {}): notes.append({'field': key, 'state': 'missing'})
                                elif type(row['conditions'][key]) is not type(value) or row['conditions'][key] != value: notes.append({'field': key, 'state': 'different'})
                            if row['origin'] != cell.get('origin'): notes.append({'field': 'measurement_origin', 'state': 'different'})
                            if row['origin']=='model_assessed':
                                notes.append({'field':'assessment_relationship','state':relationship_policy(row.get('assessment_relationship'))['relation']})
                                notes.append({'field':'assessment_independence','state':'not_established'})
                            if row.get('source_scope') == 'scripted_demo': notes.append({'field': 'response_origin', 'state': 'scripted_demo'})
                            elif row.get('source_scope') in {'synthetic_fixture','controlled_variant'}:notes.append({'field':'response_origin','state':'synthetic_or_controlled'})
                            if mode == 'strict' and notes: continue
                            if mode == 'contextual' and not notes: continue
                            accepted_rows.append(row); condition_notes += notes
                        if accepted_rows and cell['id'] not in ref_ids:
                            ref_ids.add(cell['id']); ref_counts.update(cell['descriptors'][name]['counts'])
                            reference_total+=cell['descriptors'][name]['known_n']+cell['descriptors'][name].get('unknown_or_missing_n',0)
                            for row in accepted_rows: selected_rows[row['sample_hash']] = row
                    if not ref_counts or not selected_rows: continue
                    current = Counter(encoded_value(name, r['features'][name], dimension) for r in selected_rows.values())
                    ordered_current=list(selected_rows.values())
                    split_counts=[dict(Counter(encoded_value(name,r['features'][name],dimension) for r in ordered_current[offset::2])) for offset in (0,1)]
                    current_total=len({row['sample_hash'] for row in rows})
                    bounds=_distance_bounds(current,ref_counts,current_total,reference_total)
                    outside = sum(n for key, n in current.items() if key not in ref_counts)
                    value = {'feature_id': name, 'current_counts': dict(current), 'reference_counts': dict(ref_counts),
                             'current_split_counts':split_counts,'current_sample_ids':[r['sample_hash'] for r in ordered_current],
                             'current_n': sum(current.values()), 'reference_n': sum(ref_counts.values()),
                             'current_total_n':current_total,'reference_total_n':reference_total,
                             'current_coverage':sum(current.values())/current_total,'reference_coverage':sum(ref_counts.values())/reference_total,
                             'distance': _tv(current, ref_counts), 'outside_this_reference_count': outside,
                             'distance_bounds_with_missing':bounds,
                             'outside_this_reference_ratio': outside/sum(current.values()),
                             'condition_notes': sorted({(n['field'], n['state']) for n in condition_notes}),
                             'reference_cells': sorted(ref_ids)}
                    data[mode][name][label] = value; available[mode][name].add(label); any_reference = True
            if not any_reference:
                unreferenced.append({'subject_id':subject_id,'task_id': task, 'dimension': dimension, 'feature': name, 'state': 'no_comparable_definition_or_reference', 'origin': origin,
                                     'assessment_relationships':relations,'no_additional_independent_vote':origin=='model_assessed',
                                     'known_observations': len(known_rows), 'values': [r['features'][name] for r in known_rows[:5]]})
        for mode in ('strict', 'contextual'):
            cohorts = defaultdict(list)
            for name, members in available[mode].items(): cohorts[tuple(sorted(members))].append(name)
            for cohort, feature_ids in sorted(cohorts.items()):
                per_model = []
                for label in cohort:
                    details = [data[mode][name][label] for name in sorted(feature_ids)]
                    distance = sum(d['distance'] for d in details)/len(details)
                    complete=all(d['current_coverage']==1 and d['reference_coverage']==1 for d in details)
                    bounds=[sum(d['distance_bounds_with_missing'][i] for d in details)/len(details) for i in (0,1)]
                    per_model.append({'model_label': label, 'distance': distance if complete else None,
                                      'observed_subset_distance':distance,'distance_bounds_with_missing':bounds,
                                      'descriptor_affinity': 1-distance if complete else None,'descriptor_affinity_bounds':[1-bounds[1],1-bounds[0]],
                                      'coverage':sum(min(d['current_coverage'],d['reference_coverage']) for d in details)/len(details), 'features': details,
                                      'interpretation': 'Same panel descriptors only; affinity is one minus descriptive distance, not a probability.'})
                panels.append({'id': stable_hash([subject_id,bank, task, dimension, origin, mode, cohort, sorted(feature_ids)]),
                               'subject_id':subject_id,'subject_label':rows[0]['subject_label'],'subject_scope':rows[0]['subject_scope'],
                               'bank': bank, 'task_id': task, 'task_family': _family(task), 'dimension': dimension, 'origin': origin, 'mode': mode,
                               'model_labels': list(cohort), 'feature_ids': sorted(feature_ids), 'per_model': per_model,
                               'excluded_models': [{'model_label': label, 'reason': 'No compatible known reference for this exact descriptor panel'} for label in labels if label not in cohort],
                               'cross_model_comparison': len(cohort) >= 2, 'all_candidate_models_covered': len(cohort) == len(labels),
                               'assessment_relationships':relations,
                               'source_evidence_groups':sorted({r['source_evidence_group']for r in rows if r.get('source_evidence_group')}),
                               'no_additional_independent_vote':origin=='model_assessed','eligible_as_independent_identity_evidence':False,
                               'shared_evidence_group': _family(task), 'no_independent_votes_from_related_features': True})
                from .direction_guard import evaluate
                panels[-1]['direction_guard']=evaluate(panels[-1])
    cards = []
    subjects={row['subject_id']:{'label':row['subject_label'],'scope':row['subject_scope']} for row in observations}
    for subject_id,subject in subjects.items():
      for label in labels:
        dimensions = {}
        for dimension in DIMENSIONS:
            relevant = [p for p in panels if p['subject_id']==subject_id and p['dimension'] == dimension and label in p['model_labels']]
            keys = {(p['task_id'], feature, p['origin']) for p in relevant for feature in p['feature_ids']}
            total=descriptor_total[(subject_id,dimension)]
            dimensions[dimension] = {'coverage': len(keys)/total if total else 0,
                                     'current_descriptor_count': total, 'covered_descriptors': len(keys),
                                     'strict_panels': [p['id'] for p in relevant if p['mode']=='strict'],
                                     'contextual_panels': [p['id'] for p in relevant if p['mode']=='contextual'],
                                     'missing': not relevant,
                                     'state': 'observed_with_reference' if relevant else 'observed_unreferenced' if total else 'not_observed'}
        cards.append({'subject_id':subject_id,'subject_label':subject['label'],'subject_scope':subject['scope'],
                      'model_label': label, 'dimensions': dimensions, 'global_identity_score': None})
    content_hashes = {r.get('content_sha256') for r in observations if r.get('content_sha256')}
    sample_hashes = {r['sample_hash'] for r in observations}
    return {'schema': 'tokenclock-multidimensional-fingerprint/v1', 'status': 'descriptive_observations_available' if panels else 'observed_without_comparable_reference',
            'model_panels': cards, 'comparison_panels': panels, 'observed_unreferenced': unreferenced, 'conflicts': conflicts,
            'deduplication': {'input_observation_rows': len(observed), 'deduplicated_observation_rows': len(observations),
                              'duplicate_measurements_ignored': duplicates, 'original_samples': len(sample_hashes),
                              'sample_count_scope':'Declared records; weak identities do not certify independent original API calls',
                              'identity_kinds': dict(Counter(r.get('identity_kind','unknown') for r in observations))},
            'reference_coverage': reference.get('banks', {}),
            'reference_identity': {'version':reference.get('version'),'sha256':stable_hash(reference)},
            'assessment_relationships':list({stable_hash(relationship_policy(v)):relationship_policy(v) for row in observations if row['origin']=='model_assessed'
                                             for v in row.get('assessment_relationships',[row.get('assessment_relationship')])}.values()),
            'reference_overlap': {'sample_identity_overlap': bool(sample_hashes & {h for c in cells for h in c.get('sample_hashes', [])}),
                                  'answer_content_seen_in_reference': bool(content_hashes & {h for c in cells for h in c.get('content_hashes', [])}),
                                  'meaning': 'Identical short text can occur independently. Neither overlap nor a good fit is held-out accuracy.'},
            'identity_probability': None, 'mixture_proportion': None, 'winner': None, 'warnings': warnings,
            'limitations': ['Every panel uses the same descriptors for every included model; panels with different model coverage cannot be ranked together.',
                            'Task-family-correlated behavior, quality and resource descriptors are not independent identity votes.',
                            'Assisted extraction of an existing answer does not create another independent observation of the target. Same-endpoint parsed fields remain descriptive; different endpoints do not prove different suppliers.',
                            'Unknown measurements and outside-reference values remain visible. A missing dimension does not improve a model distance.',
                            'Strict conditions/definitions are separate from contextual descriptions; assessed semantics is not deterministic certification.',
                            'Evaluator CPU/browser time is not target-model resource use.',
                            'No calibrated confidence, exact-model proof, mixture fraction or forced winner is produced.']}
