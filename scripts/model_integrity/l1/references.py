"""Release-safe descriptive references, exact-condition lookup, no classifier.

Only aggregated counts, condition values and hashes leave the local research
inputs. Raw answers, evidence excerpts, run IDs, source paths and credentials
are not copied into the distributable catalog.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
from typing import Any

SCHEMA = 'tokenclock-l1-behavior-reference/v1'
REQUIRED_CONDITIONS = ('reasoning_effort', 'generation_limit', 'system', 'history', 'tools', 'feedback', 'fresh_single_question')


def stable_hash(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def prompt_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _read(path: Path):
    return json.loads(path.read_text())


def _counts(observations: list[dict]) -> dict:
    keys = sorted({key for observation in observations for key in observation})
    result = {}
    for key in keys:
        values = Counter(stable_hash(observation[key]) for observation in observations if key in observation)
        result[key] = {'value_hash_counts': dict(sorted(values.items())),
                       'observed': sum(values.values()), 'missing': len(observations) - sum(values.values())}
    return result


def export_reference(root: Path, output_path: Path | None = None) -> dict:
    root = Path(root)
    full = _read(root / 'research/model_integrity_short_behavior_full_bank_v1_results.json')
    extension = _read(root / 'research/model_integrity_short_behavior_other_groups_v1_results.json')
    private = root / 'research/model_integrity_m12/private'
    bank = _read(private / 'short_behavior_bank_v1/bank.json')
    protocols = [_read(private / name / 'protocol.json') for name in ('short_behavior_sampling_v1', 'short_behavior_completion_v1', 'short_behavior_other_groups_v1')]
    variants = {(item['id'], variant): data for item in bank['items'] for variant, data in item['variants'].items()}
    cells = []

    def add(task, variant, model, observations, protocol, sample_source):
        metadata = variants[(task, variant)]
        actual_hash = prompt_hash(metadata['prompt'])
        if actual_hash != metadata['sha256']:
            raise ValueError('Frozen prompt hash mismatch')
        policy = protocol.get('policies', {}).get(task, {})
        cap = policy.get('generation_limit', protocol.get('caps', {}).get(f'{task}:{variant}'))
        effort = policy.get('effort', protocol.get('effort'))
        if effort != 'high' or not isinstance(cap, int):
            raise ValueError('Reference generation conditions incomplete')
        conditions = {key: protocol.get(key) for key in ('system', 'history', 'tools', 'feedback')}
        conditions.update(reasoning_effort=effort, generation_limit=cap,
                          fresh_single_question=protocol.get('single_prompt_fresh_session', protocol.get('fresh_single_question')))
        if conditions['fresh_single_question'] is not True:
            raise ValueError('Reference is not the declared isolated single-question protocol')
        cells.append({'task_id': f'{task}:{variant}', 'prompt_sha256': actual_hash, 'model_label': model,
                      'conditions': conditions, 'n': len(observations), 'features': _counts(observations),
                      'sample_source': sample_source, 'annotation_blind': False,
                      'condition_limits': ['native family APIs and provider defaults differ', 'time/channel effects not isolated', 'small descriptive sample, not held-out identity validation']})

    for family in full['cells']:
        task = family['id']
        protocol = next(p for p in protocols[:2] if task in p['families'])
        for cell in family['cells']:
            observations = cell['behavior_by_repeat']
            if len(observations) != cell['n']:
                raise ValueError('Old reference denominator mismatch')
            add(task, cell['variant'], cell['model'], observations, protocol, 'claude-base')
    # Aggregate the already reviewed rows, never count the same response twice
    # by adding both extension.cells and extension.rows.
    grouped = defaultdict(list)
    for row in extension['rows']:
        grouped[(row['probe_family'], row['variant'], row['model'])].append(row)
    for (task, variant, model), rows in sorted(grouped.items()):
        expected_hash = variants[(task, variant)]['sha256']
        if any(row['prompt_sha256'] != expected_hash for row in rows):
            raise ValueError('Extension prompt does not match frozen bank')
        add(task, variant, model, [row['root_semantic_observation']['behavior'] for row in rows], protocols[2], 'four-model-extension')
    supplementary = full.get('supplementary_rebinding', {}).get('rows', [])
    for cell in cells:
        if cell['sample_source']=='claude-base' and cell['task_id']=='C06:A':
            matching=[row for row in supplementary if row['model']==cell['model_label']]
            if matching:
                if len(matching)!=cell['n']:raise ValueError('Supplementary C06 denominator mismatch')
                cell['features']['nested_rebinding_contrast'] = _counts([{'value':row['contrast_present']} for row in matching])['value']
                cell['feature_notes']={'nested_rebinding_contrast':{'status':'EXPLORATORY_POST_SAMPLE_FEATURE',
                    'source':'prior_nonblind_hash_bound_annotations','shares_evidence':'behavior:C06'}}
    total = sum(cell['n'] for cell in cells)
    if total != full['valid_generated_answers'] + extension['reviewed_answers']:
        raise ValueError('Reference total does not reconcile')
    result = {'schema': SCHEMA, 'reference_version': '2026-09-09-descriptive-v1', 'valid_answers': total,
              'model_labels': sorted({cell['model_label'] for cell in cells}), 'cells': cells,
              'independent_blinding': False, 'identity_probability': None, 'mixture_proportion': None,
              'arbitrary_natural_tasks_covered': False,
              'scope': 'Exact short-question conditions only. A/B versions share task families. Feature counts share answers and cannot be added as independent evidence.'}
    if output_path is not None:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return result


def load_reference(path: Path) -> dict:
    reference = _read(Path(path))
    if reference.get('schema') != SCHEMA or not isinstance(reference.get('cells'), list):
        raise ValueError('Unsupported reference schema')
    return reference


def lookup(reference: dict, *, task_id: str | None = None, prompt: str | None = None,
           prompt_sha256: str | None = None, conditions: dict | None = None,
           features: dict | None = None, model_labels: list[str] | None = None) -> dict:
    """Strict matches plus clearly separate same-literal-question context.

    Contextual counts survive missing/different conditions but never join the
    strict comparison. Identification uses an exact prompt hash, never topic.
    """
    actual_hash = prompt_hash(prompt) if isinstance(prompt, str) else prompt_sha256
    conditions = conditions if isinstance(conditions, dict) else {}
    result = {'status': 'reference_missing', 'task_id': task_id, 'prompt_sha256': actual_hash,
              'matches': [], 'contextual_matches': [], 'mismatches': [],
              'identity_probability': None, 'mixture_proportion': None}
    if prompt is not None and prompt_sha256 is not None and actual_hash != prompt_sha256:
        result['reason'] = 'supplied_prompt_hash_conflicts_with_literal_prompt'
        return result
    exact_tasks = {cell['task_id'] for cell in reference.get('cells', []) if cell['prompt_sha256'] == actual_hash}
    if not task_id and len(exact_tasks) == 1:
        task_id = next(iter(exact_tasks))
        result.update(task_id=task_id, task_identification='unique_exact_literal_prompt_hash')
    missing = [key for key in REQUIRED_CONDITIONS if key not in conditions]
    result['missing_conditions'] = missing
    if not task_id or not actual_hash:
        result['reason'] = 'task_or_exact_prompt_or_generation_conditions_missing'
        return result
    candidates = [cell for cell in reference.get('cells', []) if cell['task_id'] == task_id]
    for cell in candidates:
        if model_labels is not None and cell['model_label'] not in model_labels:
            continue
        differences = []
        if cell['prompt_sha256'] != actual_hash:
            differences.append('prompt_sha256')
        differences += [key for key in REQUIRED_CONDITIONS if key in conditions and
                        (type(conditions[key]) is not type(cell['conditions'][key]) or conditions[key] != cell['conditions'][key])]
        match = {'model_label': cell['model_label'], 'n': cell['n'], 'conditions': cell['conditions'],
                 'features': cell['features'], 'feature_comparison': {}, 'condition_limits': cell['condition_limits']}
        for name, value in (features or {}).items():
            counts = cell['features'].get(name)
            if counts is None:
                match['feature_comparison'][name] = {'status': 'feature_reference_missing'}
            else:
                match['feature_comparison'][name] = {'status': 'descriptive_count',
                    'same_value_count': counts['value_hash_counts'].get(stable_hash(value), 0),
                    'observed_denominator': counts['observed'], 'missing': counts['missing']}
        if differences or missing:
            result['mismatches'].append({'model_label': cell['model_label'], 'fields': differences, 'missing_fields': missing})
            if cell['prompt_sha256'] == actual_hash:
                match.update(scope='same_literal_question_context_only', strict_comparison_eligible=False,
                             condition_differences=[{'field': key, 'state': 'unknown', 'reference': cell['conditions'][key]} for key in missing] +
                                                  [{'field': key, 'state': 'different', 'reference': cell['conditions'][key], 'current': conditions[key]} for key in differences if key != 'prompt_sha256'])
                result['contextual_matches'].append(match)
            continue
        result['matches'].append(match)
    if result['matches']:
        result['status'] = 'descriptive_reference_available'
    else:
        result['reason'] = 'same_question_conditions_unknown_or_different' if result['contextual_matches'] else 'no_exact_task_prompt_and_condition_match'
    if model_labels:
        represented = {m['model_label'] for m in result['matches']}
        result['missing_model_labels'] = sorted(set(model_labels) - represented)
    return result


def attach_reference(document: dict, report: dict, config: dict | None = None) -> dict:
    """Use explicit measured probe metadata only; never guess from a topic."""
    import copy
    output = copy.deepcopy(report)
    config = config or {}
    reference = config.get('catalog')
    if reference is None and config.get('path'):
        reference = load_reference(Path(config['path']))
    context = document.get('context', {})
    probe = context.get('probe') if isinstance(context.get('probe'), dict) else {}
    user_messages = [r for r in document.get('records', []) if r.get('kind') == 'message' and r.get('role') == 'user']
    if reference is None:
        comparison = {'status': 'reference_missing', 'reason': 'reference_catalog_not_configured'}
    else:
        exact_hashes = {cell['prompt_sha256'] for cell in reference.get('cells', [])}
        applicable = [row for row in user_messages if isinstance(row.get('data', {}).get('text'), str) and prompt_hash(row['data']['text']) in exact_hashes]
        if not applicable:
            comparison = {'status': 'reference_missing', 'reason': 'natural_or_multiturn_task_has_no_exact_probe_reference'}
        else:
            comparisons = []
            for row in applicable[:10]:
                conditions = dict(probe.get('conditions') or {})
                if len(user_messages) > 1:
                    # Visible extra conversation is a real condition difference;
                    # a caller-supplied empty-history label cannot erase it.
                    conditions['history'] = 'additional_user_turns_visible'
                    conditions['fresh_single_question'] = False
                item = lookup(reference, task_id=probe.get('task_id') if len(applicable) == 1 else None,
                              prompt=row['data']['text'], prompt_sha256=probe.get('prompt_sha256') if len(applicable) == 1 else None,
                              conditions=conditions, features=config.get('observed_features'), model_labels=config.get('model_labels'))
                item['matched_user_record_id'] = row.get('id')
                comparisons.append(item)
            comparison = comparisons[0] if len(comparisons) == 1 else {
                'status': 'descriptive_multi_question_references', 'per_question': comparisons,
                'scope': 'Each literal question is separate; counts across questions are not independent model probabilities.'}
    output['reference_comparison'] = comparison
    if comparison['status'] == 'reference_missing':
        output.setdefault('unknowns', []).append({'code': 'reference_missing', 'reason': comparison['reason'], 'evidence': []})
    return output
