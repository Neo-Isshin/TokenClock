"""Offline T01/T04 observations from explicitly supplied stage/API captures.

No ordinary user prompt/assistant answer is turned into a text-cleaning probe.
Differences, field defaults and declared stage bindings are descriptive data;
this module does not identify a processing vendor, model family or exact model.
"""
from __future__ import annotations

from collections import Counter
import hashlib
from itertools import islice
import re
import unicodedata

MAX_PAIRS = 64
MAX_TEXT_CODEPOINTS = 262144
MAX_FIELD_PATHS = 256
MAX_DEPTH = 5
MAX_LIST_ITEMS = 4
MAX_EXCERPT = 256
MISSING = object()
REQUEST_PARAMETERS = ('model','temperature','top_p','seed','max_tokens','max_output_tokens',
                      'reasoning_effort','reasoning','thinking','stream','logprobs','top_logprobs',
                      'tools','tool_choice','parallel_tool_calls','response_format','stop','store','include')
RESPONSE_PATHS = ('/id','/model','/object','/system_fingerprint','/usage','/choices','/output','/content',
                  '/status','/stop_reason','/error','/service_tier','/choices/0/logprobs',
                  '/choices/0/finish_reason','/choices/0/message/tool_calls','/output/0/type',
                  '/usage/input_tokens','/usage/output_tokens','/usage/prompt_tokens',
                  '/usage/completion_tokens','/usage/total_tokens','/usage/reasoning_tokens',
                  '/usage/input_tokens_details/cached_tokens','/usage/output_tokens_details/reasoning_tokens')


def _type(value):
    if value is None: return 'null'
    if type(value) is bool: return 'boolean'
    if type(value) is int: return 'integer'
    if type(value) is float: return 'number'
    if isinstance(value,str): return 'string'
    if isinstance(value,list): return 'array'
    if isinstance(value,dict): return 'object'
    return 'unsupported_python_type'


def _stats(text):
    try:
        encoded=text.encode('utf-8')
        byte_count=len(encoded);sha=hashlib.sha256(encoded).hexdigest();valid=True
    except UnicodeEncodeError:
        byte_count=sha=None;valid=False
    return {'codepoints':len(text),'utf8_bytes':byte_count,'utf8_sha256':sha,'valid_unicode_scalar_text':valid}


def _excerpt(text):
    excerpt=text[:MAX_EXCERPT]
    invalid=any(0xD800<=ord(char)<=0xDFFF for char in excerpt)
    if invalid:excerpt=''.join(('\\u'+format(ord(char),'04x')) if 0xD800<=ord(char)<=0xDFFF else char for char in excerpt)
    result={'text':excerpt,'full_codepoints':len(text),'truncated':len(text)>MAX_EXCERPT,'invalid_scalars_escaped':invalid}
    result.update(_stats(text));return result


def _line_endings(text):
    crlf=text.count('\r\n')
    return {'crlf':crlf,'bare_cr':text.count('\r')-crlf,'bare_lf':text.count('\n')-crlf}


def _newline_normalized(text): return text.replace('\r\n','\n').replace('\r','\n')


def _format_character(character):
    category=unicodedata.category(character)
    return category in ('Cf','Cc') or (category=='Zs' and character!=' ')


def _changes(before,after):
    prefix=0;limit=min(len(before),len(after))
    while prefix<limit and before[prefix]==after[prefix]:prefix+=1
    suffix=0
    while suffix<limit-prefix and before[len(before)-1-suffix]==after[len(after)-1-suffix]:suffix+=1
    before_end=len(before)-suffix;after_end=len(after)-suffix
    removed=before[prefix:before_end];added=after[prefix:after_end]
    difference={'identical':before==after,'common_prefix_codepoints':prefix,'common_suffix_codepoints':suffix,
                'before_range':[prefix,before_end],'after_range':[prefix,after_end],
                'before_changed_region':_excerpt(removed),'after_changed_region':_excerpt(added),
                'range_definition':'Smallest single replacement interval after removing the exact shared prefix and suffix; not a full edit-script inference.'}
    if removed and not added:
        stop={'kind':'leading_prefix_removed' if prefix==0 else 'deletion_after_exact_shared_prefix',
              'before_stop_offset':before_end,'after_stop_offset':prefix,
              'first_retained_text':_excerpt(after[prefix:prefix+80]),
              'interpretation':'Observed boundary in this pair only; it does not establish a parser stopping rule.'}
        if re.fullmatch(r'(?:[A-Za-z_][A-Za-z0-9_]*:\s*)+',removed):
            tokens=re.findall(r'([A-Za-z_][A-Za-z0-9_]*):',removed)
            stop['removed_lexical_prefix_tokens']=tokens[:32]
            stop['removed_lexical_prefix_count']=len(tokens)
            if len(set(token.casefold() for token in tokens))==1:
                token=tokens[0]
                stop['same_marker_after_casefold']=True
                stop['same_marker_later_in_retained_text']=bool(re.search(re.escape(token)+':',after[prefix:],re.I))
                stop['casefold_note']='Case folding groups visible spellings only; no case-insensitive service rule is inferred.'
        difference['observed_prefix_stop']=stop
    return difference


def _text_pair(pair,index):
    pointer='/text_pairs/'+str(index)
    base={'type':'explicit_text_stage_comparison','evidence':[{'pointer':pointer}],
          'status':'unknown','is_anomaly':None,'attribution':'not_estimated'}
    if not isinstance(pair,dict):return {**base,'reason':'text_pair_not_object'}
    rid=pair.get('request_id');before=pair.get('before');after=pair.get('after')
    if not isinstance(rid,str) or not rid.strip() or not all(isinstance(pair.get(key),str) and pair[key].strip() for key in ('before_stage','after_stage')):
        return {**base,'reason':'request_binding_or_stage_labels_missing'}
    base.update(request_id=rid,group='service-call:'+rid,before_stage=pair['before_stage'],after_stage=pair['after_stage'],
                binding_scope='caller_supplied_request_id_and_stage_labels_not_independently_authenticated')
    if not isinstance(before,str) or not isinstance(after,str):return {**base,'reason':'before_or_after_text_missing'}
    if max(len(before),len(after))>MAX_TEXT_CODEPOINTS:return {**base,'reason':'explicit_text_pair_exceeds_local_analysis_bound','before_codepoints':len(before),'after_codepoints':len(after)}
    first,second=_stats(before),_stats(after)
    invisible_before=Counter(char for char in before if _format_character(char))
    invisible_after=Counter(char for char in after if _format_character(char))
    character_changes=[]
    for char in sorted(set(invisible_before)|set(invisible_after),key=ord):
        if invisible_before[char]!=invisible_after[char]:
            character_changes.append({'codepoint':f'U+{ord(char):04X}','unicode_name':unicodedata.name(char,'UNNAMED'),
                                      'category':unicodedata.category(char),'before_count':invisible_before[char],
                                      'after_count':invisible_after[char],'delta':invisible_after[char]-invisible_before[char]})
    scalar_valid=first['valid_unicode_scalar_text'] and second['valid_unicode_scalar_text']
    base.update(status='observed',before=first,after=second,difference=_changes(before,after),
                normalization={'unicode_database_version':unicodedata.unidata_version,
                               'nfc_equivalent':unicodedata.normalize('NFC',before)==unicodedata.normalize('NFC',after) if scalar_valid else None,
                               'line_ending_normalization_equivalent':_newline_normalized(before)==_newline_normalized(after),
                               'line_endings_before':_line_endings(before),'line_endings_after':_line_endings(after),
                               'format_control_spacing_changes':character_changes,
                               'equal_after_omitting_classified_format_characters':''.join(c for c in before if not _format_character(c))==''.join(c for c in after if not _format_character(c))},
                alternatives=['任务本身可能要求改写、排版或编码转换。','差异可能来自客户端、适配器、服务端或展示层；此对记录不单独定位责任。'],
                interpretation='只描述显式配对文本的差异。未将差异判作异常，也未据此认定清洗、供应商、模型家族或具体型号。')
    return base


def _pointer(document,pointer):
    current=document
    for token in pointer.lstrip('/').split('/'):
        token=token.replace('~1','/').replace('~0','~')
        if isinstance(current,dict):current=current.get(token,MISSING)
        elif isinstance(current,list) and token.isdigit() and int(token)<len(current):current=current[int(token)]
        else:return MISSING
        if current is MISSING:return MISSING
    return current


def _shape(value,path='',depth=0,result=None):
    result=[] if result is None else result
    if depth>=MAX_DEPTH or len(result)>=MAX_FIELD_PATHS:return result
    if isinstance(value,dict):items=islice(value.items(),MAX_FIELD_PATHS)
    elif isinstance(value,list):items=list(enumerate(value[:MAX_LIST_ITEMS]))
    else:return result
    for key,child in items:
        if len(result)>=MAX_FIELD_PATHS:break
        component=str(key).replace('~','~0').replace('/','~1')
        child_path=path+'/'+component
        result.append({'path':child_path,'presence':'present','type':_type(child)})
        _shape(child,child_path,depth+1,result)
    return result


def _field(document,path,body_observed):
    if not body_observed:return {'path':path,'presence':'body_not_observed','type':None}
    value=_pointer(document,path)
    return {'path':path,'presence':'missing','type':None} if value is MISSING else {'path':path,'presence':'present','type':_type(value)}


def _api_pair(pair,index):
    base={'type':'api_field_surface','evidence':[{'pointer':'/api_pairs/'+str(index)}],
          'status':'unknown','is_anomaly':None,'parameter_effectiveness':'not_estimated','attribution':'not_estimated'}
    if not isinstance(pair,dict):return {**base,'reason':'api_pair_not_object'}
    rid=pair.get('request_id')
    request=pair.get('request',MISSING);response=pair.get('response',MISSING)
    request_seen=isinstance(request,dict);response_seen=isinstance(response,dict)
    base.update(request_id=rid if isinstance(rid,str) and rid.strip() else None,
                group='service-call:'+rid if isinstance(rid,str) and rid.strip() else 'unbound-api-pair:'+str(index),
                binding_scope='caller_supplied_request_pair_not_authenticated' if isinstance(rid,str) and rid.strip() else 'unbound_field_observations_only',
                request_body_observed=request_seen,response_body_observed=response_seen)
    if not request_seen and not response_seen:return {**base,'reason':'raw_request_and_response_objects_not_supplied'}
    parameters=[]
    for name in REQUEST_PARAMETERS:
        item=_field(request,'/'+name,request_seen)
        item['parameter']=name
        item['request_status']='request_not_observed' if not request_seen else 'explicitly_supplied' if item['presence']=='present' else 'not_explicitly_requested'
        if request_seen and name in request and (request[name] is None or type(request[name]) in (bool,int,float)):
            # These literal nontext values clarify false vs true vs null without
            # copying user prompts, tool bodies or credential strings.
            item['literal_value']=request[name]
        parameters.append(item)
    return {**base,'status':'observed','request_parameters':parameters,
            'response_fields':[_field(response,path,response_seen) for path in RESPONSE_PATHS],
            'request_shape':_shape(request) if request_seen else [],'response_shape':_shape(response) if response_seen else [],
            'shape_limits':{'max_paths_per_body':MAX_FIELD_PATHS,'max_depth':MAX_DEPTH,'sampled_array_entries':MAX_LIST_ITEMS},
            'interpretation':'参数明确出现、未明确请求、字段缺失、null和字段类型分别保留；返回某字段不说明参数生效，未请求也不说明服务禁用了默认行为。',
            'alternatives':['SDK、API版本、服务包装层、权限或默认设置都可能影响字段形态。','字段形态无法单独认证模型家族或具体型号。']}


def analyze(capture):
    observations=[]
    limitations=['本模块只分析输入中显式提供的文本阶段对和API对象，不读取外链、源路径或其他文件，不发送请求。',
                 '普通用户问题与助手回答不会被自动当成清洗前后对；显式文本对的变化也不自动构成异常。',
                 '请求ID和阶段名称是捕获材料中的声明，不是独立来源认证。',
                 '这些观察最多描述文本处理边界与API服务表面，不能单独识别供应商、模型家族或具体型号。',
                 '同一调用的文本差异、长度、格式字符和字段表现共享证据，不应重复计分。']
    if not isinstance(capture,dict):
        return {'observations':[], 'limitations':limitations+['未提供显式text_pairs/api_pairs对象；普通运输记录不升级为原始API文本证据。']}
    for key,reader in [('text_pairs',_text_pair),('api_pairs',_api_pair)]:
        values=capture.get(key,[])
        if not isinstance(values,list):
            limitations.append(key+'不是数组，该部分未分析。');continue
        for index,pair in enumerate(values[:MAX_PAIRS]):observations.append(reader(pair,index))
        if len(values)>MAX_PAIRS:limitations.append(key+'超出本地条数上限，超出部分未分析。')
    if not observations:limitations.append('没有可分析的显式阶段对或原始API对；不从普通request/response正文猜测清洗机制。')
    return {'observations':observations,'limitations':limitations}
