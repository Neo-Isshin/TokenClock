"""Visible harness model metadata; never treat a mention or a local label as attestation.

Only explicit metadata containers are traversed. Prompt text, tool output, reasoning,
files and arbitrary tool arguments are not searched for model-looking strings.
"""
from __future__ import annotations
import json
import re

FIELDS = {'model', 'model_id', 'modelID', 'model_slug', 'requested_model',
          'response_model', 'resolved_model', 'actual_model', 'served_model'}
CONTAINERS = {'metadata', 'client_metadata', 'turn_metadata', 'x-codex-turn-metadata',
              'internal_chat_message_metadata_passthrough', 'request', 'response'}
SCHEMA = 'tokenclock-visible-model-fields/v1'


def model_value(value):
    if not isinstance(value, str): return None
    value = value.strip()
    if not value or len(value) > 160 or re.search(r'[\s\x00-\x1f]', value): return None
    if value.lower().startswith(('sk-', 'bearer', 'https://', 'http://')): return None
    return value


def owner_of(payload, inherited='main'):
    if not isinstance(payload, dict): return inherited
    agent = payload.get('agent_name')
    if (isinstance(agent, str) and agent.startswith('/root/')) or isinstance(payload.get('parent_agent_id'),str) and payload['parent_agent_id']:
        return 'child'
    source = payload.get('source')
    if isinstance(source, dict) and (any(k in source for k in ('subagent', 'parent_agent_id')) or source.get('type')=='subagent'):
        return 'child'
    if isinstance(source, str) and source in {'subagent', 'sub_agent', 'child'}: return 'child'
    for key in CONTAINERS:
        nested = payload.get(key)
        if isinstance(nested, dict) and nested is not payload:
            name = nested.get('agent_name')
            if (isinstance(name, str) and name.startswith('/root/')) or isinstance(nested.get('parent_agent_id'),str) and nested['parent_agent_id']: return 'child'
    return inherited


def capture(doc, payload, line, append, *, scope, owner='main', turn=None, pointer='/payload'):
    """Append separately typed local declarations, with exact field positions."""
    count = 0
    def visit(obj, base, current_scope, current_owner, depth=0):
        nonlocal count
        if not isinstance(obj, dict) or depth > 3 or count >= 24: return
        current_owner = owner_of(obj, current_owner)
        for key in sorted(FIELDS & obj.keys()):
            raw = obj[key]
            values = [(key, raw)]
            if key == 'model' and isinstance(raw, dict):
                values = [('model/' + k, raw[k]) for k in ('id', 'modelID', 'name') if k in raw]
            for field, raw in values:
                value = model_value(raw)
                if value is None: continue
                field_scope = 'request' if key == 'requested_model' else 'response' if key in {'response_model', 'resolved_model', 'actual_model', 'served_model'} else current_scope
                if current_scope in {'compaction', 'child_request'}: field_scope = current_scope
                location = base + '/' + field
                append(doc, 'model_declaration', 'unknown', {
                    'model': value, 'field': location, 'scope': field_scope,
                    'owner': current_owner, 'origin': 'local_harness_metadata_not_attestation',
                    'session_id': doc.get('context',{}).get('session_id'),
                }, line, pointer=location, generation_id=obj.get('turn_id') or turn)
                count += 1
        for key in sorted(CONTAINERS & obj.keys()):
            nested = obj[key]
            if key in {'turn_metadata', 'x-codex-turn-metadata'} and isinstance(nested, str) and len(nested) <= 32768:
                try: nested = json.loads(nested)
                except (ValueError, TypeError): continue
            sub_scope = key if key in {'request', 'response'} else current_scope
            visit(nested, base + '/' + key, sub_scope, current_owner, depth + 1)
    visit(payload, pointer, scope, owner)


def inspect(records, add, unknown, comparison_model=None, collisions=()):
    declarations = []
    observed_keys=set()
    for row in records:
        if row.get('kind') != 'model_declaration': continue
        data = row.get('data', {})
        model = model_value(data.get('model'))
        if model is None: continue
        scope=data.get('scope');owner=data.get('owner');turn=row.get('generation_id');field=data.get('field')
        if not isinstance(scope,str) or scope not in {'request','response','session_default','compaction','child_request'}:scope='unknown'
        if not isinstance(owner,str) or owner not in {'main','child','compaction'}:owner='unknown'
        if not isinstance(turn,str) or not turn.strip() or len(turn)>512:turn=None
        if not isinstance(field,str) or len(field)>512:field=None
        pointer=row.get('source_pointer');pointer=pointer if isinstance(pointer,dict) else {}
        entry = {'record_id': row['id'], 'model': model, 'scope': scope,
                 'owner': owner, 'turn_id': turn,
                 'session_id':data.get('session_id') if isinstance(data.get('session_id'),str) else None,
                 'field': field, 'source_pointer': pointer,
                 'binding_ambiguous': row.get('_native_id') in collisions}
        declarations.append(entry)
        key=(model,entry['scope'],entry['owner'],entry['field'])
        if key not in observed_keys:
            observed_keys.add(key)
            add('source.harness_model_observed', {k:entry[k] for k in ('model','scope','owner','field')},
                [row['id']], dimension='来源声明', group='G-ROUTE', generation=entry['turn_id'])

    main = [d for d in declarations if d['owner'] == 'main' and not d['binding_ambiguous']]
    requests = [d for d in main if d['scope'] == 'request']
    defaults = [d for d in main if d['scope'] == 'session_default']
    by_turn = {}
    for d in main:
        if d['turn_id'] and d['scope'] in {'request', 'response'}:
            by_turn.setdefault((d['session_id'],d['turn_id']), []).append(d)
    paired_turns=set()
    for (session,turn), entries in by_turn.items():
        req = [d for d in entries if d['scope'] == 'request']
        rep = [d for d in entries if d['scope'] == 'response']
        wanted = sorted({d['model'] for d in req}); returned = sorted({d['model'] for d in rep})
        if wanted and returned:paired_turns.add((session,turn))
        if wanted and returned and {v.casefold() for v in wanted} != {v.casefold() for v in returned}:
            add('source.harness_model_difference', {'requested':wanted,'reported':returned,
                'turn_id':turn,'scope':'same_visible_turn_not_authenticated_request_pair'},
                [d['record_id'] for d in req + rep], dimension='来源声明', group='G-ROUTE', generation=turn)
        elif len(wanted)==len(returned)==1:
            add('source.harness_model_consistent', {'model':wanted[0],'turn_id':turn,
                'scope':'same_visible_turn_not_authenticated_request_pair'},
                [d['record_id'] for d in req+rep], dimension='来源声明',group='G-ROUTE',generation=turn)
        elif len({d['model'].casefold() for d in entries}) > 1:
            add('source.harness_multiple_models_in_turn', {'models':sorted({d['model'] for d in entries}), 'turn_id':turn},
                [d['record_id'] for d in entries], dimension='来源声明', group='G-ROUTE', generation=turn)

    chunks=[]
    for entry in requests:
        pointer=entry.get('source_pointer') or {}
        key=(entry['session_id'],entry['turn_id'] or ('line',pointer.get('line',entry['record_id'])))
        if not chunks or chunks[-1][0]!=key:chunks.append((key,[]))
        chunks[-1][1].append(entry)
    previous = None;latest_request=None
    for _,entries in chunks:
        if len({d['model'].casefold() for d in entries})!=1:
            previous=None;latest_request=None;continue
        current=entries[-1];latest_request=current
        if previous and previous['session_id']==current['session_id'] and previous['model'].casefold() != current['model'].casefold():
            add('source.harness_model_change', {'from':previous['model'],'to':current['model'],
                'from_turn':previous['turn_id'],'to_turn':current['turn_id']},
                [previous['record_id'],current['record_id']], dimension='来源声明', group='G-ROUTE', generation=current['turn_id'])
        previous = current
    if defaults and latest_request and defaults[-1]['session_id']==latest_request['session_id'] and defaults[-1]['model'].casefold() != latest_request['model'].casefold():
        add('source.harness_default_difference', {'session_default':defaults[-1]['model'],
            'latest_request':latest_request['model']}, [defaults[-1]['record_id'],latest_request['record_id']],
            dimension='来源声明', group='G-ROUTE', generation=latest_request['turn_id'])
    expected = model_value(comparison_model)
    if expected and latest_request and expected.casefold() != latest_request['model'].casefold():
        add('source.comparison_target_difference', {'comparison_target':expected,
            'latest_recorded_request':latest_request['model'],
            'scope':'user_comparison_target_not_historical_request'}, [latest_request['record_id']],
            dimension='来源声明', group='G-ROUTE', generation=latest_request['turn_id'])
    unscoped = [d for d in main if d['scope'] == 'unknown' or d['scope'] in {'request','response'} and (d['session_id'],d['turn_id']) not in paired_turns]
    for session in {d['session_id'] for d in unscoped}:
        candidates=[d for d in unscoped+defaults if d['session_id']==session]
        if len({d['model'].casefold() for d in candidates})>1:
            add('source.harness_unbound_models', {'models':sorted({d['model'] for d in candidates})},
                [d['record_id'] for d in candidates], dimension='来源声明', group='G-ROUTE')
    if unscoped: unknown('source.harness_model_scope_unknown', '型号字段已保留，但用途或主请求与响应配对不完整。', [d['record_id'] for d in unscoped])
    if requests and not any(d['scope']=='response' for d in main):
        unknown('source.harness_response_missing','已读取主请求型号，但没有可见的主响应型号字段。',[requests[-1]['record_id']])
    visible=declarations if len(declarations)<=200 else declarations[:100]+declarations[-100:]
    return {'schema':SCHEMA,'total':len(declarations),'entries':visible,
            'display_omitted':max(0,len(declarations)-200),'all_declarations_analyzed':True,
            'latest_main_request_model':latest_request['model'] if latest_request else None,
            'identity_authenticated':False}


def describe(code, value):
    value = value if isinstance(value, dict) else {}
    def label(key):
        raw = value.get(key)
        if isinstance(raw, list): return '、'.join(str(x)[:160] for x in raw[:8])
        return str(raw or '未记录')[:160]
    if code == 'source.harness_model_difference':
        return '同一可见轮次的请求声明为「'+label('requested')+'」，响应条目标注「'+label('reported')+'」。'
    if code == 'source.harness_model_change':
        return '主调用型号记录从「'+label('from')+'」变为「'+label('to')+'」。'
    if code == 'source.harness_model_consistent':
        return '可配对轮次内的请求和响应条目均标注「'+label('model')+'」；仅核对本地声明。'
    if code == 'source.harness_default_difference':
        return '会话默认型号为「'+label('session_default')+'」，最近轮次请求标注「'+label('latest_request')+'」。'
    if code == 'source.comparison_target_difference':
        return '本次比较目标为「'+label('comparison_target')+'」，日志最近主请求标注「'+label('latest_recorded_request')+'」。'
    if code in {'source.harness_multiple_models_in_turn','source.harness_unbound_models'}:
        return '记录中出现多个型号：「'+label('models')+'」；需要结合调用归属查看。'
    if code == 'source.harness_model_observed':
        owners={'main':'主会话','child':'子任务','compaction':'压缩任务','unknown':'归属未明'}
        return owners.get(value.get('owner'),'归属未明')+'的结构化型号字段：'+label('model')+'。'
    return ''
