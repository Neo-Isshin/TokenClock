"""Real historical tool-process references and bounded current projections.

No model calls, candidate execution, source-path following at runtime or
production-repair inference from file names. Original labels stay literal.
"""
from __future__ import annotations

import ast
from collections import Counter
from copy import deepcopy
import hashlib
from importlib.resources import files
from functools import lru_cache
import json
from pathlib import Path, PurePosixPath
import re
import shlex

SCHEMA='tokenclock-observable-process-profile/v1'
TASK_ID='H03:pipeline'
ORIGIN='deterministic_visible_process_projection'
UNKNOWN={'state':'unknown'}
MAX_EVENTS=10000
DEFINITION={
 'version':'visible-tool-process/v1',
 'task_scope':'Original shared incremental pipeline TASK.md; matched by contract hash, not topic or model label.',
 'actor_scope':'Only target-issued tool calls; simulated/replayed target actions retain their own origin; evaluator-only actions excluded.',
 'metrics':{
  'observed_target_tool_calls':'Recognized target-issued call events, including explicit errors; one call, not call plus result.',
  'observed_read_calls':'Direct read/read_file calls with their own target-call identity; no inference from shell contents.',
  'observed_write_calls':'Direct write/write_file or explicit patch calls; never interpreted as production repairs.',
  'observed_check_calls':'run_checks or an exact fixed task check command; not post-delivery grader activity.',
  'observed_list_calls':'Direct list_files/glob calls.',
  'other_target_calls':'Calls outside the bounded tool mapping, retained as coverage limits.',
  'read_paths_before_first_observed_write':'Different task-relative paths with delivered read text before the first observed write; not understanding or full-session first write.',
  'distinct_observed_write_paths':'Different explicit task-relative write destinations.',
  'writes_after_first_observed_check':'Raw write calls after the first observed check, not production logic changes or repairs.',
  'checks_before_first_observed_write':'Checks before the first observed write; unknown when no write boundary is seen.',
  'rechecks_without_intervening_write':'Adjacent observed checks with no intervening direct write; descriptive, not ineffective rework.',
  'visible_failed_check_calls':'Check feedback containing explicit failures; missing/unknown feedback does not become zero.',
  'nonzero_exit_check_calls':'Explicit nonzero exit values; unknown if any check lacks this field.',
  'selfcheck_failure_label_occurrences':'Anchored SELFCHECK FAIL lines in supplied raw check stdout; summary-only feedback cannot establish absence.'}}


def stable_hash(value):return hashlib.sha256(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()
def sha_bytes(value):return hashlib.sha256(value).hexdigest()
def _read(path):return json.loads(Path(path).read_text(encoding='utf-8'))
def _write(path,value):
 from .common import write_json
 write_json(path,value)

@lru_cache(maxsize=1)
def task_contract():return json.loads(files(__package__).joinpath('resources/h03_pipeline.json').read_text(encoding='utf-8'))
def measurement_contract():return {'task_version':'pipeline-v1','grader_version':'visible-tool-process-v1','definition_sha256':stable_hash(DEFINITION)}

def _json_object(value):
 if isinstance(value,dict):return value
 if isinstance(value,str):
  try:parsed=json.loads(value)
  except (ValueError,RecursionError):return {}
  return parsed if isinstance(parsed,dict) else {}
 return {}

def _arguments(record):return _json_object(record.get('arguments',{}))
def _name(value):return str(value or '').casefold().rsplit('.',1)[-1]
def _relative(value):
 if not isinstance(value,str) or '\\' in value:return None
 normalized=PurePosixPath(value).as_posix()
 declared=list(task_contract()['files'])
 matches=[path for path in declared if normalized==path or normalized.endswith('/'+path)]
 return matches[0] if len(matches)==1 else None

def _category(name,args):
 name=_name(name)
 aliases={'read':'read','read_file':'read','write':'write','write_file':'write','edit':'write','edit_file':'write','apply_patch':'write',
          'glob':'list','list_files':'list','run_checks':'check'}
 if name in aliases:return aliases[name]
 if name in ('bash','shell','exec_command'):
  command=args.get('cmd',args.get('command'))
  if isinstance(command,str):
   try:words=shlex.split(command)
   except ValueError:return 'other'
   if words and PurePosixPath(words[0]).name.startswith('python'):
    if any(word.startswith('-') and word not in ('-B','-E','-s','-I','-S') for word in words[1:]):return 'other'
    tail=[word for word in words[1:] if word not in ('-B','-E','-s','-I','-S')]
    if len(tail)==1 and PurePosixPath(tail[0]).name=='run_tests_in_copy.py':return 'check'
 return 'other'

def _explicit_path(args,output):
 value=args.get('path',args.get('filePath',args.get('file_path')))
 if value is None:value=output.get('written',output.get('path'))
 return _relative(value)

def normalize_h03(events):
 normalized=[];ignored=Counter();seen=set()
 for ordinal,event in enumerate(events[:MAX_EVENTS]):
  if not isinstance(event,dict):ignored['malformed']+=1;continue
  actor=event.get('actor')
  if actor not in ('target','simulated_target'):
   ignored[str(actor or 'unknown')]+=1;continue
  identity=event.get('id') or 'ordinal-'+str(ordinal)
  key=stable_hash({k:v for k,v in event.items() if k not in ('elapsed_seconds','recorded_at')})
  if key in seen:ignored['duplicate']+=1;continue
  seen.add(key);args=_arguments(event);output=_json_object(event.get('output'))
  category=_category(event.get('name'),args)
  normalized.append({'id':str(identity),'native_call_id':event.get('call_id'),'write_content_sha256':sha_bytes(args['content'].encode()) if isinstance(args.get('content'),str) else None,'actor':actor,'stage':event.get('stage'),'category':category,
                     'status':event.get('status'),'path':_explicit_path(args,output),'output':output,
                     'read_text_observed':isinstance(output.get('text'),str) and event.get('status')=='completed',
                     'evidence':{'pointer':'/tool_events/'+str(ordinal)}})
 return normalized,dict(ignored)

def normalize_l1(document):
 records=document.get('records',[]);calls=[];results={};seen=set();ignored=Counter()
 for ordinal,record in enumerate(records[:MAX_EVENTS*2]):
  if not isinstance(record,dict):continue
  if record.get('kind')=='tool_result' and record.get('call_id'):results.setdefault(str(record['call_id']),[]).append((ordinal,record))
  elif record.get('kind')=='tool_call':calls.append((ordinal,record))
 normalized=[]
 for ordinal,call in calls:
  if call.get('role') not in ('assistant','target'):
   ignored[str(call.get('role','unknown'))]+=1;continue
  key=stable_hash({k:v for k,v in call.items() if k not in ('seq','source_pointer')})
  if key in seen:ignored['duplicate']+=1;continue
  seen.add(key)
  candidates=[(i,r) for i,r in results.get(str(call.get('call_id')),[]) if i>ordinal and
              r.get('role') not in ('evaluator','user','child') and
              not (call.get('generation_id') and r.get('generation_id') and call['generation_id']!=r['generation_id'])]
  unique={stable_hash({k:v for k,v in r.items() if k not in ('seq','source_pointer')}):(i,r) for i,r in candidates}
  pair=next(iter(unique.values())) if len(unique)==1 else None
  data=call.get('data') or {};args=_arguments(data)
  result=pair[1].get('data',{}) if pair else {}
  output=_json_object(result.get('text'))
  if not output and isinstance(result.get('text'),str):output={'text':result['text']}
  if 'exit_code' in result and 'exit_code' not in output:output['exit_code']=result['exit_code']
  category=_category(data.get('name'),args)
  normalized.append({'id':str(call.get('id') or 'ordinal-'+str(ordinal)),'native_call_id':call.get('call_id'),'write_content_sha256':sha_bytes(args['content'].encode()) if isinstance(args.get('content'),str) else None,'actor':'target','stage':call.get('stage'),
                     'category':category,'status':'completed' if pair else 'unknown','path':_explicit_path(args,output),
                     'output':output,'read_text_observed':bool(pair) and isinstance(output.get('text'),str),
                     'evidence':{'pointer':'/records/'+str(ordinal),'result_pointer':'/records/'+str(pair[0]) if pair else None}})
 return normalized,dict(ignored)

def _failure_feedback(output):
 checks=output.get('checks')
 if isinstance(checks,list):
  states=[item.get('status') for item in checks if isinstance(item,dict)]
  if 'fail' in states:return True
  return False if states and all(state in ('pass','not_applicable') for state in states) else None
 texts=[output[key] for key in ('stdout','stderr') if isinstance(output.get(key),str)]
 if not texts:return None
 text='\n'.join(texts)
 if re.search(r'(?m)^SELFCHECK\s+FAIL\b|^FAILED(?:\s|\()|^FAIL:|^ERROR:',text):return True
 if type(output.get('exit_code')) is int and output['exit_code']!=0:return True
 if re.search(r'(?m)^OK\s*$|\b[1-9]\d*\s+passed\b|^SELFCHECK\s+ok\b',text):return False
 return None

def measure(events):
 counts=Counter(event['category'] for event in events)
 features={'observed_target_tool_calls':len(events),'observed_read_calls':counts['read'],'observed_write_calls':counts['write'],
           'observed_check_calls':counts['check'],'observed_list_calls':counts['list'],'other_target_calls':counts['other'],
           'distinct_observed_write_paths':len({event['path'] for event in events if event['category']=='write' and event['path']})}
 first_write=next((i for i,e in enumerate(events) if e['category']=='write'),None)
 first_check=next((i for i,e in enumerate(events) if e['category']=='check'),None)
 features['read_paths_before_first_observed_write']=len({e['path'] for e in events[:first_write] if e['category']=='read' and e['read_text_observed'] and e['path']}) if first_write is not None else deepcopy(UNKNOWN)
 features['checks_before_first_observed_write']=sum(e['category']=='check' for e in events[:first_write]) if first_write is not None else deepcopy(UNKNOWN)
 features['writes_after_first_observed_check']=sum(e['category']=='write' for e in events[first_check+1:]) if first_check is not None else deepcopy(UNKNOWN)
 check_indices=[i for i,e in enumerate(events) if e['category']=='check']
 features['rechecks_without_intervening_write']=sum(not any(e['category']=='write' for e in events[a+1:b]) for a,b in zip(check_indices,check_indices[1:])) if len(check_indices)>1 else deepcopy(UNKNOWN)
 checks=[events[i]['output'] for i in check_indices];failures=[_failure_feedback(output) for output in checks]
 features['visible_failed_check_calls']=sum(value is True for value in failures) if checks and all(value is not None for value in failures) else deepcopy(UNKNOWN)
 exits=[output.get('exit_code') for output in checks]
 features['nonzero_exit_check_calls']=sum(value!=0 for value in exits) if exits and all(type(value) is int for value in exits) else deepcopy(UNKNOWN)
 stdouts=[output.get('stdout') for output in checks]
 features['selfcheck_failure_label_occurrences']=sum(len(re.findall(r'(?m)^SELFCHECK\s+FAIL\b',text)) for text in stdouts) if stdouts and all(isinstance(text,str) for text in stdouts) else deepcopy(UNKNOWN)
 return features

def trace_content_hash(events):
 records=[]
 for event in events:
  output=event['output'];category=event['category']
  value={'category':category,'path':event.get('path'),'native_call_id':event.get('native_call_id'),
         'write_content_sha256':event.get('write_content_sha256'),'status':event.get('status')}
  if category=='read':value['read_text_sha256']=sha_bytes(output['text'].encode()) if isinstance(output.get('text'),str) else None
  elif category=='check':value['check_output']={k:output[k] for k in ('stdout','stderr','exit_code','checks','status') if k in output}
  elif category=='list':value['files']=output.get('files')
  elif category=='write':value['reported_written_path']=_relative(output.get('written',output.get('path')))
  records.append(value)
 return stable_hash({'canonical_trace_version':1,'events':records})

def original_identity(trace_hash,fallback):
 try:reference=json.loads(files(__package__).joinpath('resources/process-reference-v1.json').read_text(encoding='utf-8'))
 except FileNotFoundError:return fallback
 matches={row['original_sample_sha256'] for row in reference.get('process_trace_aliases',[]) if row.get('trace_content_sha256')==trace_hash}
 return next(iter(matches)) if len(matches)==1 else fallback


def _task_evidence(document,events):
 definition=task_contract();contract_hash=definition['contract_sha256'];context=document.get('context') or {}
 if context.get('process_task_id')==TASK_ID and context.get('task_contract_sha256')==contract_hash:
  return {'matched':True,'basis':'explicit_task_and_contract_hash_declarations','task_contract_sha256':contract_hash}
 task_reads=[event for event in events if event['category']=='read' and event['path']=='TASK.md' and isinstance(event['output'].get('text'),str)
             and sha_bytes(event['output']['text'].encode())==contract_hash]
 prompt_hashes={'a1bc7edc8c0081105b108769f2c62f705facf2213877e99eea4c5b931d890865'}
 prompt_hashes.update(sha_bytes(stage['prompt'].encode()) for stage in definition['stages'])
 prompts=[r for r in document.get('records',[]) if isinstance(r,dict) and r.get('kind')=='message' and r.get('role')=='user' and isinstance(r.get('data',{}).get('text'),str)]
 exact_request=any(sha_bytes(r['data']['text'].strip().encode()) in prompt_hashes or sha_bytes(r['data']['text'].encode())==contract_hash for r in prompts)
 return {'matched':bool(task_reads and exact_request),'basis':'exact_observed_TASK_text_and_matching_task_request' if task_reads and exact_request else 'task_scope_not_uniquely_bound',
         'task_contract_sha256':contract_hash if task_reads and exact_request else None,'evidence':[event['evidence'] for event in task_reads]}

def profile_from_h03(result):
 if result.get('task_id') not in ('H03','H03:pipeline') or result.get('variant','pipeline')!='pipeline':return None
 raw=result.get('tool_events')
 if not isinstance(raw,list):return None
 events,ignored=normalize_h03(raw)
 if not events:return None
 source=result.get('source') or {};execution=result.get('execution') or {}
 limits=execution.get('limits') or {}
 contract=task_contract()
 conditions={'task_contract_sha256':contract['contract_sha256'],'harness':'tokenclock-h03-workspace-v1',
             'tool_mapping':'read/write/list/fixed_checks','check_feedback_schema':'public_check_status_summary',
             'stage_protocol':'controller_stage_labels','source_capture_complete':result.get('stop') is None,
             'generation_conditions_origin':'only_explicit_result_fields'}
 for key,source_key in [('generation_limit','output_tokens'),('max_requests','requests')]:
  if source_key in limits:conditions[key]=limits[source_key]
 if 'reasoning_effort' in result.get('generation',{}).get('conditions',{}):conditions['reasoning_effort']=result['generation']['conditions']['reasoning_effort']
 return {'schema':SCHEMA,'task_id':TASK_ID,'measurement_contract':measurement_contract(),'conditions':conditions,
         'origin':ORIGIN,'source_scope':source.get('kind','unknown'),'sample_hash':source.get('original_sample_sha256') or original_identity(trace_content_hash(events),stable_hash({'initial':source.get('initial_workspace_sha256'),'events':raw})),
         'trace_content_sha256':trace_content_hash(events),'features':measure(events),'coverage':{'target_events':len(events),'ignored':ignored,'raw_event_limit':MAX_EVENTS},
         'limitations':['Counts describe visible target-issued calls, not thinking steps, production repairs, or evaluator work.',
                        'Current two-stage/status-summary harness differs from the historical raw-feedback harness; compare contextually only.']}

def attach_l1(document,report):
 output=deepcopy(report);events,ignored=normalize_l1(document)
 if not events:return output
 matched=_task_evidence(document,events);source=document.get('source') or {};context=document.get('context') or {}
 output['process_profile']={'schema':SCHEMA,'task_id':TASK_ID if matched['matched'] else 'unmatched-session','task_binding':matched,
   'measurement_contract':measurement_contract() if matched['matched'] else {},'origin':ORIGIN,
   'source_scope':source.get('kind','imported_session'),'sample_hash':original_identity(trace_content_hash(events),stable_hash({'observed_document':document.get('id'),'events':events})),
   'trace_content_sha256':trace_content_hash(events),'conditions':{'task_contract_sha256':matched['task_contract_sha256'],
      'harness':'l1-import:'+str(source.get('format','unknown')),'source_capture_complete':context.get('capture_complete'),
      'tool_mapping':'bounded_explicit_call_and_result_pairs','check_feedback_schema':'captured_result_body'},
   'features':measure(events),'coverage':{'target_events':len(events),'ignored':ignored},
   'limitations':['Exact task text and task request, or explicit task/hash declarations, are required for reference matching.',
                  'L1 capture conditions may be incomplete; path names alone and evaluator-only events do not identify a task or a target action.']}
 return output

def fingerprint_observation(profile,subject):
 if not isinstance(profile,dict) or profile.get('schema')!=SCHEMA or not profile.get('features'):return None
 return {'bank':'process','task_id':profile.get('task_id','unmatched-session'),'task_family':profile.get('task_id','unmatched-session'),
         'dimension':'process','origin':profile.get('origin',ORIGIN),'measurement_contract':profile.get('measurement_contract',{}),
         'conditions':profile.get('conditions',{}),'features':deepcopy(profile['features']),
         'sample_hash':profile['sample_hash'],'content_sha256':profile.get('trace_content_sha256'),'identity_kind':'observed_process_snapshot',
         'source_scope':profile.get('source_scope','unknown'),'subject_id':subject['id'],'subject_label':subject['label'],'subject_scope':subject['scope']}

def _strip_production(code):
 tree=ast.parse(code)
 tree.body=[node for node in tree.body if not (isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name=='_self_check') and
            not (isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Name) and node.value.func.id=='_self_check')]
 for node in ast.walk(tree):
  if isinstance(node,(ast.Module,ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and node.body and isinstance(node.body[0],ast.Expr) and isinstance(node.body[0].value,ast.Constant) and isinstance(node.body[0].value.value,str):node.body=node.body[1:]
 return sha_bytes(ast.dump(tree,include_attributes=False).encode())

def historical_observations(root):
 root=Path(root).resolve();base=root/'research/model_integrity_m12/private';prior_path=base/'process_profile_audit_v1/heavy-trace-features.json'
 prior=_read(prior_path);definition=task_contract();observations=[];audits=[];all_hashes={}
 for annotation in prior['rows']:
  name=annotation['original_session_id']
  if name not in ('pipeline-04','pipeline-05'):raise ValueError('Unreviewed historical process enrollment')
  folder=base/'pipeline-v2'/name
  def read(name):
   path=folder/name;data=path.read_bytes();all_hashes[str(path)]=sha_bytes(data);return json.loads(data)
  delivery=read('delivery.json');raw=read('tool-events.json');capture=read('capture.json');history=read('history.json')
  for filename in ('delivery.json','tool-events.json'):
   if all_hashes[str(folder/filename)]!=annotation['source_hashes'][filename]:raise ValueError('Historical source hash drift: '+filename)
  if capture.get('parts')!=raw:raise ValueError('Capture alias differs; cannot merge as one source')
  if delivery.get('complete') is not True or delivery.get('model')!=annotation['model_label_as_recorded']:raise ValueError('Historical completion/model declaration mismatch')
  before={};after={}
  for relative,expected in prior['comparability']['before_file_sha256'].items():
   for sub,target in [('before',before),('after',after)]:
    path=folder/sub/relative;data=path.read_bytes();all_hashes[str(path)]=sha_bytes(data);target[relative]=sha_bytes(data)
   if before[relative]!=expected or expected!=definition['source_file_sha256'][relative]:raise ValueError('Task snapshot definition drift')
  calls=[];results={};user_task_prompts=[]
  for message in history:
   content=message.get('content')
   if message.get('role')=='assistant' and isinstance(content,list):
    # Only tool-use blocks are inspected. Thinking/text bodies are not features.
    calls.extend(block for block in content if isinstance(block,dict) and block.get('type')=='tool_use')
   elif message.get('role')=='user':
    if isinstance(content,str):user_task_prompts.append(content)
    elif isinstance(content,list):
     for block in content:
      if block.get('type')=='tool_result':results[block['tool_use_id']]=block.get('content')
      else:raise ValueError('Unreviewed non-tool user followup in historical reference')
  if len(user_task_prompts)!=1 or sha_bytes(user_task_prompts[0].encode())!=prior['comparability']['initial_user_prompt_sha256'] or len(calls)!=len(raw):raise ValueError('Historical request/tool count mismatch')
  normalized=[]
  name_map={'list_files':'glob','read_file':'read','write_file':'write','run_checks':'bash'}
  for index,(call,event) in enumerate(zip(calls,raw)):
   state=event['state'];args=call.get('input') or {};out=_json_object(state.get('output'))
   if name_map.get(call['name'])!=event.get('tool') or _json_object(results.get(call['id']))!=out:raise ValueError('Native tool/result binding mismatch')
   if call['name'] in ('read_file','write_file') and _relative(args.get('path'))!=_relative(state.get('input',{}).get('filePath')):raise ValueError('Tool input path mismatch')
   if call['name']=='write_file' and args.get('content')!=state.get('input',{}).get('content'):raise ValueError('Tool write content mismatch')
   normalized.append({'id':call['id'],'native_call_id':call['id'],'write_content_sha256':sha_bytes(args['content'].encode()) if isinstance(args.get('content'),str) else None,'actor':'target','stage':0,'category':_category(call['name'],args),'status':state['status'],
                      'path':_explicit_path(args,out),'output':out,'read_text_observed':isinstance(out.get('text'),str) and state['status']=='completed',
                      'evidence':{'path':str(folder/'tool-events.json'),'pointer':'/'+str(index),'native_call_id':call['id']}})
  measured=measure(normalized);expected=annotation['raw_counts']
  if (measured['observed_target_tool_calls'],measured['observed_read_calls'],measured['observed_write_calls'],measured['observed_check_calls'])!=(expected['tool_events'],expected['read_calls'],expected['write_calls'],expected['test_execution_calls']):raise ValueError('Recomputed tool counts do not match prior audit')
  ast_checks={}
  for index,expected_ast in annotation.get('production_ast_comparison',{}).get('sha256_by_event',{}).items():
   actual=_strip_production(raw[int(index)]['state']['input']['content']);ast_checks[index]=actual
   if actual!=expected_ast:raise ValueError('Prior production-AST annotation cannot be reproduced')
  identity=stable_hash({'historical_workspace':name,'files':after})
  policy=delivery['policy']
  conditions={'task_contract_sha256':definition['contract_sha256'],'initial_prompt_sha256':sha_bytes(user_task_prompts[0].encode()),
              'harness':'m12-four-tool-generous-v2','tool_mapping':'read/write/list/fixed_checks','check_feedback_schema':'raw_stdout_stderr_exit',
              'stage_protocol':'single_task_no_requirement_followups','source_capture_complete':True,
              'generation_limit':policy['generation_limit'],'reasoning_effort':policy['effort'],'max_requests':policy['max_requests'],
              'generation_conditions_origin':'recorded_delivery_policy_and_verified_history'}
  observation={'bank':'process','task_id':TASK_ID,'task_family':TASK_ID,'dimension':'process','origin':ORIGIN,
    'model_label':delivery['model'],'sample_hash':identity,'content_sha256':trace_content_hash(normalized),
    'measurement_contract':measurement_contract(),'conditions':conditions,'features':measured}
  observations.append(observation)
  semantic={key:value if value is not None else deepcopy(UNKNOWN) for key,value in annotation['semantic_counts'].items()}
  observations.append({**observation,'origin':'prior_nonblind_process_semantics','measurement_contract':{
    'task_version':'pipeline-v1','grader_version':'historical-process-semantics-v1','definition_sha256':stable_hash({'schema':prior['schema'],'fields':sorted(semantic),'role':'prior_nonblind_annotation_not_automatic_production_repair'})},'features':semantic})
  audits.append({'original_session':name,'model_label_as_recorded':delivery['model'],'sample_hash':identity,'canonical_trace_sha256':trace_content_hash(normalized),
     'source_files':{path:digest for path,digest in all_hashes.items() if str(folder)+'/' in path},'capture_alias_verified':True,
     'native_tool_calls_and_results_verified':len(normalized),'features':measured,'prior_semantic_features':semantic,
     'production_ast_hashes_reproduced':ast_checks,'prior_annotations_remain_nonblind':True,'source_scope':'one_existing_session_not_a_new_sample'})
 for path,expected in all_hashes.items():
  if sha_bytes(Path(path).read_bytes())!=expected:raise ValueError('Historical source changed while auditing')
 exclusions=[]
 open_audit=_read(base/'process_profile_audit_v1/features.json')
 toolfree_verified=0
 for row in open_audit['rows']:
  response_ref=next((ref for ref in row['source_files'] if ref['path'].endswith('/response.json')),None)
  if response_ref is None:continue
  raw_response=Path(response_ref['path']).read_bytes()
  if sha_bytes(raw_response)!=response_ref['sha256']:raise ValueError('Tool-free source hash drift')
  response=json.loads(raw_response)
  action_types=[item.get('type') for key in ('output','content') for item in response.get(key,[]) if isinstance(item,dict) and item.get('type') in ('tool_use','function_call','custom_tool_call')]
  chat_calls=sum(len((choice.get('message') or {}).get('tool_calls') or []) for choice in response.get('choices',[]) if isinstance(choice,dict))
  if action_types or chat_calls or row['request_conditions'].get('tools_enabled_by_protocol')!=[]:raise ValueError('Open-artifact target tool absence is no longer established')
  toolfree_verified+=1
 exclusions=[{'scope':'40 open-artifact answers','raw_response_hashes_and_zero_action_types_verified':toolfree_verified,'reason':'Protocol had no target tools; evaluator execution is not target process. Retain resource/delivery observations in their existing banks.'},
             {'scope':'pipeline-01, pipeline-02 and 02-resume','reason':'Different artificial limits and continuation scope; excluded from this same-task completed-pair reference.'}]
 parents=root/'research/model_integrity_l1_confusion_bank_v1/private/materialized-v1/parents.json'
 if parents.exists():
  for parent in _read(parents)['parents']:
   if parent.get('bucket')!='tool_task_groups':continue
   exclusions.append({'scope':parent['id'],'task_family':parent['lineage_group'],'recorded_labels':parent.get('original_model_labels',[]),
     'reason':'Same pipeline-04 source view; not another sample' if parent['lineage_group']=='incremental-pipeline-cache' else 'Different task family; not silently matched to H03:pipeline or relabelled to a current model.'})
 return observations,{'schema':'tokenclock-process-reference-source-audit/v1','included':audits,'excluded_or_duplicate':exclusions,
                     'original_sessions':len(audits),'same_task_cross_model_pairs':1,'new_model_calls':0,'new_cost_usd':'0',
                     'all_selected_sources_unchanged':True,'reasoning_bodies_used':False,'candidate_code_executed':False}


def build(root,output_dir,resource_path=None):
 from .fingerprints import aggregate_reference
 observations,audit=historical_observations(root);output=Path(output_dir)
 if output.exists() and any(output.iterdir()):raise ValueError('Refusing to replace a process source audit')
 output.mkdir(parents=True,exist_ok=True);output.chmod(0o700)
 labels=dict(Counter(row['model_label_as_recorded'] for row in audit['included']))
 banks={'process':{'original_samples':audit['original_sessions'],'labels':labels,'task_ids':[TASK_ID],
   'observed_metric_count':len(DEFINITION['metrics']),'reference_scope':'Real historical target-tool traces, one session per label; current cross-harness comparisons contextual only.',
   'prior_semantic_annotations_separate':True,'new_model_calls':0}}
 reference=aggregate_reference(observations,banks=banks,source_audit={'new_model_calls':0,'new_cost_usd':'0','historical_labels_authenticated':False,'sources_unchanged':True})
 reference['process_trace_aliases']=[{'trace_content_sha256':row['canonical_trace_sha256'],'original_sample_sha256':row['sample_hash']} for row in audit['included']]
 target=Path(resource_path) if resource_path else Path(root)/'scripts/model_integrity/probes/resources/process-reference-v1.json'
 _write(target,reference);_write(output/'source-audit.json',audit)
 _write(output/'build-summary.json',{'reference_sha256':sha_bytes(target.read_bytes()),'reference_path':str(target),'banks':banks,'cells':len(reference['cells']),'new_model_calls':0})
 return reference


def merge_reference(reference):
 """Default bundled extension only; an explicit caller reference stays explicit."""
 try:extra=json.loads(files(__package__).joinpath('resources/process-reference-v1.json').read_text(encoding='utf-8'))
 except FileNotFoundError:return reference
 result=deepcopy(reference);existing={cell['id'] for cell in result.get('cells',[])}
 result.setdefault('cells',[]).extend(cell for cell in extra.get('cells',[]) if cell['id'] not in existing)
 result['model_labels']=sorted(set(result.get('model_labels',[]))|set(extra.get('model_labels',[])))
 result.setdefault('banks',{}).update(extra.get('banks',{}))
 return result
