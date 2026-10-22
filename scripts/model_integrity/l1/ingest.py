"""Bounded, local import of native logs. Captured commands are never run."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .engine import INPUT_SCHEMA, MAX_RECORDS

DEFAULT_MAX_BYTES = 64 * 1024 * 1024


def _object(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise ValueError('duplicate JSON object key: '+str(key))
        result[key]=value
    return result


def strict_loads(raw):
    return json.loads(raw, object_pairs_hook=_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('non-finite JSON value: '+value)))


def _blocks_text(blocks):
    if isinstance(blocks,str): return blocks
    if not isinstance(blocks,list): return ''
    return '\n'.join(b.get('text','') for b in blocks if isinstance(b,dict) and b.get('type') in {'text','input_text','output_text'} and isinstance(b.get('text'),str))


def _usage(raw, schema):
    result={'schema':schema}
    if not isinstance(raw,dict): return result
    fields={'input_tokens':'input_tokens','output_tokens':'output_tokens','total_tokens':'total_tokens',
            'reasoning_tokens':'reasoning_tokens','reasoning_output_tokens':'reasoning_tokens',
            'cached_input_tokens':'cache_read_tokens','cache_read_input_tokens':'cache_read_tokens',
            'cache_creation_input_tokens':'cache_write_tokens','prompt_tokens':'input_tokens','completion_tokens':'output_tokens',
            'prompt_cache_hit_tokens':'cache_read_tokens','prompt_cache_miss_tokens':'cache_miss_tokens'}
    for source,dest in fields.items():
        if source in raw:result[dest]=raw[source]
    for outer,inner,dest in [('input_tokens_details','cached_tokens','cache_read_tokens'),
                             ('output_tokens_details','reasoning_tokens','reasoning_tokens')]:
        if isinstance(raw.get(outer),dict) and inner in raw[outer]:result[dest]=raw[outer][inner]
    return result


def _result_data(value):
    if isinstance(value,list): value=_blocks_text(value)
    if isinstance(value,dict): parsed=value
    elif isinstance(value,str):
        try:parsed=strict_loads(value)
        except (ValueError,TypeError):parsed=None
    else:parsed=None
    if isinstance(parsed,dict) and any(k in parsed for k in ('stdout','output','exit_code')):
        out=parsed.get('stdout',parsed.get('output',value if isinstance(value,str) else ''))
        data={'text':out if isinstance(out,str) else str(out)}
        if 'exit_code' in parsed:data['exit_code']=parsed['exit_code']
        if parsed.get('stderr'):data['text']+='\n'+str(parsed['stderr'])
        return data
    return {'text':value if isinstance(value,str) else ''}


def _base(path,raw,fmt):
    sha=hashlib.sha256(raw).hexdigest()
    return {'schema':INPUT_SCHEMA,'id':'import-'+sha[:16],
            'source':{'kind':'imported_session','format':fmt,'refs':[{'path':str(path),'sha256':sha}]},
            'context':{'capture_complete':False},'records':[]}


def _append(doc,kind,role,data,line=None,pointer=None,**kwargs):
    index=len(doc['records'])
    record={'id':f'local-{index+1:06d}','seq':index,'kind':kind,'role':role,'data':data}
    if line is not None:record['source_pointer']={'path':doc['source']['refs'][0]['path'],'line':line}
    if pointer is not None:record['source_pointer']={'path':doc['source']['refs'][0]['path'],'json_pointer':pointer}
    record.update({k:v for k,v in kwargs.items() if v is not None})
    doc['records'].append(record)
    if len(doc['records'])>MAX_RECORDS:raise ValueError('Too many events; select a smaller explicit session scope')


def import_codex(rows,path,raw):
    doc=_base(path,raw,'codex_jsonl')
    turn=None
    call_generations={}
    for line,item in rows:
        if not isinstance(item,dict):
            _append(doc,'gap','unknown',{'reason':'Non-object JSONL record'},line);continue
        if item.get('_malformed_line'):
            _append(doc,'gap','unknown',{'reason':'Malformed/truncated JSONL line omitted','line':line},line);continue
        kind=item.get('type'); payload=item.get('payload')
        if not isinstance(payload,dict):
            _append(doc,'metadata','unknown',{'record_type':str(kind)},line);continue
        if kind=='session_meta':
            if isinstance(payload.get('id'),str):doc['context']['session_id']=payload['id']
        elif kind=='turn_context':
            turn=payload.get('turn_id')
            if isinstance(payload.get('model'),str):
                # This is a local harness declaration, not a response receipt.
                _append(doc,'model_request','user',{'model':payload['model'],'declaration_scope':'harness_turn_context'},line,generation_id=turn)
                doc['context'].setdefault('requested_model',payload['model'])
        elif kind=='event_msg':
            if payload.get('type')=='token_count':
                info=payload.get('info')
                last=info.get('last_token_usage') if isinstance(info,dict) else None
                if isinstance(last,dict):_append(doc,'usage','assistant',_usage(last,'openai_responses'),line,generation_id=turn)
            elif payload.get('type') in {'context_compacted','history_compacted'}:
                _append(doc,'gap','unknown',{'reason':'Source reports compacted history'},line)
            # agent_message/user_message event mirrors are deliberately not
            # duplicated when canonical response_item messages are present.
        elif kind=='compacted':
            _append(doc,'gap','unknown',{'reason':'Source contains compacted context'},line)
        elif kind=='response_item':
            ptype=payload.get('type')
            if ptype=='reasoning':continue
            if ptype=='message':
                body=_blocks_text(payload.get('content'))
                role=payload.get('role','unknown')
                _append(doc,'message',role,{'text':body},line,generation_id=turn)
            elif ptype in {'function_call','custom_tool_call'}:
                args=payload.get('arguments',payload.get('input',{}))
                if ptype=='custom_tool_call':args={'input':args}
                _append(doc,'tool_call','assistant',{'name':payload.get('name',''),'arguments':args},line,
                        call_id=payload.get('call_id'),generation_id=turn)
                cid=payload.get('call_id')
                if cid:call_generations[cid]=turn if cid not in call_generations else None
            elif ptype in {'function_call_output','custom_tool_call_output'}:
                _append(doc,'tool_result','tool',_result_data(payload.get('output','')),line,
                        call_id=payload.get('call_id'),generation_id=call_generations.get(payload.get('call_id')))
            else:_append(doc,'metadata','unknown',{'record_type':ptype},line)
        else:_append(doc,'metadata','unknown',{'record_type':str(kind)},line)
    return doc


def import_claude(rows,path,raw):
    doc=_base(path,raw,'claude_code_jsonl')
    for line,item in rows:
        if not isinstance(item,dict):
            _append(doc,'gap','unknown',{'reason':'Non-object JSONL record'},line);continue
        if item.get('_malformed_line'):
            _append(doc,'gap','unknown',{'reason':'Malformed/truncated JSONL line omitted','line':line},line);continue
        role=item.get('type')
        message=item.get('message')
        if isinstance(item.get('sessionId'),str):doc['context'].setdefault('session_id',item['sessionId'])
        if role not in {'assistant','user'} or not isinstance(message,dict):
            _append(doc,'metadata','unknown',{'record_type':str(role)},line);continue
        generation=message.get('id') if role=='assistant' else None
        if role=='assistant' and isinstance(message.get('model'),str):
            _append(doc,'model_response','assistant',{'model':message['model'],'declaration_scope':'local_assistant_message'},line,generation_id=generation)
        content=message.get('content')
        if isinstance(content,str):_append(doc,'message',role,{'text':content},line,generation_id=generation)
        elif isinstance(content,list):
            for block in content:
                if not isinstance(block,dict):continue
                if block.get('type')=='text':
                    _append(doc,'message',role,{'text':block.get('text','')},line,generation_id=generation)
                elif block.get('type')=='tool_use':
                    _append(doc,'tool_call',role,{'name':block.get('name',''),'arguments':block.get('input',{})},line,
                            call_id=block.get('id'),generation_id=generation)
                elif block.get('type')=='tool_result':
                    data=_result_data(block.get('content',''))
                    if block.get('is_error') is True:data['tool_error']=True
                    _append(doc,'tool_result','tool',data,line,call_id=block.get('tool_use_id'))
        if isinstance(message.get('usage'),dict):
            _append(doc,'usage',role,_usage(message['usage'],'anthropic_messages'),line,generation_id=generation)
    return doc


def load_observation(path: str | Path, format: str = 'auto', max_bytes: int = DEFAULT_MAX_BYTES) -> dict:
    path=Path(path).expanduser().resolve()
    if not isinstance(max_bytes,int) or max_bytes<1:raise ValueError('max_bytes must be positive')
    if path.is_dir():
        # Restrict directory import to the fixed three source files, with an
        # aggregate size guard before calling the existing source projector.
        files=[path/name for name in ('input.json','response.json','answer.txt')]
        if not all(p.is_file() for p in files):raise ValueError('Directory import requires input.json, response.json and answer.txt')
        if sum(p.stat().st_size for p in files)>max_bytes:raise ValueError('Source exceeds input size limit')
        from .sources import project_source
        return project_source(path)
    if path.stat().st_size>max_bytes:raise ValueError('Source exceeds input size limit; choose a smaller explicit scope or raise --max-mib')
    with path.open('rb') as stream:raw=stream.read(max_bytes+1)
    if len(raw)>max_bytes:raise ValueError('Source grew beyond input size limit while reading')
    content=raw.decode('utf-8-sig')
    if format=='observation':
        doc=strict_loads(content)
        if not isinstance(doc,dict) or doc.get('schema')!=INPUT_SCHEMA:raise ValueError('Not an L1 observation')
        return doc
    if format=='auto' and path.suffix.casefold()!='.jsonl':
        try:value=strict_loads(content)
        except ValueError:
            # Only fall back to JSONL if the first actual line is independently
            # valid JSON. Malformed pretty JSON is not silently a partial log.
            first=next((x for x in content.splitlines() if x.strip()),'')
            strict_loads(first)
        else:
            if isinstance(value,dict) and value.get('schema')==INPUT_SCHEMA:return value
            from .sources import project_source
            return project_source(path)
    rows=[]
    for line_number,line in enumerate(content.splitlines(),1):
        if not line.strip():continue
        try:rows.append((line_number,strict_loads(line)))
        except ValueError:rows.append((line_number,{'_malformed_line':True}))
    if not rows:raise ValueError('No readable native JSONL records')
    selected=format
    if selected=='auto':
        if any(isinstance(x,dict) and x.get('type') in {'session_meta','turn_context','response_item'} for _,x in rows):selected='codex'
        elif any(isinstance(x,dict) and x.get('type') in {'assistant','user'} and isinstance(x.get('message'),dict) for _,x in rows):selected='claude-code'
        else:raise ValueError('Unrecognized JSONL schema; select an explicit supported format')
    if selected=='codex':
        if not any(isinstance(x,dict) and x.get('type') in {'session_meta','turn_context','response_item'} and isinstance(x.get('payload'),dict) for _,x in rows):
            raise ValueError('Selected codex format does not match the observed JSONL schema')
        doc=import_codex(rows,path,raw)
    elif selected=='claude-code':
        if not any(isinstance(x,dict) and x.get('type') in {'assistant','user'} and isinstance(x.get('message'),dict) for _,x in rows):
            raise ValueError('Selected claude-code format does not match the observed JSONL schema')
        doc=import_claude(rows,path,raw)
    else:raise ValueError('Unsupported format: '+str(selected))
    return doc
