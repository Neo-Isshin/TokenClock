"""Observe recorded service behavior without guessing actual backend identity."""
from __future__ import annotations
import hashlib
import json
import math
import statistics
from collections import defaultdict

ROUTE_FIELDS = ('model', 'provider', 'route', 'fallback', 'fallback_model', 'routed_model', 'upstream_model', 'system_fingerprint')


def _number(value):
    return type(value) in {int, float} and math.isfinite(value) and value >= 0


def _state(mapping, key):
    return {'state': 'missing'} if key not in mapping else {'state': 'null' if mapping[key] is None else 'reported', 'value': mapping[key]}


def _text_delta(event):
    data = event.get('data', event.get('event', event))
    if not isinstance(data, dict): return None, None
    if isinstance(data.get('choices'), list) and data['choices']:
        delta = data['choices'][0].get('delta', {})
        if isinstance(delta.get('content'), str): return delta['content'], 'content'
        if isinstance(delta.get('reasoning_content'), str): return delta['reasoning_content'], 'reported_reasoning_text'
    delta = data.get('delta')
    if isinstance(delta, str): return delta, str(data.get('type', event.get('type', 'unknown')))
    if isinstance(delta, dict):
        for key in ('text', 'thinking'):
            if isinstance(delta.get(key), str): return delta[key], 'content' if key == 'text' else 'reported_thinking_text'
    if isinstance(data.get('text'), str): return data['text'], str(data.get('channel', 'content'))
    return None, None


def analyze(records, metadata=None):
    metadata = metadata or {}
    if not isinstance(records, (list, dict)):
        raise ValueError('Expected captured records or a request/response envelope')
    captured = records if isinstance(records, dict) else {'records': records}
    source_records = captured.get('records', [])
    request = captured.get('request', {})
    response = captured.get('response', {})
    events = list(captured.get('events', [])) if isinstance(captured.get('events', []), list) else []
    request = request if isinstance(request, dict) else {}
    response = response if isinstance(response, dict) else {}
    checks, observations, limits = [], [], []
    def check(identifier, status, observed, expected=None, dimension='服务处理', group='service:recording', evidence=None, reason=None):
        row = {'id': identifier, 'status': status, 'observed': observed, 'dimension': dimension, 'group': group,
               'evidence': evidence or [{'pointer': '/', 'note': 'Supplied capture only; no source.refs dereference'}], 'mandatory': False}
        if expected is not None: row['expected'] = expected
        if reason: row['reason'] = reason
        checks.append(row)
    model_rows, usage_rows = [], []
    if request or response:
        model_rows.append({'request': request, 'response': response, 'evidence': [{'pointer': '/request'}, {'pointer': '/response'}],
                           'binding': 'same_supplied_capture_envelope', 'session_id': captured.get('session_id', metadata.get('session_id'))})
        if isinstance(response.get('usage'), dict): usage_rows.append((response['usage'], [{'pointer': '/response/usage'}]))
        elif isinstance(captured.get('usage'), dict): usage_rows.append((captured['usage'], [{'pointer': '/usage'}]))
    if isinstance(source_records, list):
        groups = {}
        for i, record in enumerate(source_records):
            if not isinstance(record, dict): continue
            if 'requested_model' in record or 'response_model' in record:
                ev = [{'pointer': '/records/' + str(i), 'record_id': record.get('client_request_id')}]
                req = {'model': record['requested_model']} if 'requested_model' in record else {}
                rep = {'model': record['response_model']} if 'response_model' in record else {}
                responses_by_request = metadata.get('responses_by_request', {})
                raw_response = responses_by_request.get(record.get('client_request_id'), responses_by_request.get(str(record.get('number')), {})) if isinstance(responses_by_request, dict) else {}
                if isinstance(raw_response, dict):
                    for key in ROUTE_FIELDS:
                        if key in raw_response: rep[key] = raw_response[key]
                for key in ROUTE_FIELDS:
                    if key != 'model' and key in record: rep[key] = record[key]
                for source_key, target_key in [('finish_reason', 'finish_reason'), ('provider_response_id', 'id')]:
                    if source_key in record: rep[target_key] = record[source_key]
                model_rows.append({'request': req, 'response': rep, 'request_id': record.get('client_request_id'),
                                   'binding': 'same_controller_call_record_not_provider_authentication', 'evidence': ev,
                                   'session_id': record.get('session_id', metadata.get('session_id'))})
                observed_usage=record.get('usage',record.get('partial_usage'))
                if isinstance(observed_usage, dict):
                    usage = dict(observed_usage)
                    usage.setdefault('schema', {'messages': 'anthropic_messages', 'responses': 'openai_responses', 'chat_completions': 'openai_chat', 'chat': 'openai_chat'}.get(record.get('api_format'), 'unknown'))
                    usage_rows.append((usage, ev))
                headers = record.get('headers', {})
                if isinstance(headers, dict):
                    observations.append({'type': 'visible_response_headers', 'fields': {k: v for k, v in headers.items() if k.lower() in {'request-id', 'x-request-id', 'x-model', 'openrouter-generation-id', 'content-type'}}, 'evidence': ev})
                observations.append({'type': 'controller_call_status', 'status': record.get('status'), 'source_kind': record.get('source_kind'),
                                     'recorded_source_kind': record.get('recorded_source_kind'),
                                     'record_origin_label': record.get('record_origin_label'), 'transport_mode': record.get('transport_mode'),
                                     'dispatched': _state(record,'dispatched'), 'usage_scope': record.get('usage_scope','unspecified'),
                                     'elapsed_seconds': _state(record, 'elapsed_seconds'),
                                     'timing_scope': 'replay_execution_wall_not_original_model_latency' if record.get('transport_mode') == 'replay' else 'client_request_wall',
                                     'cost_fields': {k: _state(record, k) for k in ('reserved_usd','reported_cost_usd','estimated_cost_usd','pending_reserved_usd','reservation_released','actual_cost_usd')}, 'evidence': ev})
                events_by_request = metadata.get('events_by_request', {})
                if isinstance(events_by_request, dict):
                    selected = events_by_request.get(record.get('client_request_id'), events_by_request.get(str(record.get('number')), []))
                    if isinstance(selected, list):
                        events.extend([{**e, 'request_id': record.get('client_request_id')} for e in selected if isinstance(e, dict)])
                continue
            kind = record.get('kind', record.get('type'))
            data = record.get('data', {})
            data = data if isinstance(data, dict) else {}
            evidence = [{'pointer': '/records/' + str(i), 'record_id': record.get('id')}]
            if kind in {'model_request', 'model_response', 'request', 'response'}:
                rid = record.get('request_id')
                if not isinstance(rid, str) or not rid.strip():
                    observations.append({'type': 'unbound_model_declaration', 'fields': {k: _state(data, k) for k in ROUTE_FIELDS}, 'evidence': evidence})
                    continue
                entry = groups.setdefault(rid, {'requests': [], 'responses': [], 'evidence': [], 'session_id': record.get('session_id', metadata.get('session_id'))})
                entry['requests' if kind in {'model_request', 'request'} else 'responses'].append((data, record.get('generation_id')))
                entry['evidence'] += evidence
            elif kind == 'usage': usage_rows.append((data, evidence))
            elif kind in {'stream_delta', 'sse', 'stream_event'}: events.append(record)
            elif kind in {'error', 'request_failed'}:
                observations.append({'type': 'request_failure', 'error_type': data.get('type', data.get('error_type', 'unknown')), 'evidence': evidence})
        for rid, group in groups.items():
            if len(group['requests']) == 1 and len(group['responses']) == 1:
                req, rg = group['requests'][0]; rep, pg = group['responses'][0]
                if rg and pg and rg != pg:
                    check('binding:' + str(rid), 'unknown', {'request_generation': rg, 'response_generation': pg}, reason='Same request string but incompatible generation scopes', evidence=group['evidence'])
                    continue
                model_rows.append({'request': req, 'response': rep, 'request_id': rid,
                                   'evidence': group['evidence'], 'binding': 'same_visible_request_id', 'session_id': group['session_id']})
            else:
                check('binding:' + str(rid), 'unknown', {'requests': len(group['requests']), 'responses': len(group['responses'])}, reason='No unique visible request/response pair', evidence=group['evidence'])
    for i, row in enumerate(model_rows):
        req, rep = row['request'], row['response']
        wanted, returned = req.get('model'), rep.get('model')
        observations.append({'type': 'source_fields', 'requested_model': _state(req, 'model'),
                             'response_fields': {k: _state(rep, k) for k in ROUTE_FIELDS},
                             'request_id': row.get('request_id', captured.get('request_id')),
                             'response_id': rep.get('id'), 'binding': row['binding'], 'evidence': row['evidence']})
        state = 'unknown' if not isinstance(wanted, str) or not isinstance(returned, str) else 'pass' if wanted == returned else 'fail'
        check('model_declaration:' + str(i), state, {'requested': wanted, 'reported': returned}, dimension='来源声明', group='source:route', evidence=row['evidence'],
              reason='Visible declaration comparison only; aliases, versions, gateway mapping and same-model supplier changes are alternative explanations.')
        finish = rep.get('finish_reason', rep.get('stop_reason'))
        if finish is None and isinstance(rep.get('choices'), list) and rep['choices']:
            finish = rep['choices'][0].get('finish_reason')
        incomplete = rep.get('incomplete_details')
        if finish is None and isinstance(incomplete, dict): finish = incomplete.get('reason')
        if finish is None and rep.get('status') in {'completed', 'incomplete', 'failed'}: finish = rep['status']
        observations.append({'type': 'completion', 'finish_reason': finish, 'state': 'missing' if finish is None else 'reported',
                             'limited': finish in {'length', 'max_tokens', 'max_output_tokens', 'token_limit', 'incomplete'}, 'evidence': row['evidence']})
    previous = {}
    for row in model_rows:
        session = row.get('session_id')
        if not session: continue
        fields = {k: row['response'][k] for k in ROUTE_FIELDS if k in row['response']}
        prior = previous.get(session)
        if prior:
            changed = {k: {'before': prior[k], 'after': fields[k]} for k in prior.keys() & fields.keys() if prior[k] != fields[k]}
            if changed:
                observations.append({'type': 'session_visible_field_change', 'session_id': session, 'changes': changed,
                                     'meaning': 'Observed within supplied session records; not proof of exact backend or cross-day stability.', 'evidence': row['evidence']})
        previous[session] = fields
    for i, (raw, evidence) in enumerate(usage_rows):
        schema = raw.get('schema', metadata.get('usage_schema'))
        if not schema:
            if 'cache_creation_input_tokens' in raw or 'cache_read_input_tokens' in raw: schema = 'anthropic_messages'
            elif 'prompt_cache_hit_tokens' in raw: schema = 'deepseek_chat'
            elif 'prompt_tokens' in raw and 'completion_tokens' in raw: schema = 'openai_chat'
            elif 'input_tokens_details' in raw or 'output_tokens_details' in raw: schema = 'openai_responses'
            else: schema = 'unknown'
        inp = raw.get('prompt_tokens', raw.get('input_tokens'))
        out = raw.get('completion_tokens', raw.get('output_tokens'))
        total = raw.get('total_tokens')
        cache = raw.get('cache_read_input_tokens', raw.get('prompt_cache_hit_tokens', raw.get('cache_read_tokens')))
        if cache is None and isinstance(raw.get('input_tokens_details'), dict): cache = raw['input_tokens_details'].get('cached_tokens')
        write = raw.get('cache_creation_input_tokens', raw.get('cache_write_tokens'))
        reasoning = _state(raw, 'reasoning_tokens')
        for detail in ('output_tokens_details', 'completion_tokens_details'):
            if isinstance(raw.get(detail), dict) and 'reasoning_tokens' in raw[detail]: reasoning = _state(raw[detail], 'reasoning_tokens')
        issues = []
        known = False
        token_values = [value for value in (inp, out, total, cache, write) if value is not None]
        if any(type(value) is not int or value < 0 for value in token_values):
            issues.append('invalid_token_count_type_or_sign'); known = True
        elif schema in {'openai_responses', 'openai_chat', 'deepseek_chat'} and all(type(v) is int for v in (inp, out, total)):
            known = True
            if inp + out != total: issues.append('total_not_input_plus_output')
            if cache is not None and cache > inp: issues.append('cache_read_exceeds_input')
            if reasoning['state'] == 'reported' and type(reasoning['value']) is int and reasoning['value'] > out: issues.append('reasoning_subset_exceeds_output')
            miss = raw.get('prompt_cache_miss_tokens', raw.get('cache_miss_tokens'))
            if schema == 'deepseek_chat' and type(miss) is int and type(cache) is int and miss + cache != inp: issues.append('cache_hit_plus_miss_not_input')
        elif schema == 'anthropic_messages' and all(type(v) is int for v in (inp, out, cache, write)):
            known = True
            if total is not None and inp + out + cache + write != total: issues.append('derived_total_not_disjoint_anthropic_fields')
        check('usage:' + str(i), 'fail' if issues else 'pass' if known else 'unknown',
              {'schema': schema, 'input': inp, 'output': out, 'total': total, 'cache_read': cache, 'cache_write': write, 'issues': issues},
              group='resource:usage:' + str(i), evidence=evidence,
              reason='Arithmetic follows the declared native schema. Cache reuse of previous assistant output is allowed by some service mechanisms and is not itself an anomaly.')
        observations.append({'type': 'reasoning_usage_field', **reasoning, 'evidence': evidence,
                             'meaning': 'Reported field only; zero or missing does not establish zero internal reasoning.'})
    stream_groups = defaultdict(list)
    for event in events if isinstance(events, list) else []:
        if not isinstance(event, dict): continue
        delta, channel = _text_delta(event)
        if delta is None: continue
        timestamp = event.get('elapsed_seconds', event.get('received_at', event.get('time')))
        if timestamp is None and isinstance(event.get('data'), dict): timestamp = event['data'].get('elapsed_seconds')
        stream_groups[event.get('request_id', event.get('generation_id', 'unbound'))].append((delta, channel, timestamp))
    for stream_id, parsed in stream_groups.items():
        times = [t for _, _, t in parsed]
        binding_ambiguous = stream_id == 'unbound' and len(model_rows) > 1
        clock_known = not binding_ambiguous and all(_number(t) for t in times)
        monotone = clock_known and all(a <= b for a, b in zip(times, times[1:]))
        observation = {'type': 'client_stream_shape', 'stream_scope_id': stream_id, 'events': len(parsed), 'characters': sum(len(t) for t, _, _ in parsed),
                       'channels': sorted({c for _, c, _ in parsed}), 'timing_available': clock_known,
                       'meaning': 'Client received event boundaries; buffering, network, SDK and flush policies can change shape. Events are not tokens or thinking steps.'}
        if monotone:
            gaps = [b - a for a, b in zip(times, times[1:])]
            observation.update(first_event_seconds=times[0], last_event_seconds=times[-1],
                               median_gap_seconds=statistics.median(gaps) if gaps else None,
                               max_gap_seconds=max(gaps) if gaps else None)
        observations.append(observation)
        check('stream_clock_order:' + str(stream_id), 'pass' if monotone else 'fail' if clock_known else 'unknown', {'events': len(parsed), 'monotonic': monotone if clock_known else None}, group='service:stream:' + str(stream_id), reason='Unknown request binding' if binding_ambiguous else None)
    limits += ['Source claims, service-chain observations and model-specific identity are distinct. No backend identity or fraud probability is computed.',
               'No per-call routing field means no direct routing evidence; fields are not fabricated.',
               'Wall time includes network, queueing, cache, provider and transport effects, not a direct count of reasoning steps.',
               'No real mixed-relay detection rate or model-mixture fraction is known from these engineering records.',
               'A same-model supplier change is not automatically a different model. A distribution change remains a limited observation.']
    return {'schema': 'tokenclock-task-result/v1', 'task_id': 'diagnostics', 'status': 'completed' if any(c['status'] in {'pass', 'fail'} for c in checks) else 'limited',
            'checks': checks, 'observations': observations, 'source': {'kind': metadata.get('source_kind', 'recorded_capture'),
                'sha256': hashlib.sha256(json.dumps(records, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
                'supplemental_input_sha256': {key: hashlib.sha256(json.dumps(metadata[key], ensure_ascii=False, sort_keys=True).encode()).hexdigest()
                                             for key in ('events_by_request', 'responses_by_request') if key in metadata},
                'hash_meaning': 'Integrity of supplied bytes/data, not authentication of a real backend'},
            'execution': {'actor': 'evaluator', 'network_calls': 0, 'target_model_calls': 0}, 'artifacts': [],
            'identity_probability': None, 'mixture_proportion': None, 'limitations': limits}
