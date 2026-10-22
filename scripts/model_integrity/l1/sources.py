"""Read-only source projections for the bounded L1 engineering bank.

This module never imports runner code, executes transcript commands, calls a
model, or treats local hashes / model declarations as backend authentication.
Only selected public-facing messages, tool records and documented metadata are
projected. Hidden reasoning and graders are not detector inputs.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_OUTPUT = ROOT / 'research/model_integrity_l1_confusion_bank_v1/private/materialized-v1'
SCHEMA = 'tokenclock-l1-observation/v1'
MAX_SOURCE_BYTES = 32 * 1024 * 1024


def load(path: Path) -> Any:
    if path.stat().st_size > MAX_SOURCE_BYTES:
        raise ValueError('Source exceeds the bounded 32 MiB import limit')
    return json.loads(path.read_text(encoding='utf-8'))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_ref(path: Path) -> dict:
    path = path.resolve()
    try:
        label = str(path.relative_to(ROOT))
    except ValueError:
        label = str(path)
    return {'path': label, 'sha256': digest(path)}


def _save(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    path.chmod(0o600)


def _base(identifier: str, fmt: str, refs: list[dict], kind: str = 'research_capture') -> dict:
    return {'schema': SCHEMA, 'id': identifier,
            'source': {'kind': kind, 'format': fmt, 'refs': refs},
            'context': {}, 'records': []}


def _record(doc: dict, kind: str, role: str, data: dict, pointer: str,
            source: dict, **bindings: Any) -> dict:
    row = {'id': f"{doc['id']}-r{len(doc['records']) + 1:04d}",
           'seq': len(doc['records']), 'kind': kind, 'role': role,
           'data': data, 'source_pointer': {'path': source['path'], 'json_pointer': pointer}}
    row.update({k: v for k, v in bindings.items() if v is not None})
    doc['records'].append(row)
    return row


def _exit(text: Any, metadata: dict | None = None) -> Any:
    meta = metadata or {}
    if 'exit' in meta:
        return meta['exit']
    if 'exit_code' in meta:
        return meta['exit_code']
    if isinstance(text, str):
        try:
            value = json.loads(text)
            if isinstance(value, dict) and 'exit_code' in value:
                return value['exit_code']
        except (ValueError, TypeError):
            pass
    return None


def _usage(raw: dict, schema: str) -> dict:
    """Preserve missing versus null/zero; never assume additive cache semantics."""
    out: dict = {'schema': schema, 'raw': raw}
    names = {'input_tokens': 'input_tokens', 'output_tokens': 'output_tokens',
             'reasoning_tokens': 'reasoning_tokens', 'total_tokens': 'total_tokens',
             'cache_read_input_tokens': 'cache_read_tokens',
             'cache_creation_input_tokens': 'cache_write_tokens'}
    for key, dest in names.items():
        if key in raw:
            out[dest] = raw[key]
    if schema == 'unknown':
        out['adapter'] = 'opencode_session_tokens'
        for key, dest in [('input', 'input_tokens'), ('output', 'output_tokens'),
                          ('reasoning', 'reasoning_tokens'), ('total', 'total_tokens')]:
            if key in raw:
                out[dest] = raw[key]
        for key, dest in [('read', 'cache_read_tokens'), ('write', 'cache_write_tokens')]:
            if isinstance(raw.get('cache'), dict) and key in raw['cache']:
                out[dest] = raw['cache'][key]
    if schema == 'openai_responses':
        for outer, key, dest in [('input_tokens_details', 'cached_tokens', 'cache_read_tokens'),
                                 ('input_tokens_details', 'cache_write_tokens', 'cache_write_tokens'),
                                 ('output_tokens_details', 'reasoning_tokens', 'reasoning_tokens')]:
            if isinstance(raw.get(outer), dict) and key in raw[outer]:
                out[dest] = raw[outer][key]
    return out


def project_opencode(path: Path, identifier: str = 'imported-opencode',
                     tool_payload_path: Path | None = None) -> dict:
    """Import native export {info, messages:[{info,parts}]} without guessing IDs."""
    raw = load(path)
    if not isinstance(raw, dict) or not isinstance(raw.get('messages'), list):
        raise ValueError('Expected native OpenCode session export')
    if any(not isinstance(m, dict) or not isinstance(m.get('info'), dict)
           or not isinstance(m.get('parts'), list) for m in raw['messages']):
        raise ValueError('Unbound session-db arrays are not a native role-bound export')
    ref = source_ref(path)
    doc = _base(identifier, 'opencode_native_session_export', [ref])
    from .model_fields import capture
    def append_field(doc,kind,role,data,line=None,pointer=None,**bindings):
        return _record(doc,kind,role,data,pointer,ref,**bindings)
    info = raw.get('info', {})
    if isinstance(info.get('id'),str):doc['context']['session_id']=info['id']
    capture(doc,info,None,append_field,scope='session_default',pointer='/info')
    payload_ref = None
    payloads = {}
    if tool_payload_path is not None:
        payload_raw = load(tool_payload_path)
        if not info.get('id') or payload_raw.get('session', {}).get('id') != info['id']:
            raise ValueError('Tool payload supplement must have the same captured native session ID')
        observed = collections.defaultdict(list)
        for pi, entry in enumerate(payload_raw.get('parts', [])):
            wrapped = isinstance(entry.get('data'), dict)
            part = entry['data'] if wrapped else entry
            pointer = f'/parts/{pi}' + ('/data' if wrapped else '')
            if part.get('type') == 'tool' and part.get('callID'):
                observed[part['callID']].append((pointer, part))
        payloads = {key: values[0] for key, values in observed.items() if len(values) == 1}
        payload_ref = source_ref(tool_payload_path)
        doc['source']['refs'].append(payload_ref)
    if info.get('id'):
        doc['context']['session_id'] = info['id']
    doc['context']['capture_complete'] = False  # selected export, not proof of entire lifecycle
    if isinstance(info.get('model'), dict):
        model = info['model']
        if model.get('id'):
            doc['context']['display_model'] = model['id']
        if model.get('providerID'):
            doc['context']['provider'] = model['providerID']
    for index, message in enumerate(raw['messages']):
        meta = message['info']
        role = meta.get('role', 'unknown')
        role = role if role in ('user', 'assistant', 'system', 'tool', 'evaluator', 'child') else 'unknown'
        binding = {'generation_id': meta.get('id'), 'parent_id': meta.get('parentID')}
        capture(doc,meta,None,append_field,scope='request' if role=='user' else 'response' if role=='assistant' else 'unknown',
                owner='child' if role=='child' else 'main',turn=meta.get('parentID') if role=='assistant' else meta.get('id'),pointer=f'/messages/{index}/info')
        if role == 'user' and isinstance(meta.get('model'), dict):
            model = meta['model']
            if model.get('modelID'):
                doc['context'].setdefault('requested_model', model['modelID'])
                _record(doc, 'model_request', 'user',
                        {'model': model['modelID'], 'provider': model.get('providerID'),
                         'declaration_scope': 'local_harness_user_message'},
                        f'/messages/{index}/info/model', ref, generation_id=meta.get('id'))
        elif role == 'assistant' and meta.get('modelID'):
            _record(doc, 'model_response', role,
                    {'model': meta['modelID'], 'provider': meta.get('providerID'),
                     'declaration_scope': 'local_harness_assistant_message'},
                    f'/messages/{index}/info', ref, **binding)
        for pindex, part in enumerate(message['parts']):
            pointer = f'/messages/{index}/parts/{pindex}'
            ptype = part.get('type')
            if ptype == 'text':
                _record(doc, 'message', role, {'text': part.get('text', '')}, pointer, ref, **binding)
            elif ptype == 'tool':
                state = part.get('state', {})
                call = part.get('callID')
                tool_pointer, tool_ref = pointer, ref
                actor_binding = {}
                if call in payloads:
                    payload_pointer, payload_part = payloads[call]
                    if payload_part.get('tool') != part.get('tool'):
                        raise ValueError('Same call ID has inconsistent native tool names')
                    state = payload_part.get('state', {})
                    tool_pointer, tool_ref = payload_pointer, payload_ref
                    actor_binding = {'actor_source_pointer': {'path': ref['path'],
                                     'json_pointer': f'/messages/{index}/info/role'}}
                # Native call/result live in the same part. No provider request ID fabricated.
                pair = call or f'local:{ref["sha256"][:16]}:{index}:{pindex}'
                bkind = 'native_call_id' if call else 'local_same_source_record'
                _record(doc, 'tool_call', role,
                        {'name': part.get('tool', ''), 'arguments': state.get('input', {}),
                         'binding_kind': bkind}, tool_pointer + '/state/input', tool_ref,
                        call_id=pair, **binding, **actor_binding)
                if 'output' in state:
                    result = {'text': state['output'], 'binding_kind': bkind,
                              'tool_status': state.get('status')}
                    code = _exit(state['output'], state.get('metadata'))
                    if code is not None:
                        result['exit_code'] = code
                    for key in ('truncated', 'count'):
                        if key in state.get('metadata', {}):
                            result[key] = state['metadata'][key]
                    _record(doc, 'tool_result', role, result, tool_pointer + '/state/output', tool_ref,
                            call_id=pair, **binding, **actor_binding)
                else:
                    _record(doc, 'gap', role, {'reason': 'Tool result absent in captured part'},
                            pointer, ref, call_id=pair, **binding)
            # Reasoning, encrypted content, step billing duplication and snapshots are excluded.
        if isinstance(meta.get('tokens'), dict):
            _record(doc, 'usage', role, _usage(meta['tokens'], 'unknown'),
                    f'/messages/{index}/info/tokens', ref, **binding)
    return doc


def project_history(path: Path, identifier: str = 'imported-history') -> dict:
    """Import native Responses items or Anthropic message/tool blocks in order."""
    raw = load(path)
    if not isinstance(raw, list):
        raise ValueError('Expected native message history array')
    ref = source_ref(path)
    doc = _base(identifier, 'native_message_history', [ref])
    doc['context']['capture_complete'] = False
    caller_by_call: dict[str, str] = {}
    for i, item in enumerate(raw):
        pointer = f'/{i}'
        if item.get('type') == 'reasoning':
            continue
        role = item.get('role', 'assistant' if item.get('type') in ('function_call', 'message') else 'unknown')
        # An output-item ID (e.g. fc_...) is not a response/generation ID.
        binding = {'source_item_id': item.get('id')}
        if item.get('type') == 'function_call':
            call = item.get('call_id')
            caller_by_call[call] = role
            _record(doc, 'tool_call', role,
                    {'name': item.get('name', ''), 'arguments': item.get('arguments', '')},
                    pointer, ref, call_id=call, **binding)
        elif item.get('type') == 'function_call_output':
            call = item.get('call_id')
            text = item.get('output', '')
            data = {'text': text}
            code = _exit(text)
            if code is not None:
                data['exit_code'] = code
            _record(doc, 'tool_result', caller_by_call.get(call, 'unknown'), data,
                    pointer, ref, call_id=call)
        elif isinstance(item.get('content'), str):
            _record(doc, 'message', role, {'text': item['content']}, pointer + '/content', ref, **binding)
        elif isinstance(item.get('content'), list):
            for bi, block in enumerate(item['content']):
                loc = pointer + f'/content/{bi}'
                if block.get('type') in ('text', 'output_text', 'input_text'):
                    _record(doc, 'message', role, {'text': block.get('text', '')}, loc, ref, **binding)
                elif block.get('type') == 'tool_use':
                    call = block.get('id')
                    caller_by_call[call] = role
                    _record(doc, 'tool_call', role,
                            {'name': block.get('name', ''), 'arguments': block.get('input', {})},
                            loc, ref, call_id=call, **binding)
                elif block.get('type') == 'tool_result':
                    call = block.get('tool_use_id')
                    text = block.get('content', '')
                    data = {'text': text}
                    code = _exit(text)
                    if code is not None:
                        data['exit_code'] = code
                    _record(doc, 'tool_result', caller_by_call.get(call, 'unknown'), data,
                            loc, ref, call_id=call)
    return doc


def project_artifact(run: Path, identifier: str = 'imported-artifact') -> dict:
    if (run / 'answer.txt').stat().st_size > MAX_SOURCE_BYTES:
        raise ValueError('Artifact answer exceeds the bounded 32 MiB import limit')
    inp, response = load(run / 'input.json'), load(run / 'response.json')
    refs = [source_ref(run / name) for name in ('input.json', 'response.json', 'answer.txt')]
    doc = _base(identifier, 'sealed_tool_free_artifact_run', refs)
    doc['context'] = {'tools_available': [], 'capture_complete': False,
                      'requested_model': inp['schedule']['model']}
    _record(doc, 'model_request', 'user', {'model': inp['schedule']['model'],
            'declaration_scope': 'local_recorded_schedule'}, '/schedule/model', refs[0])
    _record(doc, 'message', 'user', {'text': inp['prompt']}, '/prompt', refs[0])
    generation = response.get('id')
    if response.get('model'):
        _record(doc, 'model_response', 'assistant', {'model': response['model']},
                '/model', refs[1], generation_id=generation)
    _record(doc, 'message', 'assistant', {'text': (run / 'answer.txt').read_text()}, '',
            refs[2], generation_id=generation)
    if isinstance(response.get('usage'), dict):
        schema = 'openai_responses' if response.get('object') == 'response' else 'anthropic_messages'
        _record(doc, 'usage', 'assistant', _usage(response['usage'], schema), '/usage',
                refs[1], generation_id=generation)
    _record(doc, 'metadata', 'assistant', {key: response[key] for key in
            ('status', 'stop_reason', 'incomplete_details', 'error') if key in response},
            '', refs[1], generation_id=generation)
    return doc


def project_dialogue(path: Path, identifier: str = 'imported-dialogue') -> dict:
    """Project only literal user/assistant turns, never grade or preference labels."""
    raw = load(path)
    if not isinstance(raw.get('turns'), list):
        raise ValueError('Expected normalized dialogue with literal turns')
    ref = source_ref(path)
    doc = _base(identifier, 'existing_normalized_dialogue_text_only', [ref])
    doc['context']['capture_complete'] = False
    for index, turn in enumerate(raw['turns']):
        for role, key in [('user', 'user_text'), ('assistant', 'assistant_text')]:
            if key in turn:
                _record(doc, 'message', role, {'text': turn[key]}, f'/turns/{index}/{key}', ref,
                        stage=f'turn-{index + 1}')
        if turn.get('truncated'):
            _record(doc, 'gap', 'unknown', {'reason': 'Source marks this answer truncated'},
                    f'/turns/{index}/truncated', ref, stage=f'turn-{index + 1}')
    return doc


def project_source(path: Path, identifier: str = 'imported-session') -> dict:
    """CLI-compatible bounded auto-detection; native formats only, no execution."""
    path = Path(path)
    if path.is_dir():
        doc = project_artifact(path, identifier)
    else:
        raw = load(path)
        if isinstance(raw, list):
            doc = project_history(path, identifier)
        elif isinstance(raw, dict) and 'messages' in raw:
            doc = project_opencode(path, identifier)
        elif isinstance(raw, dict) and 'turns' in raw:
            doc = project_dialogue(path, identifier)
        else:
            raise ValueError('Unsupported source format; no inferred event scaffold is constructed')
    doc['source']['kind'] = 'imported_session'
    return doc


def candidates(root: Path = ROOT) -> list[dict]:
    """One anchor per task family. Source choice never reads quality scores."""
    out: list[dict] = []
    rows = load(root / 'research/model_integrity_m12/private/replay-features-blind.json')
    groups: dict[str, list] = collections.defaultdict(list)
    for row in rows:
        if row['source'].startswith('M9'):
            groups['m9-' + row['context']['task']].append(row)
        elif row['source'] == 'M10':
            groups['maintenance-' + row['context']['task']].append(row)
    for family, members in sorted(groups.items()):
        # Source ID ordering frozen independently of score/features.
        row = sorted(members, key=lambda r: r['source_id'])[0]
        original = root / row['source_path']
        native = original.with_name('session.private.json' if family.startswith('m9-') else 'session-export.json')
        out.append({'lineage_group': family, 'bucket': 'tool_task_groups', 'path': native,
                    'format': 'opencode', 'limitations': [
                        'One native export anchor; near-duplicate instances and model arms grouped together.',
                        'OpenCode model/usage fields are local harness declarations; no backend identity proof.',
                        'Captured export completeness is unknown; hidden reasoning and grader outputs excluded.'],
                    'related_original_records': len(members)})
    out.append({'lineage_group': 'incremental-pipeline-cache', 'bucket': 'tool_task_groups',
                'path': root / 'research/model_integrity_m12/private/pipeline-v2/pipeline-04/history.json',
                'format': 'history', 'limitations': [
                    'One anchor from an existing paired task; native history has no per-response model/usage metadata.',
                    'Tool results keep native tool-use bindings; no grader evaluations imported.'],
                'related_original_records': 2})
    idx = load(root / 'research/model_integrity_m6_actual_b/private/source-index.private.json')
    tool_groups: dict[str, list] = collections.defaultdict(list)
    dialog_groups: dict[str, list] = collections.defaultdict(list)
    for row in idx['records']:
        payload = load(Path(row['payload_path']))
        if row['channel'] == 'T':
            tool_groups[payload['task_family_id']].append((row, payload))
        elif row['channel'] == 'D':
            # A/B task rewordings are one conceptual dialogue family, not new groups.
            dialog_groups[payload['stratum']].append((row, payload))
    for family, members in sorted(tool_groups.items()):
        native = None
        for row, _ in sorted(members, key=lambda x: x[0]['record_id']):
            cap = next(b for b in row['source_bindings'] if b['role'] == 'session_capture')
            for name in ('session.private.json', 'session.sanitized.private.json'):
                candidate = Path(cap['path']).with_name(name)
                try:
                    decoded = load(candidate)
                    if all('info' in m and 'parts' in m for m in decoded['messages']):
                        native = candidate
                        break
                except (ValueError, OSError, KeyError, TypeError):
                    continue
            if native is not None:
                break
        if native is None:
            raise ValueError('No complete role-bound native export for selected task family')
        out.append({'lineage_group': 'm5-tool-' + family, 'bucket': 'tool_task_groups',
                    'path': native, 'format': 'opencode',
                    'tool_payload_path': native.with_name('session-db.private.json'),
                    'limitations': ['Existing M5 task anchor; alternate model arms and A/B variants share the family.',
                                    'First parseable role-bound native/sanitized export selected; truncated exports excluded before detector evaluation.',
                                    'Sanitized export supplies native roles/IDs; same-session raw DB tool payloads are joined only by unique matching native callID and tool name.',
                                    'External hidden graders remain excluded; unresolved or repeated call IDs retain redacted/unknown payloads.'],
                    'related_original_records': len(members)})
    for family, members in sorted(dialog_groups.items()):
        row, _ = sorted(members, key=lambda x: x[0]['record_id'])[0]
        out.append({'lineage_group': 'm5-dialogue-' + family, 'bucket': 'natural_or_multiturn_groups',
                    'path': Path(row['payload_path']), 'format': 'dialogue',
                    'limitations': ['Controlled three-turn dialogue, not an unconstrained natural session.',
                                    'Existing literal text projection only: original tool/usage/model provenance is not available in this view.',
                                    'A/B near-duplicate prompts share the family; no target actions are invented.'],
                    'related_original_records': len(members)})
    artifact_rows = load(root / 'research/model_integrity_m12/private/process_profile_audit_v1/features.json')['rows']
    artifacts: dict[str, list] = collections.defaultdict(list)
    for row in artifact_rows:
        artifacts[row['item_id']].append(row)
    for family, members in sorted(artifacts.items()):
        row = sorted(members, key=lambda r: r['id'])[0]
        out.append({'lineage_group': 'artifact-' + family, 'bucket': 'tool_free_deliverables',
                    'path': root / 'research/model_integrity_m12/private/open_artifact_sampling_v2/runs' / row['id'],
                    'format': 'artifact', 'limitations': [
                        'Final-answer artifact only; no target tools or evaluator tests are converted into model actions.',
                        'All model arms for the same task are one lineage; API label is a declaration, not verified identity.'],
                    'related_original_records': len(members)})
    return out


def materialize(output: Path = DEFAULT_OUTPUT, root: Path = ROOT) -> dict:
    selected = candidates(root)
    if len(selected) > 32:
        raise ValueError('Candidate set exceeds frozen bounded parent cap')
    # Freeze five acceptance groups before materializing any derivatives. Cover all buckets.
    acceptance = {'m9-F3', 'maintenance-framing', 'artifact-OA04', 'artifact-OA11',
                  'm5-dialogue-evidence_diagnosis'}
    lineages = {c['lineage_group'] for c in selected}
    if not acceptance.issubset(lineages):
        raise ValueError('Frozen acceptance lineage is unavailable')
    parsers = {'opencode': project_opencode, 'history': project_history,
               'artifact': project_artifact, 'dialogue': project_dialogue}
    parents = []
    for index, c in enumerate(selected, 1):
        identifier = f'l1-parent-{index:03d}'
        if c.get('tool_payload_path'):
            doc = project_opencode(c['path'], identifier, c['tool_payload_path'])
        else:
            doc = parsers[c['format']](c['path'], identifier)
        models = sorted({str(r['data']['model']) for r in doc['records']
                         if r['kind'] in ('model_request', 'model_response') and r['data'].get('model')})
        dest = output / 'parents' / (identifier + '.json')
        _save(dest, doc)
        try:
            observation_path = str(dest.relative_to(root))
        except ValueError:
            observation_path = str(dest.resolve())
        parents.append({'id': identifier, 'lineage_group': c['lineage_group'],
                        'split': 'acceptance' if c['lineage_group'] in acceptance else 'development',
                        'bucket': c['bucket'], 'observation_path': observation_path,
                        'observation_sha256': digest(dest), 'source_refs': doc['source']['refs'],
                        'original_model_labels': models, 'limitations': c['limitations'],
                        'related_original_records_not_independent_parents': c['related_original_records'],
                        'record_counts': dict(collections.Counter(r['kind'] for r in doc['records']))})
    report = {'schema': 'tokenclock-l1-parent-selection/v1', 'status': 'MATERIALIZED_FROZEN',
              'selection_rule': 'One existing source anchor per task family; family grouping precedes derivatives; no score-based selection.',
              'parents': parents, 'parent_count': len(parents),
              'lineage_group_count': len({p['lineage_group'] for p in parents}),
              'bucket_counts': dict(collections.Counter(p['bucket'] for p in parents)),
              'split_counts': dict(collections.Counter(p['split'] for p in parents)),
              'unique_input_files': len({r['path'] for p in parents for r in p['source_refs']}),
              'new_model_calls': 0, 'new_cost_usd': '0',
              'limitations': ['32-group quota is a maximum target, not a reason to split near-duplicate tasks.',
                             'Actual controlled multiround corpus covers four dialogue families; natural-session temporary path index is unavailable.',
                             'All twelve existing open-artifact families retained to cover visual/text/code tasks; this exceeds the soft bucket target of eight.',
                             'Selected existing research captures are not untouched or independently sampled model validation.',
                             'Current filesystem content was not interpreted as historic artifact snapshots.']}
    _save(output / 'parents.json', report)
    _save(output / 'source-selection.json', {k: v for k, v in report.items() if k != 'parents'} | {
        'planned_parent_count': 32, 'shortfall': 32 - len(parents),
        'frozen_acceptance_groups': sorted(acceptance),
        'selected_lineages': sorted(lineages),
        'source_hashes_verified_at_materialization': True,
        'detector_input_excludes': ['grader results', 'gold labels', 'operator IDs', 'recipe IDs',
                                   'hidden reasoning', 'encrypted reasoning', 'synthetic event scaffold']})
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--import-source', type=Path)
    parser.add_argument('--id', default='imported-session')
    args = parser.parse_args()
    if args.import_source:
        doc = project_source(args.import_source, args.id)
        _save(args.output, doc)
        print(json.dumps({'status': 'imported', 'records': len(doc['records'])}))
    else:
        report = materialize(args.output)
        print(json.dumps({k: report[k] for k in ('status', 'parent_count', 'lineage_group_count',
                                               'bucket_counts', 'split_counts', 'unique_input_files')}))


if __name__ == '__main__':
    main()
