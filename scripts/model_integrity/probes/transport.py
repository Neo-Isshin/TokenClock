"""Serial, receipted live/replay calls. No implicit credentials or retries."""
from __future__ import annotations

import copy
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import socket
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
import uuid

from .common import canonical,digest,write_json,cancelled

FORMATS={'responses','messages','chat_completions'}


def money(value):
    if isinstance(value,bool):raise ValueError('Invalid money amount')
    if len(str(value))>128:raise ValueError('Money representation exceeds safety bound')
    try:n=Decimal(str(value))
    except (InvalidOperation,ValueError):raise ValueError('Invalid money amount') from None
    if not n.is_finite() or n<0 or n>Decimal('1000000000000'):raise ValueError('Money must be finite, nonnegative and bounded')
    return n


class ProbeStop(Exception):
    def __init__(self,code,details=None):super().__init__(code);self.code=code;self.details=details or {}


def quote_request(config,body,context=None):
    """Pure admission quote shared by UI preview and the actual dispatcher."""
    live=config.get('transport_mode','live')=='live'
    input_rate=money(config.get('input_usd_per_million')) if live else Decimal(0)
    output_rate=money(config.get('output_usd_per_million')) if live else Decimal(0)
    cache_read_rate=money(config.get('cache_read_usd_per_million',input_rate))
    cache_write_rate=money(config.get('cache_write_usd_per_million',input_rate*2 if config.get('api_format','responses')=='messages' else input_rate))
    data=canonical(body)
    if len(data)>24*1024*1024:raise ProbeStop('request_storage_limit')
    cap=body.get('max_output_tokens',body.get('max_tokens'))
    if type(cap) is not int or not 256<=cap<=262144:raise ValueError('Request must carry an explicit output cap within 256–262144')
    additional=(context or {}).get('input_additional_token_upper',0)
    if type(additional) is not int or not 0<=additional<=8_000_000:raise ValueError('Invalid extra input allowance')
    # With an explicit image allowance, image bytes are not text tokens.
    # Keep every other field in the byte-based text upper bound. Without an
    # allowance retain the older conservative full-body bound.
    cost_body=body
    if additional:
        def without_image_payload(value):
            if isinstance(value,list):return [without_image_payload(v) for v in value]
            if not isinstance(value,dict):return value
            result={k:without_image_payload(v) for k,v in value.items()}
            if value.get('type')=='input_image' and isinstance(value.get('image_url'),str) and value['image_url'].startswith('data:image/'):
                result['image_url']='[image charged by explicit allowance]'
            elif value.get('type')=='image_url' and isinstance(value.get('image_url'),dict) and str(value['image_url'].get('url','')).startswith('data:image/'):
                result['image_url']={**value['image_url'],'url':'[image charged by explicit allowance]'}
            elif value.get('type')=='image' and isinstance(value.get('source'),dict) and value['source'].get('type')=='base64':
                result['source']={**value['source'],'data':'[image charged by explicit allowance]'}
            return result
        cost_body=without_image_payload(body)
    upper=len(canonical(cost_body))+1024+additional
    if upper+cap>int(config.get('context_token_limit',2097152)):raise ProbeStop('conservative_context_limit')
    input_upper_rate=max(input_rate,cache_read_rate,cache_write_rate)
    estimate=(Decimal(upper)*input_upper_rate+Decimal(cap)*output_rate)/Decimal(1000000)+Decimal('0.01')
    return {'reserved_usd':str(estimate),'input_upper_for_cost':upper,'output_tokens':cap,
            'serialized_body_bytes':len(data),'separate_image_token_allowance':additional}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        fp.close()
        raise ProbeStop('redirect_rejected')


def request_body(config,prompt=None,history=None,tools=None,output_limit=None,system=None):
    fmt=config.get('api_format','responses');model=config.get('model')
    if fmt not in FORMATS or not isinstance(model,str) or not model.strip():raise ValueError('显式API格式和型号必填')
    cap=output_limit if output_limit is not None else config.get('max_output_tokens')
    if type(cap) is not int or not 256<=cap<=262144:raise ValueError('输出上限必须明确且在256–262144内')
    messages=copy.deepcopy(history) if history is not None else [{'role':'user','content':prompt}]
    if not isinstance(messages,list) or not messages:raise ValueError('Message list missing')
    effort=config.get('reasoning_effort','high')
    if effort not in {'low','medium','high','xhigh'}:raise ValueError('Unsupported reasoning effort')
    if fmt=='messages':
        converted=[]
        for m in messages:
            if m.get('role')=='tool':
                converted.append({'role':'user','content':[{'type':'tool_result','tool_use_id':m['tool_call_id'],'content':m['content']}]})
            elif m.get('native_format')==fmt:converted.append(copy.deepcopy(m['native_message']))
            elif m.get('role')=='assistant' and m.get('tool_calls'):
                content=[{'type':'text','text':m.get('content','')}] if m.get('content') else []
                content += [{'type':'tool_use','id':t['id'],'name':t['name'],'input':t['arguments']} for t in m['tool_calls']]
                converted.append({'role':'assistant','content':content})
            else:converted.append({'role':m['role'],'content':m['content']})
        body={'model':model,'messages':converted,'max_tokens':cap,
              'thinking':{'type':'adaptive','display':'summarized'},'output_config':{'effort':effort}}
        if tools:body['tools']=[{'name':t['name'],'description':t['description'],'input_schema':t['parameters']} for t in tools]
    elif fmt=='responses':
        converted=[]
        for m in messages:
            if m.get('native_format')==fmt:converted.extend(copy.deepcopy(m['native_output']))
            elif m.get('role')=='tool':converted.append({'type':'function_call_output','call_id':m['tool_call_id'],'output':m['content']})
            else:
                if m.get('content'):converted.append({'role':m['role'],'content':m['content']})
                converted.extend({'type':'function_call','call_id':t['id'],'name':t['name'],'arguments':json.dumps(t['arguments'],ensure_ascii=False)} for t in m.get('tool_calls',[]))
        body={'model':model,'input':converted,'max_output_tokens':cap,'reasoning':{'effort':effort,'summary':'auto'},
              'store':False,'include':['reasoning.encrypted_content']}
        if tools:body.update(tools=[{'type':'function',**t} for t in tools],parallel_tool_calls=False)
    else:
        converted=[]
        for m in messages:
            item={k:m[k] for k in ('role','content','tool_call_id') if k in m}
            if m.get('tool_calls'):item['tool_calls']=[{'id':t['id'],'type':'function','function':{'name':t['name'],'arguments':json.dumps(t['arguments'],ensure_ascii=False)}} for t in m['tool_calls']]
            converted.append(item)
        body={'model':model,'messages':converted,'max_tokens':cap,'reasoning_effort':effort}
        native_minimax=urlsplit(config.get('endpoint','')).hostname in {'api.minimax.io','api.minimaxi.com','api.minimax.cn'} and model.startswith('MiniMax-')
        if config.get('protocol_profile')=='minimax' or native_minimax:
            # Explicit native compatibility profile; do not pass OpenAI effort
            # as if it were a verified MiniMax setting, or mix reasoning into JSON.
            body.pop('reasoning_effort',None)
            body.update(thinking={'type':'adaptive'},reasoning_split=True)
        if tools:body.update(tools=[{'type':'function','function':t} for t in tools],parallel_tool_calls=False)
    body['stream']=bool(config.get('stream',True))
    if system is not None:
        if not isinstance(system,str):raise ValueError('System instruction must be text')
        if fmt=='messages':body['system']=system
        elif fmt=='responses':body['instructions']=system
        else:body['messages'].insert(0,{'role':'system','content':system})
    if fmt=='chat_completions' and body['stream']:body['stream_options']={'include_usage':True}
    return body


def normalize_response(raw,fmt):
    text=[];calls=[];finish=None
    if fmt=='messages':
        finish=raw.get('stop_reason')
        for block in raw.get('content',[]):
            if block.get('type')=='text':text.append(block.get('text',''))
            elif block.get('type')=='tool_use':calls.append({'id':block['id'],'name':block['name'],'arguments':block.get('input',{})})
        native={'native_format':fmt,'native_message':{'role':'assistant','content':raw.get('content',[])}}
        complete=finish in {'end_turn','tool_use','stop_sequence'}
    elif fmt=='responses':
        finish=raw.get('status')
        for item in raw.get('output',[]):
            if item.get('type')=='message':text += [b.get('text','') for b in item.get('content',[]) if b.get('type')=='output_text']
            elif item.get('type')=='function_call':
                args=item.get('arguments',{})
                if isinstance(args,str):
                    try:args=json.loads(args)
                    except ValueError:args={'__invalid_arguments__':args}
                calls.append({'id':item.get('call_id',item.get('id')),'name':item.get('name'),'arguments':args})
        native={'native_format':fmt,'native_output':raw.get('output',[])}
        complete=finish=='completed'
    else:
        choices=raw.get('choices',[])
        if not choices:raise ProbeStop('missing_choice')
        finish=choices[0].get('finish_reason');message=choices[0].get('message',{})
        if isinstance(message.get('content'),str):text.append(message['content'])
        for item in message.get('tool_calls',[]):
            fn=item.get('function',{});args=fn.get('arguments',{})
            if isinstance(args,str):
                try:args=json.loads(args)
                except ValueError:args={'__invalid_arguments__':args}
            calls.append({'id':item.get('id'),'name':fn.get('name'),'arguments':args})
        native={};complete=finish in {'stop','tool_calls','function_call'}
    limited=finish in {'length','max_tokens','incomplete'}
    return {'text':'\n'.join(text),'tool_calls':calls,'finish_reason':finish,'completed':complete,
            'limited':limited,'response_model':raw.get('model'),'provider_response_id':raw.get('id'),
            'usage':raw.get('usage'),'assistant_message':{'role':'assistant','content':'\n'.join(text),'tool_calls':calls,**native}}


class StreamAccumulator:
    def __init__(self,fmt):
        self.fmt=fmt;self.final=None;self.parts={};self.msg={};self.chat_calls={};self.chat_text='';self.finish=None;self.usage=None
    def feed(self,e):
        typ=e.get('type')
        if typ=='error':raise ProbeStop('stream_error')
        if self.fmt=='responses':
            if typ in {'response.completed','response.incomplete','response.failed'}:self.final=e['response']
        elif self.fmt=='messages':
            if typ=='message_start':self.msg=copy.deepcopy(e['message'])
            elif typ=='content_block_start':self.parts[e['index']]=copy.deepcopy(e['content_block'])
            elif typ=='content_block_delta':
                block=self.parts[e['index']];delta=e['delta'];key={'text_delta':'text','thinking_delta':'thinking','signature_delta':'signature','input_json_delta':'partial_json'}.get(delta.get('type'))
                if key:block[key]=block.get(key,'')+delta.get(key,'')
            elif typ=='message_delta':self.msg.update(e.get('delta',{}));self.msg.setdefault('usage',{}).update(e.get('usage',{}))
            elif typ=='message_stop':
                for b in self.parts.values():
                    if b.get('type')=='tool_use' and 'partial_json' in b:
                        try:b['input']=json.loads(b.pop('partial_json'))
                        except ValueError:b['input']={'__invalid_arguments__':b.pop('partial_json','')}
                self.msg['content']=[self.parts[k] for k in sorted(self.parts)]
                if e.get('openrouter_metadata'):self.msg['openrouter_metadata']=e['openrouter_metadata']
                self.final=self.msg
        else:
            self.msg.update({k:e[k] for k in ('id','model','provider') if k in e})
            if e.get('usage') is not None:self.usage=e['usage']
            for c in e.get('choices',[]):
                if c.get('index',0)!=0:continue
                d=c.get('delta',{});self.chat_text+=d.get('content') or ''
                if c.get('finish_reason'):self.finish=c['finish_reason']
                for item in d.get('tool_calls',[]):
                    entry=self.chat_calls.setdefault(item.get('index',0),{'id':'','type':'function','function':{'name':'','arguments':''}})
                    if item.get('id'):entry['id']=item['id']
                    for key in ('name','arguments'):entry['function'][key]+=item.get('function',{}).get(key,'')
    def done(self):
        if self.fmt=='chat_completions' and self.finish:
            self.final={**self.msg,'usage':self.usage,'choices':[{'index':0,'finish_reason':self.finish,'message':{'role':'assistant','content':self.chat_text,'tool_calls':[self.chat_calls[k] for k in sorted(self.chat_calls)]}}]}
        return self.final


class ProbeClient:
    """One client per paid run; replay never consumes a live call allowance."""
    def __init__(self,config,output_dir,progress=None,cancelled_check=None):
        self.config=dict(config or {})
        if self.config.get('purpose','target') not in {'target','judge'}:raise ValueError('Invalid billing role')
        self.output=Path(output_dir);self.output.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.progress=progress or (lambda *a,**k:None);self.cancelled=cancelled_check or (lambda:False)
        self.mode=self.config.get('transport_mode','replay');self.format=self.config.get('api_format','responses')
        if self.mode not in {'live','replay'} or self.format not in FORMATS:raise ValueError('Invalid transport mode/format')
        self.max_requests=self.config.get('max_requests',10);self.max_cost=money(self.config.get('max_cost_usd','0'))
        if type(self.max_requests) is not int or not 1<=self.max_requests<=64:raise ValueError('请求数上限必须为1–64整数')
        self.spent=Decimal(0);self.reported_spent=Decimal(0);self.estimated_spent=Decimal(0);self.pending=Decimal(0);self.records=[];self.started=time.monotonic()
        self.wall=min(3600,max(1,int(self.config.get('wall_seconds',900))))
        self.replay=list(self.config.get('replay_records',[]));self.replay_pos=0
        if self.mode=='live':
            if self.config.get('allow_live') is not True:raise ValueError('Live probe requires explicit consent')
            parsed=urlsplit(self.config.get('endpoint',''))
            local=parsed.scheme=='http' and parsed.hostname in {'127.0.0.1','localhost','::1'} and self.config.get('allow_local_http') is True
            if (parsed.scheme!='https' and not local) or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query:
                raise ValueError('Use an explicit HTTPS endpoint without embedded credentials/query')
            if not isinstance(self.config.get('api_key'),str) or not self.config['api_key']:raise ValueError('API key required; no research key is inferred')
            self.input_rate=money(self.config.get('input_usd_per_million'));self.output_rate=money(self.config.get('output_usd_per_million'))
        else:self.input_rate=self.output_rate=Decimal(0)
        self.cache_read_rate=money(self.config.get('cache_read_usd_per_million',self.input_rate))
        self.cache_write_rate=money(self.config.get('cache_write_usd_per_million',self.input_rate*2 if self.format=='messages' else self.input_rate))

    def _emit(self,stage,row,*,final=False):
        write_json(self.output/'calls.json',self.records)
        write_json(self.output/'accounting.json',self.accounting())
        billing={'reservation_usd':row.get('reserved_usd','0'),
                 'reported_cost_usd':row.get('reported_cost_usd'), 'estimated_cost_usd':row.get('estimated_cost_usd'),
                 'pending_reserved_usd':row.get('pending_reserved_usd','0'),
                 'reservation_released':row.get('reservation_released',False),
                 'accounting':row.get('accounting','reserved'),'usage_scope':row.get('usage_scope','not_observed')}
        checkpoint={'stage':stage,'message':f'探针请求 {len(self.records)}/{self.max_requests}',
                    'billing_schema':'tokenclock-probe-billing-checkpoint/v1','client_request_id':row['client_request_id'],
                    'request_number':row['number'],'requests':len(self.records),'purpose':row.get('purpose','target'),'request_billing':billing,
                    'reserved_cost_usd':billing['pending_reserved_usd'],
                    'reported_cost_usd':billing['reported_cost_usd'],'estimated_cost_usd':billing['estimated_cost_usd'],
                    'reservation_released':billing['reservation_released'],'probe_billing':True,'record_status':row['status'],
                    'totals':{'reported_cost_usd':str(self.reported_spent),'estimated_cost_usd':str(self.estimated_spent),
                              'pending_reserved_usd':str(self.pending),'budget_accounted_usd':str(self.spent)}}
        try:self.progress(checkpoint)
        except Exception as exc:
            row['progress_callback_error_type']=type(exc).__name__
            write_json(self.output/'calls.json',self.records)
            if not final:raise

    def request(self,body,context=None):
        cancelled(self.cancelled)
        if time.monotonic()-self.started>=self.wall:raise ProbeStop('run_wall_limit')
        if len(self.records)>=self.max_requests:raise ProbeStop('request_count_limit')
        if self.pending:raise ProbeStop('unsettled_previous_request')
        data=canonical(body)
        quote=quote_request({**self.config,'transport_mode':self.mode},body,context)
        cap=quote['output_tokens'];upper=quote['input_upper_for_cost'];additional=quote['separate_image_token_allowance']
        estimate=money(quote['reserved_usd'])
        if self.mode=='live' and self.spent+estimate>self.max_cost:raise ProbeStop('budget_cannot_reserve_full_request',{'required_usd':str(estimate),'remaining_usd':str(self.max_cost-self.spent)})
        number=len(self.records)+1;row={'number':number,'client_request_id':'tc-'+uuid.uuid4().hex,
             'request_sha256':digest(body),'requested_model':body.get('model'),'api_format':self.format,
             'status':'reserved','context':context or {},'transport_mode':self.mode,'purpose':self.config.get('purpose','target'),
             'reserved_usd':str(estimate if self.mode=='live' else 0),'request_limits':{'output_tokens':cap,'input_upper_for_cost':upper,
                 'serialized_body_bytes':len(data),'separate_image_token_allowance':additional}}
        row.update(dispatched=False,reported_cost_usd=None,estimated_cost_usd=None,
                   pending_reserved_usd=row['reserved_usd'],reservation_released=self.mode=='replay',
                   accounting='reserved' if self.mode=='live' else 'replay_no_live_charge')
        self.records.append(row)
        if self.mode=='live':self.pending=estimate
        start=time.monotonic();events=[]
        try:
            write_json(self.output/f'{number:03d}-request.json',body)
            self._emit('probe_request_reserved',row)
            cancelled(self.cancelled)
            if self.mode=='replay':
                if self.replay_pos>=len(self.replay):raise ProbeStop('replay_exhausted')
                entry=self.replay[self.replay_pos]
                if entry.get('request_sha256')!=digest(body):raise ProbeStop('replay_request_mismatch')
                expected=entry.get('workspace_sha256')
                if expected is not None and expected!=(context or {}).get('workspace_sha256'):raise ProbeStop('replay_workspace_mismatch')
                self.replay_pos+=1
                row.update(source_kind='replay_record',recorded_source_kind=entry.get('source_kind','synthetic_fixture'),record_origin_label=entry.get('record_origin_label'),
                    origin_note='Known selection of a stored record, not a new live backend identity')
                if entry.get('error'):raise ProbeStop(entry['error'])
                raw=copy.deepcopy(entry['response']);events=copy.deepcopy(entry.get('events',[]));headers=copy.deepcopy(entry.get('headers',{}))
                row['http_status']=entry.get('http_status',200)
            else:
                row.update(status='dispatching');self._emit('probe_request_started',row)
                cancelled(self.cancelled)
                headers={'Authorization':'Bearer '+self.config['api_key'],'Content-Type':'application/json','Accept':'text/event-stream' if body.get('stream') else 'application/json',
                         'x-opencode-session':row['client_request_id']}
                if self.format=='messages':headers.update({'x-api-key':self.config['api_key'],'anthropic-version':'2023-06-01'})
                req=Request(self.config['endpoint'],data=data,headers=headers,method='POST')
                idle=min(60,max(1,int(self.config.get('idle_seconds',30))))
                request_wall=min(self.wall-(time.monotonic()-self.started),max(idle,int(self.config.get('request_wall_seconds',600))))
                # Past this boundary a failed connection may already have
                # reached the provider; retain unknown fees conservatively.
                row.update(status='dispatched',source_kind='live_api',dispatched=True)
                write_json(self.output/'calls.json',self.records)
                with build_opener(NoRedirect()).open(req,timeout=min(idle,request_wall)) as response:
                    row['http_status']=response.status
                    headers={k:response.headers.get(k) for k in ('request-id','x-request-id','x-model','content-type','openrouter-generation-id') if response.headers.get(k)}
                    row['headers']=headers
                    actual_stream='text/event-stream' in response.headers.get('content-type','').lower()
                    row.update(stream_requested=body.get('stream',False),stream_observed=actual_stream)
                    raw,events=self._read(response,start,request_wall,actual_stream,number)
            write_json(self.output/f'{number:03d}-response.json',raw)
            write_json(self.output/f'{number:03d}-events.json',events)
            self._settle(row,raw.get('usage') if isinstance(raw,dict) else None,final=True)
            normalized=normalize_response(raw,self.format)
            row.update(status='completed' if normalized['completed'] else 'limited' if normalized['limited'] else 'incomplete',
                       response_model=normalized['response_model'],provider_response_id=normalized['provider_response_id'],
                       finish_reason=normalized['finish_reason'],usage=normalized['usage'],headers=headers,elapsed_seconds=time.monotonic()-start)
            if self.cancelled():
                row['status']='cancelled_after_response'
                self._emit('probe_request_finished',row,final=True)
                raise ProbeStop('cancelled')
            self._emit('probe_request_finished',row,final=True)
            cancelled(self.cancelled)
            return {**normalized,'record':copy.deepcopy(row),'events':events,'raw_response':raw}
        except Exception as exc:
            code=exc.code if isinstance(exc,ProbeStop) else 'cancelled' if self.cancelled() or isinstance(exc,InterruptedError) or type(exc).__name__ in {'JobCancelled','AnalysisCancelled'} else 'http_error' if isinstance(exc,HTTPError) else 'network_timeout' if isinstance(exc,(TimeoutError,socket.timeout)) else 'request_failed'
            row.update(status=code,error_type=type(exc).__name__,elapsed_seconds=time.monotonic()-start)
            if isinstance(exc,HTTPError):
                row['http_status']=exc.code
                row['headers']={k:exc.headers.get(k) for k in ('request-id','x-request-id','x-model','content-type','openrouter-generation-id') if exc.headers and exc.headers.get(k)}
                try:
                    error_bytes=exc.read(1024*1024)
                    error_path=self.output/f'{number:03d}-error-raw.bin'
                    fd=os.open(error_path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|getattr(os,'O_NOFOLLOW',0),0o600)
                    with os.fdopen(fd,'wb') as saved:saved.write(error_bytes)
                    row.update(error_response_bytes=len(error_bytes),error_capture_limit_bytes=1024*1024,
                               error_capture_limit_reached=len(error_bytes)==1024*1024)
                    error_body=json.loads(error_bytes)
                    write_json(self.output/f'{number:03d}-error-response.json',error_body)
                    if isinstance(error_body,dict) and isinstance(error_body.get('usage'),dict):
                        self._settle(row,error_body['usage'],final=True)
                except (ValueError,OSError,ProbeStop):pass
                finally:exc.close()
            if not row.get('reservation_released') and isinstance(row.get('partial_usage'),dict):
                try:self._settle(row,row['partial_usage'],final=False)
                except (ValueError,ProbeStop):pass
            if self.mode=='live' and not row.get('dispatched'):
                self.pending=Decimal(0)
                row.update(pending_reserved_usd='0',reservation_released=True,accounting='cancelled_or_failed_before_dispatch_no_charge')
            self._emit('probe_request_failed',row,final=True)
            raise ProbeStop(code,{'request_number':number,'pending_usd':str(self.pending)}) from None

    def _settle(self,row,usage,*,final=True):
        if self.mode=='replay':
            row.update(accounting='replay_no_live_charge',charged_usd='0',pending_reserved_usd='0',reservation_released=True,usage_scope='historical_record_not_new_charge');return
        charge=None;kind=None
        if isinstance(usage,dict):
            if usage.get('cost') is not None:charge=money(usage['cost']);kind='response_reported_cost'
            else:
                inp=usage.get('input_tokens',usage.get('prompt_tokens'));out=usage.get('output_tokens',usage.get('completion_tokens'))
                if type(inp) is int and inp>=0 and type(out) is int and out>=0:
                    cache_charge=Decimal(0)
                    if self.format=='messages':
                        # Cache input is separately billed; missing fields are
                        # not silently assumed zero for reconciliation.
                        cache=[usage.get('cache_read_input_tokens'),usage.get('cache_creation_input_tokens')]
                        if any(type(x) is not int or x<0 for x in cache):inp=None
                        else:cache_charge=Decimal(cache[0])*self.cache_read_rate+Decimal(cache[1])*self.cache_write_rate
                    if inp is not None:
                        charge=(Decimal(inp)*self.input_rate+Decimal(out)*self.output_rate+cache_charge)/Decimal(1000000);kind='configured_rate_estimate'
                        row['estimate_policy']='Configured rates; absent cache read/write rates use conservative input-rate defaults, not a provider invoice.'
        if charge is None:
            row['accounting']='unsettled_reservation_retained';return
        prior_reported=money(row.get('reported_cost_usd') or 0)
        prior_estimated=money(row.get('estimated_cost_usd') or 0)
        # A later null cannot erase a known report; reported billing has
        # priority over a configured-rate estimate for the same request.
        if kind=='configured_rate_estimate' and row.get('reported_cost_usd') is not None:return
        if not final:charge=max(charge,prior_reported if kind=='response_reported_cost' else prior_estimated)
        self.reported_spent-=prior_reported;self.estimated_spent-=prior_estimated
        row.update(accounting=kind,charged_usd=str(charge),reported_cost_usd=str(charge) if kind=='response_reported_cost' else None,
                   estimated_cost_usd=str(charge) if kind=='configured_rate_estimate' else None,
                   usage_scope='final_visible_usage' if final else 'last_visible_partial_usage')
        if kind=='response_reported_cost':self.reported_spent+=charge
        else:self.estimated_spent+=charge
        self.spent=self.reported_spent+self.estimated_spent
        reserved=money(row['reserved_usd'])
        self.pending=Decimal(0) if final else max(Decimal(0),reserved-charge)
        row.update(pending_reserved_usd=str(self.pending),reservation_released=final)
        if charge>reserved:row['billing_bound_exceeded']=True;raise ProbeStop('billing_bound_exceeded')

    def _read(self,response,start,wall,stream,number):
        maximum=24*1024*1024;total=0;events=[];buf=b'';lines=[]
        acc=StreamAccumulator(self.format);parts=[];terminal=False
        row=self.records[number-1]
        raw_path=self.output/f'{number:03d}-raw.bin'
        raw_path.touch(mode=0o600,exist_ok=True);raw_path.chmod(0o600)
        try:
            with raw_path.open('wb') as saved:
                while True:
                    cancelled(self.cancelled)
                    if time.monotonic()-start>wall:raise ProbeStop('request_wall_limit')
                    chunk=response.read1(65536)
                    if not chunk:break
                    total+=len(chunk)
                    if total>maximum:raise ProbeStop('response_storage_limit')
                    saved.write(chunk)
                    if not stream:parts.append(chunk);continue
                    buf+=chunk
                    if len(buf)>2*1024*1024:raise ProbeStop('stream_event_size_limit')
                    while b'\n' in buf:
                        line,buf=buf.split(b'\n',1);line=line.rstrip(b'\r')
                        if line.startswith(b'data:'):lines.append(line[5:].lstrip())
                        elif not line and lines:
                            payload=b'\n'.join(lines);lines=[]
                            if payload==b'[DONE]':terminal=True;break
                            e=json.loads(payload)
                            events.append({'elapsed_seconds':time.monotonic()-start,'event':e})
                            candidate=e.get('response',e.get('message',e))
                            if isinstance(candidate,dict):
                                if isinstance(candidate.get('usage'),dict):row.setdefault('partial_usage',{}).update(candidate['usage'])
                                if candidate.get('model') is not None:row['response_model']=candidate['model']
                                if candidate.get('id') is not None:row['provider_response_id']=candidate['id']
                            acc.feed(e)
                            if isinstance(acc.usage,dict):row['partial_usage']=copy.deepcopy(acc.usage)
                            if isinstance(acc.msg.get('usage'),dict):row['partial_usage']=copy.deepcopy(acc.msg['usage'])
                            if self.format in {'messages','responses'} and acc.final is not None:terminal=True;break
                    if terminal:break
        finally:
            write_json(self.output/f'{number:03d}-events.json',events)
            if isinstance(row.get('partial_usage'),dict):write_json(self.output/f'{number:03d}-partial-usage.json',row['partial_usage'])
            write_json(self.output/'calls.json',self.records)
        if not stream:return json.loads(b''.join(parts)),events
        final=acc.done()
        if not terminal or final is None:raise ProbeStop('stream_without_terminal_event')
        return final,events

    def accounting(self):
        return {'requests':len(self.records),'live_requests':sum(r.get('source_kind')=='live_api' for r in self.records),
                'reported_cost_usd':str(self.reported_spent),'estimated_cost_usd':str(self.estimated_spent),
                'reported_or_estimated_usd':str(self.spent),'budget_accounted_usd':str(self.spent),
                'pending_reserved_usd':str(self.pending),
                'max_cost_usd':str(self.max_cost),'mode':self.mode,'no_automatic_retries':True}
