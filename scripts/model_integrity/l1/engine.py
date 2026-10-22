"""Conservative, offline analysis of visible session observations.

This first internal runtime extracts source declarations, tool/result evidence,
usage arithmetic and capture limits. It deliberately does not estimate model
identity, recover hidden reasoning, execute artifacts, or consume bank gold.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import PurePosixPath
import re
from typing import Any

# Reuse the existing command tokenizer and explicit test-command recognition;
# don't reuse M10's old exit-code-only success or tool-count quality score.
from scripts.model_integrity.m10_features import command_segments, is_other_test, is_documented_test

INPUT_SCHEMA = 'tokenclock-l1-observation/v1'
OUTPUT_SCHEMA = 'tokenclock-l1-assessment/v1'
KNOWN_KINDS = {'message','model_request','model_response','billing','tool_call','tool_result',
               'artifact_snapshot','usage','stream_delta','gap','metadata'}
MAX_RECORDS = 100000
MAX_TEXT = 8 * 1024 * 1024


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def text(value: Any) -> str:
    if not isinstance(value, str):
        return ''
    if len(value) > MAX_TEXT:
        raise ValueError('record text exceeds 8 MiB; select a smaller explicit session scope')
    return value


def number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def model_key(value: Any) -> str | None:
    # Keep model snapshot/version suffixes; no broad display normalizer here.
    return value.strip().casefold() if isinstance(value, str) and value.strip() else None


def _arguments(record):
    value = record['data'].get('arguments', {})
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (ValueError, TypeError):
            value = {'raw': value}
    return value if isinstance(value, dict) else {}


def _command(record):
    args = _arguments(record)
    return text(args.get('cmd', args.get('command', '')))


def _name(record):
    return str(record['data'].get('name', '')).casefold().rsplit('.', 1)[-1]


def _is_test(call, context):
    command = _command(call)
    if _name(call) in {'run_tests','run_test','run_checks','test'}:
        return True
    expected = context.get('test_command')
    if isinstance(expected, list) and expected and all(isinstance(x, str) for x in expected):
        if is_documented_test(command, expected):
            return True
    if is_other_test(command):
        return True
    for words in command_segments(command):
        if not words:
            continue
        words=list(words)
        while words and (words[0]=='env' or re.fullmatch(r'[A-Za-z_]\w*=.*',words[0])):
            words.pop(0)
        if not words:continue
        executable = PurePosixPath(words[0]).name
        if re.fullmatch(r'python(?:\d+(?:\.\d+)*)?',executable):
            args=words[1:]; index=0
            while index<len(args):
                arg=args[index]
                if arg=='-c' or arg=='-':break  # inline code is not a named test script
                if arg=='-m':
                    if index+1<len(args) and args[index+1] in {'pytest','unittest'}:return True
                    break
                if arg in {'-W','-X'}:
                    index+=2;continue
                if arg=='--':
                    index+=1
                    if index>=len(args):break
                    arg=args[index]
                elif arg.startswith('-'):
                    index+=1;continue
                script=PurePosixPath(arg).name
                if re.fullmatch(r'(?:test[^/]*|[^/]*_test|run_(?:checks?|tests?)(?:_[^/]*)?|check[^/]*|verify[^/]*)\.py',script):return True
                break
        if executable == 'swift' and len(words)>1 and words[1]=='test':
            return True
    return False


def _test_status(stdout, exit_code):
    """Only classify linked test execution. Negations/examples don't suffice."""
    fail = bool(re.search(r'(?im)^\s*(?:FAIL(?:ED)?(?:\s*[:(]|\s+[\w/])|FAILED\b|ERROR:\s|AssertionError\b)', stdout))
    fail |= bool(re.search(r'(?im)(?<![\d-])[1-9]\d*\s+(?:failed|failures?|errors?)\b', stdout))
    fail |= bool(re.search(r'(?im)^\s*(?:失败|错误)\s*[:：]\s*[1-9]\d*', stdout))
    fail |= bool(re.search(r'(?im)^\s*SELFCHECK\s+FAIL\b',stdout))
    if number(exit_code) and exit_code != 0:
        fail = True
    if isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code < 0:
        fail = True
    passed = bool(re.search(r'(?im)^\s*OK\s*$|\b[1-9]\d*\s+passed\b|^\s*(?:All tests passed|Tests passed)\b', stdout))
    if fail:
        return 'fail'
    if passed or (type(exit_code) is int and exit_code == 0):
        return 'pass'
    return None


def _visible_tool_output(raw):
    """Unwrap a captured tool result, without interpreting or executing code."""
    try: value=json.loads(raw)
    except (ValueError,TypeError):return raw
    if isinstance(value,dict) and any(isinstance(value.get(k),str) for k in ('stdout','stderr')):
        return '\n'.join(value[k] for k in ('stdout','stderr') if isinstance(value.get(k),str))
    return raw


def _paths(call):
    args = _arguments(call)
    paths = [args[k] for k in ('path','filePath','file_path','target') if isinstance(args.get(k), str)]
    patch = args.get('patchText', args.get('patch', args.get('input','')))
    if isinstance(patch, str):
        paths += re.findall(r'^\*\*\* (?:Update|Add|Delete) File: (.+)$', patch, re.M)
        paths += re.findall(r'^\+\+\+ (?:b/)?([^\n]+)$', patch, re.M)
    return sorted(set(paths))


def _path_kind(path):
    p = str(path).replace('\\','/').casefold()
    base = p.rsplit('/',1)[-1]
    if '/tests/' in '/'+p or base.startswith(('test_', 'test.','selftest')) or base.endswith(('_test.py','.test.js','.spec.ts')):
        return 'test'
    if base.endswith(('.md','.rst','.txt')):
        return 'documentation'
    return 'other_or_production'


def _actor(call, result):
    # A role named tool is the messenger, not necessarily the acting model.
    explicit = result.get('role')
    if explicit in {'evaluator','user','child'}:
        return explicit
    parent = call.get('role') if call else None
    if parent in {'assistant','evaluator','user','child'}:
        return parent
    return 'unknown'


def _same_scope(a,b):
    return all(not (a.get(k) and b.get(k) and a[k]!=b[k]) for k in ('generation_id','stage'))


def _claims_test_success(body):
    prose = re.sub(r'```[\s\S]*?```','',body)
    prose = re.sub(r'"[^"\n]*"|“[^”\n]*”|‘[^’\n]*’|`[^`\n]*`|\x27[^\x27\n]*\x27','',prose)
    for sentence in re.split(r'(?<=[。.!?！？])\s*|\n',prose):
        if sentence.lstrip().startswith('>'): continue
        if re.search(r'(?i)\b(?:if|unless|whether|would|could|might|should|hypothetical|example|user (?:wrote|said)|logs? (?:say|said))\b|如果|假如|假设|若|是否|未运行|没有运行|尚未|用户(?:说|写)|例如|示例',sentence): continue
        if re.search(r'(?i)\b(?:not|never|no)\b.{0,20}\b(?:tests? passed|all tests|ran|run|tested)\b',sentence): continue
        if re.search(r'(?i)(?:我已|已经|已)(?:经)?(?:运行|执行|完成|通过).{0,10}(?:测试|验证)|(?:全部|所有)测试(?:均|已|全部|都|均已|都已)?通过(?:了)?|\b(?:I (?:have )?(?:ran|run)|I tested|all tests (?:have )?passed|tests passed)\b',sentence): return True
    return False


def analyze(document: dict, comparison_model: str | None = None) -> dict:
    if not isinstance(document, dict) or document.get('schema') != INPUT_SCHEMA:
        raise ValueError('expected tokenclock-l1-observation/v1')
    canonical(document)  # reject NaN, infinities and unserializable injected objects
    original = document.get('records')
    if not isinstance(original, list) or len(original) > MAX_RECORDS:
        raise ValueError('records must be an array of at most 100000 events')
    context = document.get('context') if isinstance(document.get('context'), dict) else {}
    source = document.get('source') if isinstance(document.get('source'), dict) else {}
    facts, unknowns = [], []
    used, fact_seen, unknown_seen = set(), set(), set()

    def add(code, value, evidence=(), dimension='服务处理', group='G-API', actor=None, generation=None, stage=None):
        evidence = list(dict.fromkeys(str(x) for x in evidence))
        key = canonical([code,value,evidence,actor,generation,stage])
        if key in fact_seen:
            return
        fact_seen.add(key)
        fact = {'id':'f-'+fingerprint(key)[:16], 'code':code,'value':value,'evidence':evidence,
                'dimension':dimension,'group':group}
        if actor is not None: fact['actor']=actor
        if generation is not None: fact['generation_id']=generation
        if stage is not None: fact['stage']=stage
        facts.append(fact)
        used.update(x for x in evidence if not x.startswith('/'))

    def unknown(code, reason, evidence=()):
        evidence = list(dict.fromkeys(str(x) for x in evidence))
        key = canonical([code,reason,evidence])
        if key not in unknown_seen:
            unknown_seen.add(key)
            unknowns.append({'code':code,'reason':reason,'evidence':evidence})

    records, by_identity = [], defaultdict(dict)
    collisions = set()
    malformed = 0
    for ordinal, raw in enumerate(original):
        if not isinstance(raw, dict) or not isinstance(raw.get('data'), dict) or not isinstance(raw.get('kind'), str):
            malformed += 1
            continue
        r = dict(raw)
        r['data'] = dict(raw['data'])
        identity = str(raw.get('id') or f'local-record-{ordinal}')
        # seq may differ between overlapping exports. Same native identity +
        # payload is one event; changed payload must not be silently discarded.
        payload = {k:v for k,v in raw.items() if k not in {'seq','source_pointer','pointer'}}
        digest = fingerprint(payload)
        if digest in by_identity[identity]:
            continue
        if by_identity[identity]:
            collisions.add(identity)
        by_identity[identity][digest] = len(records)
        r['id'] = identity if len(by_identity[identity])==1 else identity+'~'+digest[:10]
        r['_native_id'] = identity
        r['_order'] = ordinal
        r['role'] = r.get('role') if r.get('role') in {'user','assistant','tool','system','evaluator','child','unknown'} else 'unknown'
        # Preserve supplied order. seq is data; sorting attacker-controlled seq
        # could turn a pre-change test into post-change verification.
        records.append(r)
    evidence_ids = [r['id'] for r in records]
    add('capture.record_count',len(records),evidence_ids,group='G-PROVENANCE')
    add('capture.role_counts',dict(sorted(Counter(r['role'] for r in records).items())),evidence_ids,group='G-PROVENANCE')
    if malformed:
        unknown('capture.malformed_records',f'{malformed} records could not be interpreted')
    if collisions:
        add('source.binding_collision',sorted(collisions),[r['id'] for r in records if r['_native_id'] in collisions],
            dimension='来源声明',group='G-ROUTE')
        unknown('capture.order_or_binding_ambiguous','Duplicate event identities carry different payloads; dependent bindings are ambiguous')
    gaps = [r for r in records if r['kind']=='gap']
    complete = context.get('capture_complete') if type(context.get('capture_complete')) is bool else None
    if gaps or complete is False:
        unknown('capture.gap','Captured history is incomplete; later recovery and missing events cannot be inferred',[r['id'] for r in gaps])
        complete = False
    if complete is None:
        unknown('capture.completeness_unknown','The source does not establish complete session coverage')

    if isinstance(context.get('display_model'), str):
        add('source.display_model',context['display_model'],['/context/display_model'],dimension='来源声明',group='G-ROUTE')
    if isinstance(context.get('requested_model'),str):
        add('source.context_model_label',context['requested_model'],['/context/requested_model'],dimension='来源声明',group='G-ROUTE')

    claims = [r for r in records if r['kind'] in {'model_request','model_response','billing'} and model_key(r['data'].get('model'))]
    request_groups = defaultdict(list)
    for r in claims:
        rid = r.get('request_id')
        if isinstance(rid,str) and rid.strip(): request_groups[rid].append(r)
    paired_ids = set()
    for rid, rs in request_groups.items():
        reqs = [r for r in rs if r['kind']=='model_request']
        reps = [r for r in rs if r['kind']=='model_response']
        if len({model_key(r['data']['model']) for r in reqs})>1 or len({model_key(r['data']['model']) for r in reps})>1:
            unknown('source.unbound_model_claims','One request ID has contradictory duplicate model records',[r['id'] for r in rs])
            continue
        if any(r['_native_id'] in collisions for r in rs):
            unknown('source.unbound_model_claims','Conflicting native event IDs make source binding ambiguous',[r['id'] for r in rs])
            continue
        if reqs and reps:
            req, rep = reqs[0], reps[0]
            # Different observed generation IDs are a scope conflict even if a
            # request string happens to match.
            rg, pg = req.get('generation_id'), rep.get('generation_id')
            if rg and pg and rg != pg:
                add('source.out_of_scope_claim',rid,[req['id'],rep['id']],dimension='来源声明',group='G-ROUTE')
                unknown('source.unbound_model_claims','Request and response belong to different generations',[req['id'],rep['id']])
                continue
            paired_ids.update(r['id'] for r in reqs+reps)
            code = 'source.model_claim_consistent' if model_key(req['data']['model'])==model_key(rep['data']['model']) else 'source.model_claim_difference'
            add(code,{'requested':req['data']['model'],'reported':rep['data']['model'],'request_id':rid},
                [req['id'],rep['id']],dimension='来源声明',group='G-ROUTE',generation=rg or pg)
            for bill in [r for r in rs if r['kind']=='billing']:
                if bill.get('generation_id') and pg and bill['generation_id']!=pg:
                    add('source.out_of_scope_claim',rid,[bill['id']],dimension='来源声明',group='G-ROUTE')
                elif model_key(bill['data']['model'])!=model_key(rep['data']['model']):
                    add('source.billing_claim_difference',{'reported':rep['data']['model'],'billed':bill['data']['model'],'request_id':rid},
                        [rep['id'],bill['id']],dimension='来源声明',group='G-ROUTE')
        elif any(r['kind']=='billing' for r in rs):
            add('source.out_of_scope_claim',rid,[r['id'] for r in rs],dimension='来源声明',group='G-ROUTE')
    unbound = [r for r in claims if r['kind']!='billing' and r['id'] not in paired_ids]
    if len(unbound)>1:
        unknown('source.unbound_model_claims','Visible model declarations lack a unique matched request/response binding',[r['id'] for r in unbound])
    provider_history = [r for r in claims if r['kind']=='model_response' and isinstance(r['data'].get('provider'),str)]
    for prev, cur in zip(provider_history,provider_history[1:]):
        if model_key(prev['data']['model'])==model_key(cur['data']['model']) and prev['data']['provider']!=cur['data']['provider']:
            add('source.provider_change',{'from':prev['data']['provider'],'to':cur['data']['provider'],'model':cur['data']['model']},
                [prev['id'],cur['id']],group='G-ROUTE')

    calls = defaultdict(list)
    for r in records:
        if r['kind']=='tool_call' and r.get('call_id'):
            calls[str(r['call_id'])].append(r)
    test_events, edits, definitions, completion_claims = [], [], [], []
    snapshots={}
    for r in records:
        kind, data, role = r['kind'], r['data'], r['role']
        if kind == 'message':
            body = text(data.get('text',''))
            if role == 'user' and re.search(r'(?i)(?:请|要求|务必|只需|只用|用).{0,12}(?:简洁|简短|详尽|详细|英文|中文)|\b(?:be concise|be brief|answer in English|answer in Chinese|in detail)\b',body):
                add('behavior.style_instructed',True,[r['id']],dimension='行为偏好',group='G-CONDITION')
            if role == 'assistant':
                add('delivery.assistant_response_observed',{'characters':len(body)},[r['id']],dimension='能力与交付',group='G-TASK',actor=role)
                if re.search(r'(?m)^\s*(?:def\s+(?:test\w*|selftest|verify)\s*\(|function\s+(?:test\w*|selftest|verify)\s*\()', body):
                    definitions.append(r)
                    add('process.test_definition_present',True,[r['id']],dimension='工作轨迹',group='G-TASK',actor=role)
                if _claims_test_success(body):
                    completion_claims.append(r)
        elif kind == 'tool_call':
            name = _name(r)
            if name in {'write','edit','apply_patch','patch','multiedit','write_file','edit_file'}:
                for path in _paths(r):
                    add('process.edit_path',{'path':path,'kind':_path_kind(path)},[r['id']],dimension='工作轨迹',group='G-TRACE',actor=role,stage=r.get('stage'))
                    edits.append((r,path))
                    targets = context.get('target_paths')
                    if isinstance(targets,list) and targets and not any(path==p or (isinstance(p,str) and p.endswith('/') and path.startswith(p)) for p in targets):
                        add('process.edit_outside_explicit_scope',path,[r['id']],dimension='能力与交付',group='G-TASK',actor=role)
        elif kind == 'tool_result':
            candidates = calls.get(str(r.get('call_id','')),[])
            # Require a prior unique call with compatible generation/actor scope.
            candidates = [c for c in candidates if c['_order'] < r['_order'] and
                          not (c.get('generation_id') and r.get('generation_id') and c['generation_id']!=r['generation_id'])]
            if len(candidates)!=1 or any(c['_native_id'] in collisions for c in candidates):
                unknown('process.tool_binding_unknown','Tool result has no unique earlier compatible call',[r['id']])
                continue
            call=candidates[0]
            actor=_actor(call,r)
            body=_visible_tool_output(text(data.get('text','')))
            if _is_test(call,context):
                status = _test_status(body,data.get('exit_code'))
                if status:
                    add('process.test_result',status,[call['id'],r['id']],dimension='工作轨迹',group='G-TASK',actor=actor,
                        generation=r.get('generation_id') or call.get('generation_id'),stage=r.get('stage',call.get('stage')))
                    test_events.append((r,call,actor,status))
                    if status=='fail' and type(data.get('exit_code')) is int and data['exit_code']==0:
                        add('process.test_exit_mismatch',True,[r['id']],dimension='工作轨迹',group='G-TASK',actor=actor)
                else:
                    unknown('process.test_result_unknown','A test command was observed but a conclusive result is missing',[call['id'],r['id']])
            if _name(call) in {'read','read_file','view_file'}:
                args=_arguments(call)
                path=next((args[k] for k in ('path','filePath','file_path') if isinstance(args.get(k),str)),None)
                if path:
                    truncated=bool(data.get('truncated') is True or re.search(r'(?i)output (?:was )?truncated|\[truncated\]|truncated output|截断',body))
                    value={'path':path,'returned_characters':len(body),'truncated':truncated}
                    if isinstance(data.get('visible_start'),int): value['visible_start']=data['visible_start']
                    if isinstance(data.get('visible_end'),int): value['visible_end']=data['visible_end']
                    add('process.read_visible',value,[call['id'],r['id']],dimension='工作轨迹',group='G-TRACE',actor=actor)
                    if truncated: unknown('process.read_coverage_incomplete','Requested file range exceeds the visible returned content',[r['id']])
        elif kind == 'usage':
            _usage(r,add,unknown)
        elif kind == 'artifact_snapshot':
            path=data.get('path'); content=data.get('content')
            if isinstance(path,str) and isinstance(content,str):
                key=(path,r.get('stage')); previous=snapshots.get(key)
                if previous is not None and previous['data'].get('content')!=content:
                    add('process.artifact_content_changed',path,[previous['id'],r['id']],dimension='能力与交付',group='G-TASK')
                    edits.append((r,path))
                snapshots[key]=r
        elif kind == 'gap':
            pass

    for r in completion_claims:
        # Tests by evaluators, users, child agents do not substantiate the
        # parent assistant's claim of having executed tests itself.
        supported=[t for t in test_events if t[2]=='assistant' and t[3]=='pass' and t[0]['_order']<r['_order'] and
                   _same_scope(t[0],r) and
                   not any(e['_order']>t[0]['_order'] and e['_order']<r['_order'] and _same_scope(e,r) and _path_kind(p)=='other_or_production' for e,p in edits)]
        later_fail=[t for t in test_events if t[2]=='assistant' and t[3]=='fail' and t[0]['_order']<r['_order'] and _same_scope(t[0],r)]
        if not supported or (later_fail and later_fail[-1][0]['_order']>supported[-1][0]['_order']):
            add('process.unverified_completion_claim',True,[r['id']],dimension='能力与交付',group='G-TASK',actor='assistant')
    for r,path in edits:
        if _path_kind(path)!='other_or_production' or (r['role']!='assistant' and r['kind']!='artifact_snapshot'): continue
        prior=[t for t in test_events if t[0]['_order']<r['_order'] and t[2]=='assistant' and _same_scope(t[0],r)]
        after=[t for t in test_events if t[0]['_order']>r['_order'] and t[2]=='assistant' and t[3]=='pass' and _same_scope(t[0],r)]
        if prior and not after:
            add('process.latest_change_unverified',True,[r['id']],dimension='能力与交付',group='G-TASK',actor='assistant')
    if definitions and not any(t[2]=='assistant' for t in test_events):
        unknown('process.test_execution_not_observed','Test definitions were supplied; no supported target test execution was observed',[r['id'] for r in definitions])

    stream = [r for r in records if r['kind']=='stream_delta']
    if stream:
        _streams(stream,add,unknown)
    unsupported=sorted({r['kind'] for r in records if r['kind'] not in KNOWN_KINDS})
    if unsupported: unknown('capture.unsupported_record_kinds','Some record kinds were retained without interpretation: '+', '.join(unsupported))
    # This version has no natural-language gold or capability tier classifier.
    unknown('reference.comparison_not_calibrated','No model-identity or capability-tier estimate is produced by this deterministic internal version')
    unknown('delivery.semantic_review_not_implemented','General task fulfillment, evidence revision and natural-language preference extraction are not fully automated')
    codes={f['code'] for f in facts}
    source_status='declaration_difference' if codes & {'source.model_claim_difference','source.billing_claim_difference'} else 'consistent_declarations' if 'source.model_claim_consistent' in codes else 'insufficient_binding'
    visible_fail=any(f['code']=='process.test_result' and f['value']=='fail' for f in facts)
    issues=visible_fail or bool(codes & {'process.edit_outside_explicit_scope','process.unverified_completion_claim','process.latest_change_unverified'})
    quality_status='visible_issue_or_unverified_claim' if issues else 'limited_observations'
    headline='发现可定位的声明差异' if source_status=='declaration_difference' else '发现可见的验证问题或待核实声明' if issues else '已提取可见记录，当前仅提供局部观察'
    return {'schema':OUTPUT_SCHEMA,'input_id':str(document.get('id','')),
            'scope':{'synthetic':source.get('kind')=='synthetic_fixture','source_format':str(source.get('format','unknown')),'capture_complete':complete,'comparison_model':comparison_model},
            'record_index':{r['id']:{'pointer':'/records/'+str(r['_order']),'native_id':r['_native_id']} for r in records},
            'summary':{'headline':headline,'source_status':source_status,'quality_status':quality_status,'identity_status':'not_estimated'},
            'facts':facts,'unknowns':unknowns,
            'coverage':{'records_total':len(original),'records_unique':len(records),'records_used':len(used & set(evidence_ids)),
                        'unsupported_kinds':unsupported,'modules':{'S01':'partial','P01':'partial','P02':'partial','P03':'partial',
                        'P04':'limited','Q01':'limited','R01':'partial','T02':'partial','T03':'partial','I03':'partial',
                        'B01-B04':'not_implemented','P05':'not_implemented','T01':'not_implemented','T05':'not_implemented'}}}


def _usage(r, add, unknown):
    d=r['data']; ev=[r['id']]
    if 'reasoning_tokens' in d:
        add('resource.reasoning_reported',d['reasoning_tokens'],ev,dimension='资源投入',group='G-RESOURCE')
    if number(d.get('elapsed_seconds')):
        add('resource.elapsed_seconds',d['elapsed_seconds'],ev,dimension='资源投入',group='G-RESOURCE')
    schema=d.get('schema','unknown')
    required={'anthropic_messages':['input_tokens','output_tokens','cache_read_tokens','cache_write_tokens'],
              'openai_responses':['input_tokens','output_tokens','total_tokens'],
              'deepseek_chat':['input_tokens','output_tokens','total_tokens'],
              'additive_fixture':['input_tokens','output_tokens','reasoning_tokens','cache_read_tokens','cache_write_tokens','total_tokens']}.get(schema)
    if not required:
        unknown('resource.usage_missing','Usage schema is unknown; no cross-schema arithmetic is assumed',ev)
        return
    if any(not number(d.get(k)) for k in required):
        unknown('resource.usage_missing','Missing/null/invalid fields prevent complete usage arithmetic for '+schema,ev)
        return
    problems=[]
    if schema=='additive_fixture':
        expected=sum(d[k] for k in required if k!='total_tokens')
        if expected!=d['total_tokens']:problems.append('total != sum of disjoint fixture fields')
    elif schema in {'openai_responses','deepseek_chat'}:
        if d['input_tokens']+d['output_tokens']!=d['total_tokens']:problems.append('total != input + output')
        if number(d.get('cache_read_tokens')) and d['cache_read_tokens']>d['input_tokens']:problems.append('cached input exceeds total input')
        if number(d.get('reasoning_tokens')) and d['reasoning_tokens']>d['output_tokens']:problems.append('reasoning subset exceeds output')
        if schema=='deepseek_chat' and number(d.get('cache_miss_tokens')) and number(d.get('cache_read_tokens')) and d['cache_miss_tokens']+d['cache_read_tokens']!=d['input_tokens']:
            problems.append('cache hit + miss != input')
    else:
        # Anthropic does not require a total_tokens field. If an adapter adds a
        # total, test only its explicitly disjoint fresh+cache+output meaning.
        if 'total_tokens' in d:
            if not number(d.get('total_tokens')):
                unknown('resource.usage_missing','Derived total_tokens is unavailable',ev)
                return
            if sum(d[k] for k in required)!=d['total_tokens']:problems.append('derived total != fresh input + cache read + cache write + output')
    add('resource.usage_consistency',not problems,ev,dimension='服务处理',group='G-RESOURCE')
    if problems:add('resource.usage_conflict_details',{'schema':schema,'issues':problems},ev,dimension='服务处理',group='G-RESOURCE')


def _streams(stream,add,unknown):
    elapsed=[r['data'].get('elapsed_seconds') for r in stream]
    ev=[r['id'] for r in stream]
    value={'events':len(stream),'characters':sum(len(text(r['data'].get('text',''))) for r in stream),
           'channels':dict(sorted(Counter(str(r['data'].get('channel','unknown')) for r in stream).items()))}
    if all(number(t) for t in elapsed) and all(a<=b for a,b in zip(elapsed,elapsed[1:])):
        value['first_event_seconds']=elapsed[0]
        value['last_event_seconds']=elapsed[-1]
        gaps=sorted(b-a for a,b in zip(elapsed,elapsed[1:]))
        if gaps:
            value['median_gap_seconds']=gaps[len(gaps)//2]
            value['max_gap_seconds']=gaps[-1]
    else:
        unknown('resource.stream_timing_unknown','Per-event receive times are missing or non-monotonic',ev)
    add('resource.stream_observed',value,ev,dimension='服务处理',group='G-STREAM')
