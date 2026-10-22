"""Coverage-aware check scores and descriptive behavior distributions.

No candidate-supplied score is read, and no identity or mixing probability is
derived. Related checks and A/B versions retain one correlation group.
"""
from __future__ import annotations
from collections import Counter, defaultdict
import hashlib
import json
import math


def _hash(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def score_checks(checks):
    if not isinstance(checks, list):
        raise ValueError('checks must be a list')
    groups, source, invalid, identities = defaultdict(list), [], [], {}
    duplicate_count = 0
    for index, original in enumerate(checks):
        if not isinstance(original, dict):
            invalid.append({'index': index, 'reason': 'check_not_object'}); continue
        item = dict(original)
        identifier = item.get('id')
        status = item.get('status')
        weight = item.get('weight', 1)
        if not isinstance(identifier, str) or not identifier or status not in {'pass', 'fail', 'unknown', 'not_applicable'}:
            invalid.append({'index': index, 'reason': 'invalid_id_or_status'}); continue
        if type(weight) not in {int, float} or not math.isfinite(weight) or weight <= 0:
            invalid.append({'index': index, 'reason': 'invalid_weight'}); continue
        if identifier in identities:
            if _hash(item) == _hash(identities[identifier]):
                duplicate_count += 1; continue
            invalid.append({'index': index, 'id': identifier, 'reason': 'same_id_different_content'})
            item['status'] = 'unknown'; item['mandatory'] = True
        else:
            identities[identifier] = item
        dimension = str(item.get('dimension', '')).casefold()
        if dimension.startswith('source') or dimension in {'provenance', '来源声明'} or identifier.startswith(('source_', 'source.')):
            source.append(item); continue
        groups[str(item.get('group') or identifier)].append(item)
    grouped = []
    for group, members in groups.items():
        applicable = [x for x in members if x['status'] != 'not_applicable']
        statuses = {x['status'] for x in applicable}
        state = 'not_applicable' if not applicable else 'fail' if 'fail' in statuses else 'unknown' if 'unknown' in statuses else 'pass'
        grouped.append({'group': group, 'status': state, 'weight': max(x.get('weight', 1) for x in members),
                        'check_ids': sorted({x['id'] for x in members}),
                        'known_check_fraction': sum(x['status'] in {'pass', 'fail'} for x in applicable) / len(applicable) if applicable else None,
                        'mandatory_unknown': any(x.get('mandatory', True) and x['status'] == 'unknown' for x in applicable),
                        'reason': 'Related checks share one group weight; a visible failure is not cancelled by another pass.'})
    active = [g for g in grouped if g['status'] != 'not_applicable']
    total = sum(g['weight'] for g in active)
    passed = sum(g['weight'] for g in active if g['status'] == 'pass')
    failed = sum(g['weight'] for g in active if g['status'] == 'fail')
    unknown = sum(g['weight'] for g in active if g['status'] == 'unknown')
    mandatory_unknown = any(g['mandatory_unknown'] for g in active)
    observed_score = 100 * passed / (passed + failed) if passed + failed else None
    return {'schema': 'tokenclock-check-score/v1',
            'score': None if mandatory_unknown or invalid or not total or not (passed + failed) else 100 * passed / total,
            'observed_score': observed_score,
            'score_range': [100 * passed / total, 100 * (passed + unknown) / total] if total else None,
            'coverage': sum(g['weight'] * g['known_check_fraction'] for g in active) / total if total else 0,
            'scored_group_outcome_coverage': (passed + failed) / total if total else 0,
            'full_task_pass': bool(active) and not invalid and all(g['status'] == 'pass' for g in active),
            'mandatory_unknown': mandatory_unknown, 'groups': grouped, 'source_observations': source,
            'invalid_checks': invalid, 'exact_duplicate_checks_ignored': duplicate_count,
            'group_counts': dict(Counter(g['status'] for g in grouped)),
            'identity_probability': None, 'mixture_proportion': None,
            'interpretation': 'Score covers declared task checks only. Observed score excludes unknown checks and is not a full-task score. Source declarations are separate.'}


def compare_behavior(samples, reference, model_labels=None):
    if not isinstance(samples, list) or not isinstance(reference, dict):
        raise ValueError('samples/reference types are invalid')
    samples = [{**s.get('extracted', {}), **{k: v for k, v in s.items() if k != 'extracted'}} if isinstance(s, dict) and isinstance(s.get('extracted'), dict) else s for s in samples]
    cells = reference.get('cells', [])
    labels = model_labels or sorted({c['model_label'] for c in cells})
    questions = defaultdict(list)
    for sample in samples:
        questions[sample.get('task_id', 'unknown')].append(sample)
    results = []
    family_distances = defaultdict(lambda: defaultdict(list))
    for task, rows in sorted(questions.items()):
        matching = [c for c in cells if c['task_id'] == task and c['model_label'] in labels]
        categories = Counter(r.get('status', 'unknown') for r in rows)
        eligible = [r for r in rows if r.get('status') not in {'truncated', 'failed', 'cancelled'} and
                    ((r.get('status') != 'noncompliant' and r.get('compliance') != 'noncompliant') or r.get('behavior_eligible') is True)]
        q = {'task_id': task, 'raw_requests': len(rows), 'eligible_responses': len(eligible),
             'status_counts': dict(categories), 'compliance_counts': dict(Counter(str(r.get('compliance', 'unknown')) for r in rows)),
             'categorical_noncompliant_responses_retained': sum(r.get('status') == 'noncompliant' for r in eligible),
             'unclassified_or_other_responses': sum(r.get('status') == 'partial' or r.get('features', {}).get('extraction_category') == 'OTHER' or r.get('features', {}).get('selected_content') == 'UNCLASSIFIED' for r in rows),
             'models': [], 'shared_evidence_group': 'behavior:' + task.split(':')[0]}
        for cell in matching:
            origin = cell.get('sample_source', 'four-model-extension')
            current_features = []
            rejected_prompt = 0
            condition_notes = []
            for row in eligible:
                given_hash = row.get('prompt_sha256') or row.get('metadata', {}).get('prompt_sha256')
                if given_hash and given_hash != cell.get('prompt_sha256'):
                    rejected_prompt += 1; continue
                current_features.append(row.get('reference_features', {}).get(origin, row.get('features', {})))
                conditions = row.get('conditions', row.get('metadata', {}).get('conditions', {})) or {}
                for key, value in cell.get('conditions', {}).items():
                    if key not in conditions:
                        condition_notes.append((key, 'missing'))
                    elif type(conditions[key]) is not type(value) or conditions[key] != value:
                        condition_notes.append((key, 'different'))
                if not given_hash:
                    condition_notes.append(('prompt_sha256', 'missing'))
            feature_results = []
            for key, prior in cell.get('features', {}).items():
                observed = [f[key] for f in current_features if key in f and f[key] != 'UNKNOWN']
                if not observed:
                    continue
                counts = Counter(_hash(v) for v in observed)
                prior_counts = prior.get('value_hash_counts', {})
                prior_n = sum(prior_counts.values())
                if not prior_n:
                    continue
                union = set(counts) | set(prior_counts)
                distance = sum(abs(counts.get(k, 0) / len(observed) - prior_counts.get(k, 0) / prior_n) for k in union) / 2
                pooled = set().union(*(set(c.get('features', {}).get(key, {}).get('value_hash_counts', {})) for c in matching if c.get('sample_source', 'four-model-extension') == origin))
                outside = sum(n for k, n in counts.items() if k not in pooled)
                outside_model = sum(n for k, n in counts.items() if k not in prior_counts)
                feature_results.append({'feature': key, 'observed_n': len(observed), 'missing_extraction_n': len(current_features) - len(observed),
                                        'reference_n': prior_n, 'reference_missing_n': prior.get('missing', 0),
                                        'value_hash_counts': dict(counts), 'total_variation_distance': distance,
                                        'outside_reference_pool_count': outside, 'outside_reference_pool_ratio': outside / len(observed),
                                        'outside_this_model_count': outside_model,
                                        'contribution': 'Marginal descriptive distance sharing the same question/answer evidence, not an independent identity vote.'})
            mean = sum(f['total_variation_distance'] for f in feature_results) / len(feature_results) if feature_results else None
            model = {'model_label': cell['model_label'], 'reference_sample_source': origin, 'reference_n': cell.get('n'),
                     'features': feature_results, 'mean_marginal_distance': mean,
                     'features_with_observations': len(feature_results), 'reference_features_total': len(cell.get('features', {})),
                     'feature_coverage': len(feature_results) / len(cell['features']) if cell.get('features') else 0,
                     'comparison_scope': 'exact_recorded_conditions' if not condition_notes else 'descriptive_conditions_incomplete_or_different',
                     'condition_notes': [{'field': k, 'state': s} for k, s in sorted(set(condition_notes))],
                     'prompt_mismatch_responses_excluded': rejected_prompt}
            q['models'].append(model)
            if mean is not None:
                family_distances[cell['model_label']][task.split(':')[0]].append(mean)
        q['reference_missing'] = not matching
        results.append(q)
    summary = []
    for label, families in sorted(family_distances.items()):
        means = {f: sum(values) / len(values) for f, values in families.items()}
        summary.append({'model_label': label, 'mean_family_distance': sum(means.values()) / len(means),
                        'families_observed': len(means), 'family_contributions': means,
                        'families_requested': len({task.split(':')[0] for task in questions}),
                        'family_comparison_coverage': len(means) / len({task.split(':')[0] for task in questions}) if questions else 0,
                        'reference_projection_schemas': sorted({c.get('sample_source', 'four-model-extension') for c in cells if c.get('model_label') == label}),
                        'scope': 'Descriptive only; models with different available feature projections are not a calibrated ranking.'})
    return {'schema': 'tokenclock-behavior-comparison/v1', 'questions': results, 'descriptive_model_summaries': summary,
            'identity_probability': None, 'mixture_proportion': None,
            'limitations': ['No green-light threshold or model mixing percentage is inferred.',
                            'Outside-reference answers remain in the distance denominator; failures/truncation/noncompliance remain separately counted. Explicit neutral no-choice categories can remain behavioral observations without becoming compliant answers.',
                            'Missing conditions limit attribution but do not delete descriptive observations.',
                            'Correlated features share one question; A/B versions share one family.',
                            'Feature coverage is reported; distances from different historical annotation schemas are not directly calibrated against one another.',
                            'Small, nonblind historical marginals are not calibrated identity likelihoods.']}
