"""Bounded, subject-scoped synthesis of already recorded weak evidence.

No model calls, reference writes, path dereferences, global identity scores or
majority votes. A source declaration conflict and a behavioral direction are
different observations and cannot cancel each other.
"""
from __future__ import annotations
from copy import deepcopy
import hashlib
import json
import math
from .reference_labels import reference_label

SCHEMA='tokenclock-evidence-synthesis/v1'
CATEGORIES=('source_conflicts','supporting','counterevidence','alternatives','gaps','observations')
CATEGORY_LABELS={'source_conflicts':'来源声明与绑定差异','supporting':'支持偏离的观察',
 'counterevidence':'反对偏离的观察','alternatives':'替代解释','gaps':'缺失证据','observations':'其他局部观察'}
DIMENSIONS={'behavior':'回答倾向','capability_delivery':'交付检查','process':'工作过程','resources':'资源投入'}
UNBOUND_SCOPES={'unbound_report_group','input_group_without_live_subject_binding','unmatched_session','unbound','declared_panel_group'}
MODEL_LABEL_SCOPES={'configured_endpoint_and_requested_model_not_attestation',
 'imported_model_declaration_within_input_group_not_attestation','declared_model','declared'}


def _text(value,limit=240):
    return ' '.join(value.split())[:limit] if isinstance(value,str) else ''


def _hash(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=False,sort_keys=True,default=str,separators=(',',':')).encode()).hexdigest()


def _number(value):return type(value)in(int,float) and math.isfinite(value) and 0<=value<=1
def _mapping(value):return value if isinstance(value,dict) else {}
def _array(value):return value if isinstance(value,list) else []


def _clean(value,seen=None,depth=0):
    """Stable duplicate-report identity, excluding derived explanations only."""
    if depth>16:return '[depth bound]'
    if isinstance(value,(dict,list)):
        seen=set() if seen is None else seen
        if id(value)in seen:return '[cycle]'
        seen=seen|{id(value)}
        if isinstance(value,dict):
            return {str(k):_clean(v,seen,depth+1)for k,v in value.items()if k not in {'user_summary','synthesis','recommendation'}}
        return [_clean(v,seen,depth+1)for v in value]
    return value


def synthesize(report,analysis_context=None):
    if not isinstance(report,dict):raise ValueError('Synthesis requires an existing report object')
    context=analysis_context if isinstance(analysis_context,dict) else report.get('analysis_context',{})
    context=context if isinstance(context,dict) else {}
    supplied_claims=context.get('subject_claims',{}) if isinstance(context.get('subject_claims',{}),dict) else {}
    subjects={};seen_reports=set();duplicates=0;leaves=0;bounded=False

    def make_subject(raw,leaf_hash,path,label=None):
        raw=raw if isinstance(raw,dict) else {}
        given=_text(raw.get('id'),200);scope=_text(raw.get('scope'),120)
        bound=bool(given and scope and scope not in UNBOUND_SCOPES)
        sid=given if bound else 'input-'+_hash([leaf_hash,given])[:24]
        if sid not in subjects:
            title=_text(raw.get('label')) or label or '未绑定输入 '+leaf_hash[:8]
            subjects[sid]={'subject_id':sid,'label':title,'declared_model':None,'claim_scope':'not_observed',
                'conclusion':{},**{k:[] for k in CATEGORIES},'evidence_groups':[],
                'identity_probability':None,'identity_authenticated':False,
                'binding_scope':scope if bound else 'separate_unbound_input',
                '_claims':set(),'_references':set(),'_entry_index':{},'_demo':False,'_ordinary':False,
                '_generation_limited':False,
                '_report_refs':[],'_reference_label':None}
        subject=subjects[sid]
        if path not in subject['_report_refs']:subject['_report_refs'].append(path)
        declared=_text(raw.get('declared_model'),200)
        if not declared and scope in MODEL_LABEL_SCOPES:declared=_text(raw.get('label'),200)
        if declared:subject['_claims'].add(declared);subject['claim_scope']='subject_model_declaration'
        explicit=supplied_claims.get(given,supplied_claims.get(sid))
        if isinstance(explicit,dict):
            value=_text(explicit.get('declared_model'),200)
            if value:subject['_claims'].add(value);subject['claim_scope']=_text(explicit.get('claim_scope')) or 'controller_supplied_declaration'
            reference=_text(explicit.get('reference_label'),200)
            if reference:subject['_reference_label']=reference
        return subject

    def add(subject,category,text,pointer,scope,group,kind,*,imported=False,extra=None,record_id=None):
        item={'text':text,'evidence_refs':[{'pointer':pointer}],'scope':'imported_report_claim' if imported else scope,
              'group':group,'kind':kind}
        if imported:item['recorded_scope']=scope
        if record_id:item['evidence_refs'][0]['record_id']=record_id
        if extra:item.update(extra)
        key=_hash([category,text,scope,group,kind,extra])
        previous=subject['_entry_index'].get(key)
        if previous is not None:
            for ref in item['evidence_refs']:
                if ref not in previous['evidence_refs']:previous['evidence_refs'].append(ref)
            return
        if len(subject[category])>=80:
            nonlocal bounded
            bounded=True;return
        subject['_entry_index'][key]=item;subject[category].append(item)

    def claim(subject):
        if len(subject['_claims'])==1:return next(iter(subject['_claims']))
        return None

    def source_observations(container,path,default,targets,request_map,imported):
        """Diagnostics pointers reference its saved observation, not source.refs."""
        for i,check in enumerate(container.get('checks',[]) if isinstance(container.get('checks'),list) else []):
            if not isinstance(check,dict):continue
            name=str(check.get('id',''));state=check.get('status');observed=check.get('observed') or {}
            observed=observed if isinstance(observed,dict) else {}
            ids={r.get('record_id')for r in _array(check.get('evidence'))if isinstance(r,dict) and isinstance(r.get('record_id'),str)}
            bound={sid for rid in ids for sid in request_map.get(rid,set())}
            subject=subjects[next(iter(bound))] if len(bound)==1 else default
            # A diagnostic record not linked to a target cannot be silently
            # applied to every target in a mixed report (it may be a judge call).
            if request_map and not bound:
                subject=make_subject({},_hash([path,next(iter(ids)) if len(ids)==1 else sorted(ids)]),path,'未绑定的服务调用记录')
            pointer=path+'/checks/'+str(i);rid=next(iter(ids)) if len(ids)==1 else None
            if name.startswith('model_declaration:'):
                wanted,reported=_text(observed.get('requested'),200),_text(observed.get('reported'),200)
                if wanted:subject['_claims'].add(wanted);subject['claim_scope']='visible_request_declaration'
                group='source:call:'+str(rid or _hash([wanted,reported])[:16])
                if state=='fail' and wanted and reported and wanted!=reported:
                    add(subject,'source_conflicts',f'同一可见调用请求「{wanted}」，响应声明「{reported}」；这是声明差异，尚不能直接认定换型。',pointer,'visible_call_declaration',group,'model_declaration_difference',imported=imported,record_id=rid)
                    add(subject,'alternatives','型号别名、版本名称或网关映射也可能造成声明差异，需要结合这条调用的路由记录核对。',pointer,'service_alternative',group,'alias_or_gateway_mapping',imported=imported)
                elif state=='pass' and wanted and reported==wanted:
                    add(subject,'counterevidence','这条可见调用的请求与响应型号声明一致；它反对“字段直接冲突”的判断，但不认证真实后端。',pointer,'visible_call_declaration',group,'declaration_alignment',imported=imported,record_id=rid)
                elif state=='unknown':add(subject,'gaps','请求或响应型号声明缺失，无法核对这条调用是否一致。',pointer,'capture_limitation',group,'missing_model_declaration',imported=imported)
            elif name.startswith('binding:') and state=='unknown':
                add(subject,'gaps','调用配对或生成范围未唯一绑定，暂不把这些记录归因到某个型号。',pointer,'capture_limitation','source:binding','ambiguous_call_binding',imported=imported)
            elif name.startswith('usage:') and state=='fail':
                add(subject,'observations','可见 token 计量字段与所声明的计量规则不一致；这属于服务记录信号。',pointer,'recorded_service_observation','service:usage','usage_inconsistency',imported=imported)
                add(subject,'alternatives','计量格式、缓存字段口径、缺失记录或网关转换都可能影响 token 算术；不能单凭它推断具体型号。',pointer,'service_alternative','service:usage','usage_schema_or_gateway',imported=imported)
        for i,obs in enumerate(container.get('observations',[]) if isinstance(container.get('observations'),list) else []):
            if not isinstance(obs,dict):continue
            rid=obs.get('request_id') if isinstance(obs.get('request_id'),str) else None;bound=request_map.get(rid,set())
            subject=subjects[next(iter(bound))] if len(bound)==1 else default
            if request_map and not bound and obs.get('type')=='source_fields':
                subject=make_subject({},_hash([path,rid]),path,'未绑定的服务调用记录')
            pointer=path+'/observations/'+str(i);kind=obs.get('type')
            if kind=='source_fields':
                fields=obs.get('response_fields') or {}
                if isinstance(fields,dict) and all(not isinstance(fields.get(k),dict) or fields[k].get('state') in {'missing','null'} for k in ('route','fallback','fallback_model','routed_model','upstream_model')):
                    add(subject,'gaps','本条调用没有可见路由或回退字段，当前缺少直接路由证据。',pointer,'capture_limitation','source:route-fields','missing_route_fields',imported=imported)
            elif kind=='session_visible_field_change':
                changes=obs.get('changes',{})
                if isinstance(changes,dict) and changes:
                    fields='、'.join(sorted(str(k) for k in changes)[:8])
                    add(subject,'observations','同一记录会话内可见字段发生变化：'+fields+'。变化范围仅限所保存的记录。',pointer,'recorded_service_observation','service:session-fields','session_field_change',imported=imported)
                    add(subject,'alternatives','同型号切换供应商、网关处理或版本命名变化，也可能造成这些字段变化；不自动等同于换型。',pointer,'service_alternative','service:session-fields','provider_or_gateway_change',imported=imported)
            elif kind=='client_stream_shape':
                add(subject,'observations','已保存客户端接收到的流式事件形态，可用于对比服务处理差异。',pointer,'recorded_service_observation','service:stream','stream_shape',imported=imported)
                add(subject,'alternatives','网络、排队、缓冲、SDK 和刷新策略会影响时延及分块；事件数和等待时间不是内部推理步骤数。',pointer,'service_alternative','service:stream','network_buffering_latency',imported=imported)
            elif kind=='completion' and obs.get('limited')is True:
                add(subject,'gaps','至少一份输出在所记录的限制下未完成；这不能直接作为能力不足的证据。',pointer,'capture_limitation','delivery:limits','limited_output',imported=imported)

    def panels_for(result,path,default,lookup,imported,ordinary):
        fingerprint=result.get('fingerprints') or {};fingerprint=fingerprint if isinstance(fingerprint,dict) else {}
        overlap=_mapping(fingerprint.get('reference_overlap'))
        panels=fingerprint.get('comparison_panels',[]) if isinstance(fingerprint.get('comparison_panels'),list) else []
        for i,panel in enumerate(panels):
            if not isinstance(panel,dict):continue
            sid=panel.get('subject_id') if isinstance(panel.get('subject_id'),str) else None;subject=default if ordinary else lookup.get(sid)
            if subject is None:
                subject=default if not sid else make_subject({'id':str(sid),'label':panel.get('subject_label'),'scope':panel.get('subject_scope','declared_panel_group')},_hash([path,sid]),path)
                lookup[sid]=subject
            pointer=path+'/fingerprints/comparison_panels/'+str(i)
            family=_text(panel.get('task_family')) or _text(panel.get('task_id')) or 'unknown-task'
            group='task-family:'+family;dimension=DIMENSIONS.get(panel.get('dimension'),'局部特征')
            mode=panel.get('mode');scope='local_reference_comparison' if mode=='strict' else 'contextual_reference_comparison'
            models=panel.get('per_model',[])
            if isinstance(models,dict):models=[{'model_label':k,**v}for k,v in models.items()if isinstance(v,dict)]
            models=[m for m in models if isinstance(m,dict)] if isinstance(models,list) else []
            if any(f.get('condition_notes') for m in models for f in _array(m.get('features')) if isinstance(f,dict)):
                scope='contextual_reference_comparison'
            labels=[_text(m.get('model_label'),200)for m in models]
            subject['_references'].update(labels)
            if not ordinary and not subject['_claims'] and subject['label']in labels:
                subject['_claims'].add(subject['label']);subject['claim_scope']='subject_label_declaration'
            if ordinary:
                add(subject,'gaps','普通会话没有对应同题的任务条件，本版不把它硬套进能力或具体型号参考。',pointer,'capture_limitation',group,'ordinary_session_not_task_reference',imported=imported);continue
            if len(models)<2 or len(set(labels))!=len(labels) or not all(labels):
                add(subject,'gaps',family+' 的可比候选不足或标签不唯一，无法形成相对方向。',pointer,'reference_coverage',group,'insufficient_candidate_panel',imported=imported);continue
            if not panel.get('feature_ids') or any(not _number(m.get('distance')) or (m.get('coverage') is not None and m.get('coverage')!=1) for m in models):
                add(subject,'gaps',family+' 的共同测量存在缺失，保留原始范围，不用单一接近方向概括。',pointer,'reference_coverage',group,'missing_panel_measurements',imported=imported);continue
            values={label:m['distance']for label,m in zip(labels,models)}
            low,high=min(values.values()),max(values.values());nearest=sorted(k for k,v in values.items()if abs(v-low)<1e-12)
            declared=claim(subject);reference=subject['_reference_label'] or reference_label(declared) or declared
            extra={'comparison_scope':scope,'task_family':family,'dimension':panel.get('dimension'),
                   'recorded_comparison_mode':mode,'model_assisted':panel.get('origin')=='model_assessed',
                   'declared_model':declared,'reference_label':reference,'distances':values,
                   'reference_label_basis':'controller_mapping' if subject['_reference_label'] else 'registered_reference_name' if reference_label(declared) else 'exact_declared_name',
                   'nearest_reference_labels':nearest,'not_independent_votes':True}
            if abs(high-low)<1e-12:
                add(subject,'observations',family+' · '+dimension+'在当前共同特征上的参考距离相同，没有形成偏离方向。',pointer,scope,group,'equal_reference_distance',imported=imported,extra=extra);continue
            text=family+' · '+dimension+'的当前观察在数值上更接近「'+' / '.join(nearest)+'」的已有参考。'
            from .direction_guard import evaluate
            guard=evaluate(panel)
            extra['direction_guard']=guard
            if panel.get('origin')=='model_assessed':text+=' 其中字段由模型辅助解析，解释本身仍可能有误。'
            if scope=='contextual_reference_comparison':text+=' 条件或测量来源不完全一致，只作情境参考。'
            category='observations'
            direction_kind='reference_distance_direction'
            if subject['_demo'] or panel.get('origin')=='scripted_demo':
                text+=' 这是受控或演示输入，不作为真实型号的支持或反对证据。'
            elif subject['_generation_limited']:
                text+=' 本组存在生成受限记录，面板与完整样本的对应范围未单独明确，只保留这项数值观察。'
            elif overlap.get('sample_identity_overlap')is True:
                text+=' 样本标识与参考重合，不计为新的独立验证。'
                add(subject,'gaps','本报告含与参考重合的样本，且没有逐面板的重合定位，不能把这些方向当作新的验证。',pointer,'reference_reuse_observation',group,'reference_sample_overlap',imported=imported)
            elif reference not in values:
                add(subject,'gaps','尚未将该对象的唯一申报型号绑定到这个参考候选集；不猜测型号别名。',pointer,'reference_coverage',group,'declared_model_not_in_panel',imported=imported)
            elif guard['status']!='repeat_supported':
                text+=' '+guard['reasons'][0]
                direction_kind='reference_direction_needs_review'
                add(subject,'gaps',guard['reasons'][0],pointer,'direction_admission',group,'reference_repeat_or_margin_missing',imported=imported)
            elif values[reference]>low+1e-12:
                category='supporting';text+=' 这是支持相对申报偏离的局部弱线索。'
            elif values[reference]<high-1e-12 and len(nearest)==1:
                category='counterevidence';text+=' 这是反对相对申报偏离的局部观察，不能认证型号。'
            else:text+=' 申报参考与其他候选并列最接近，未形成针对它们的区分方向。'
            add(subject,category,text,pointer,scope,group,direction_kind,imported=imported,extra=extra)
            if scope=='contextual_reference_comparison':
                add(subject,'alternatives','提示、生成设置、上下文、提取方式或版本差异，也可能解释此处的参考偏离。',pointer,'comparison_alternative',group,'conditions_or_measurement_difference',imported=imported)
            if panel.get('origin')=='model_assessed':
                add(subject,'alternatives','这些字段来自对原回答的辅助解析；解析误差和同渠道相关性仍可能影响方向，不增加独立证据票。',pointer,'assisted_observation',group,'assisted_interpretation',imported=imported)
        if not panels:
            for i,item in enumerate(_array(_mapping(result.get('fingerprint_interpretation')).get('statements'))):
                if isinstance(item,dict):
                    subject=lookup.get(item.get('subject_id'),default) if isinstance(item.get('subject_id'),str) else default
                    add(subject,'observations','保留已有局部解释：'+_text(item.get('text'),500),path+'/fingerprint_interpretation/statements/'+str(i),'unverified_interpretation','reference:unbound-statement','interpretation_without_panel',imported=imported)
                    add(subject,'gaps','缺少这段解释对应的可比面板，未将文字本身升级成支持或反对证据。',path+'/fingerprint_interpretation/statements/'+str(i),'reference_coverage','reference:unbound-statement','missing_interpretation_panel',imported=imported)

    def visit(wrapper,path='',imported=False,depth=0):
        nonlocal duplicates,leaves,bounded
        if not isinstance(wrapper,dict):return
        if depth>6 or leaves>=64:bounded=True;return
        result=wrapper.get('result') if isinstance(wrapper.get('result'),dict) else wrapper
        rp=path+'/result' if result is not wrapper else path
        components=result.get('components')
        if isinstance(components,list):
            for i,component in enumerate(components[:64]):
                if isinstance(component,dict):visit(component.get('report'),rp+'/components/'+str(i)+'/report',True,depth+1)
            if len(components)>64:bounded=True
            return
        fingerprint=_hash(_clean(wrapper))
        if fingerprint in seen_reports:duplicates+=1;return
        seen_reports.add(fingerprint);leaves+=1
        lane=wrapper.get('workflow_mode','l1' if result.get('facts') is not None else 'unknown')
        ordinary=lane=='l1';default=make_subject(result.get('subject'),fingerprint,rp,'已有会话 '+fingerprint[:8] if ordinary else None)
        default['_ordinary']|=ordinary
        lookup={result['subject']['id']:default} if isinstance(result.get('subject'),dict) and isinstance(result['subject'].get('id'),str) else {}
        request_map={};targets={};samples=result.get('samples',[]) if isinstance(result.get('samples'),list) else []
        demo=result.get('source_scope')=='scripted_demo' or _mapping(result.get('source')).get('kind')in{'scripted_demo','synthetic_fixture','controlled_variant'}
        default['_demo']|=demo
        for i,sample in enumerate(samples):
            if not isinstance(sample,dict):continue
            raw=sample.get('subject') if isinstance(sample.get('subject'),dict) else result.get('subject')
            subject=make_subject(raw,fingerprint,rp+'/samples/'+str(i)) if raw else default
            if isinstance(raw,dict) and isinstance(raw.get('id'),str):lookup[raw['id']]=subject
            targets[subject['subject_id']]=subject;subject['_demo']|=demo
            record=_mapping(sample.get('record'));requested=_text(record.get('requested_model'),200)
            if requested:subject['_claims'].add(requested);subject['claim_scope']='visible_request_declaration'
            rid=record.get('client_request_id')
            if isinstance(rid,str):request_map.setdefault(rid,set()).add(subject['subject_id'])
            meta=_mapping(sample.get('metadata'))
            subject['_demo']|=meta.get('source_scope')in{'scripted_demo','synthetic_fixture','controlled_variant'} or record.get('source_kind')in{'scripted_demo','synthetic_fixture','controlled_variant'}
            if meta.get('completed')is False or meta.get('truncated')is True or sample.get('status')in{'limited','failed','cancelled','truncated','incomplete'}:
                subject['_generation_limited']=True
                add(subject,'gaps','这份回答在已记录的限制下未完成，不能把它直接当作模型能力不符。',rp+'/samples/'+str(i),'capture_limitation','task-family:'+str(sample.get('task_id','unknown')).split(':')[0],'incomplete_sample',imported=imported)
        if samples and default['subject_id'] not in targets and not any(default[c] for c in CATEGORIES):
            subjects.pop(default['subject_id'],None)
            default=next(iter(targets.values())) if len(targets)==1 else make_subject({},fingerprint,rp,'尚未绑定到单一对象的记录')
        generation=_mapping(_mapping(result.get('generation')).get('record'))
        generation_checks=[(i,c)for i,c in enumerate(_array(result.get('checks')))if isinstance(c,dict) and c.get('id')=='generation.complete' and c.get('status')in{'unknown','fail'}]
        finish=generation.get('finish_reason');stop=_mapping(result.get('stop')).get('code')
        limit_reasons={'length','max_tokens','max_output_tokens','token_limit','generation_incomplete','output_token_limit'}
        if generation.get('status')in{'limited','incomplete','cancelled_after_response'} or (isinstance(finish,str) and finish in limit_reasons) or (isinstance(stop,str) and stop in limit_reasons) or generation_checks:
            default['_generation_limited']=True
            evidence_path=rp+'/generation/record' if generation else rp+'/checks/'+str(generation_checks[0][0]) if generation_checks else rp+'/stop'
            add(default,'gaps','该任务未获得或未确认完整的生成结果；旧面板的数值可以保留，但不据此直接判断能力或型号偏离。',evidence_path,'capture_limitation','delivery:generation','incomplete_generation',imported=imported)
        if isinstance(generation.get('client_request_id'),str):request_map.setdefault(generation['client_request_id'],set()).add(default['subject_id'])
        declared=_text(_mapping(result.get('source')).get('requested_model'),200) or _text(generation.get('requested_model'),200)
        if declared:default['_claims'].add(declared);default['claim_scope']='visible_request_declaration'
        for i,fact in enumerate(result.get('facts',[]) if isinstance(result.get('facts'),list) else []):
            if not isinstance(fact,dict):continue
            code=fact.get('code') if isinstance(fact.get('code'),str) else '';value=fact.get('value');pointer=rp+'/facts/'+str(i)
            value=value if isinstance(value,dict) else {};rid=_text(value.get('request_id'),200)
            group='source:call:'+rid if rid else 'l1:'+str(code)
            if code.startswith('source.harness_') or code=='source.comparison_target_difference':
                if code=='source.harness_model_observed':continue  # full field inventory is separate; do not crowd out differences
                from ..l1.model_fields import describe
                description=describe(code,value)
                if description:
                    add(default,'observations',description,pointer,'local_harness_declaration',
                        'source:harness:'+str(fact.get('generation_id') or 'session'),code,imported=imported)
                if code not in {'source.harness_model_observed','source.harness_model_consistent'}:
                    add(default,'alternatives','用户切换、轮次覆盖设置、重试或别名也可能造成记录差异；这些字段不证明实际后端权重。',
                        pointer,'harness_alternative','source:harness','harness_declaration_alternatives',imported=imported)
                continue
            if code in {'source.model_claim_difference','source.billing_claim_difference','source.binding_collision'}:
                wanted=_text(value.get('requested'),200);reported=_text(value.get('reported'),200)
                text=('请求与响应的型号声明不同：'+wanted+' / '+reported+'。') if code=='source.model_claim_difference' and wanted and reported else {
                    'source.model_claim_difference':'已保存请求与响应型号声明的差异。','source.billing_claim_difference':'已保存调用与计费型号声明的差异。','source.binding_collision':'相同记录标识对应不同内容，当前存在绑定冲突。'}[code]
                add(default,'source_conflicts',text+' 需核对原始绑定，不直接等同于换型。',pointer,'visible_call_declaration',group,str(code),imported=imported,record_id=rid or None)
            elif code=='source.provider_change':
                add(default,'observations','可见供应商声明发生变化。',pointer,'recorded_service_observation','service:provider',str(code),imported=imported)
                add(default,'alternatives','同型号可以切换供应商；供应商变化本身不能证明型号变化。',pointer,'service_alternative','service:provider','same_model_supplier_change',imported=imported)
            elif code in {'process.test_exit_mismatch','process.unverified_completion_claim','process.latest_change_unverified','process.edit_outside_explicit_scope'}:
                messages={'process.test_exit_mismatch':'检查退出码与返回内容存在差异。','process.unverified_completion_claim':'完成声明缺少对应的可见验证。','process.latest_change_unverified':'最近修改后没有看到对应复验。','process.edit_outside_explicit_scope':'可见写入超出了明确允许的路径。'}
                add(default,'observations',messages[code]+' 这是当前过程记录的局部信号，不能直接识别型号。',pointer,'visible_process_observation','l1:process',str(code),imported=imported)
        fields=result.get('model_declarations',{})
        if isinstance(fields,dict) and fields.get('schema')=='tokenclock-visible-model-fields/v1' and type(fields.get('total')) is int and fields['total']>0:
            add(default,'observations','已读取 '+str(fields['total'])+' 条结构化型号字段，原始位置已保留。',rp+'/model_declarations',
                'local_harness_declaration','source:harness','visible_harness_model_fields',imported=imported)
            if any(u.get('code')=='source.harness_response_missing' for u in result.get('unknowns',[]) if isinstance(u,dict)):
                add(default,'gaps','主请求型号已记录，缺少对应的主响应型号声明。',rp+'/model_declarations',
                    'capture_limitation','source:harness','missing_harness_response_model',imported=imported)
        diagnostics=result.get('diagnostics')
        if isinstance(diagnostics,dict):source_observations(diagnostics,rp+'/diagnostics',default,targets,request_map,imported)
        elif result.get('task_id')=='diagnostics':source_observations(result,rp,default,targets,request_map,imported)
        for i,check in enumerate(result.get('checks',[]) if isinstance(result.get('checks'),list) else []):
            if not isinstance(check,dict) or result.get('task_id')=='diagnostics':continue
            if check.get('dimension')in{'来源声明','provenance'}:continue
            group=str(check.get('group') or 'delivery:'+str(result.get('task_id','unknown')))
            if check.get('mandatory') and check.get('status')=='unknown':
                add(default,'gaps','必需检查「'+_text(check.get('id'))+'」尚未核验。',rp+'/checks/'+str(i),'capture_limitation',group,'mandatory_check_unknown',imported=imported)
            elif check.get('status')=='fail':
                add(default,'observations','本地检查「'+_text(check.get('id'))+'」未通过；它说明本次交付在该检查上的表现，不直接证明换型。',rp+'/checks/'+str(i),'local_delivery_check',group,'local_check_failed',imported=imported)
        if ordinary:
            add(default,'gaps','普通会话缺少同题、同条件的型号参考；当前过程观察不直接变成具体型号的支持或反对证据。',rp,'capture_limitation','l1:reference-scope','ordinary_session_not_task_reference',imported=imported)
            if _mapping(result.get('scope')).get('capture_complete')is not True:
                add(default,'gaps','会话记录完整性未得到确认，未记录的行为不能当作没有发生。',rp+'/scope' if 'scope'in result else rp,'capture_limitation','l1:capture','capture_incomplete',imported=imported)
        panels_for(result,rp,default,lookup,imported,ordinary)
        for s in list(targets.values()) or [default]:
            if demo:add(s,'observations','此输入属于脚本演示或受控变体；仅说明本次工程/核验行为，不代表新的真实模型样本。',rp,'demonstration','source:demonstration','controlled_input',imported=imported)
        if targets and default['subject_id']not in targets and not any(default[c]for c in CATEGORIES) and not default['_claims'] and not default['_references']:
            subjects.pop(default['subject_id'],None)

    visit(report)
    output=[]
    for subject in subjects.values():
        subject['declared_model']=claim(subject)
        if len(subject['_claims'])>1:
            add(subject,'gaps','这个输入组含多个不同的申报型号，尚未唯一绑定；不将其合成一个型号画像。',subject['_report_refs'][0],'capture_limitation','source:declaration-scope','multiple_declared_models')
            for category in ('supporting','counterevidence'):
                retained=[]
                for entry in subject[category]:
                    if entry['kind']=='reference_distance_direction':
                        entry['text']=entry['text'].replace(' 这是支持相对申报偏离的局部弱线索。','').replace(' 这是反对相对申报偏离的局部观察，不能认证型号。','')+' 本组申报未唯一绑定，只保留数值观察。'
                        entry['claim_attribution']='ambiguous';subject['observations'].append(entry)
                    else:retained.append(entry)
                subject[category]=retained
        if subject['declared_model'] is None and not subject['_ordinary']:
            add(subject,'gaps','没有唯一且明确的申报型号，局部参考方向仅作观察。',subject['_report_refs'][0],'reference_coverage','source:declaration-scope','missing_declared_model')
        if subject['_demo']:
            state,title,text='demonstration','受控输入的观察已整理','本组属于演示或受控输入，不形成真实型号的支持或反对结论。'
        elif subject['source_conflicts']:
            state,title,text='source_conflict','发现来源声明或绑定差异','先核对原始调用的声明与绑定；局部参考相近不能抵消这些差异，目前仍不直接认定换型。'
        elif subject['supporting'] and any(e['kind']=='reference_distance_direction'for e in subject['counterevidence']):
            state,title,text='mixed_local_directions','局部参考方向不一致','有支持偏离和反对偏离的局部观察，保留各自条件与相关题族，不按多数票判断型号。'
        elif subject['supporting']:
            state,title,text='local_deviation_signal','存在支持相对申报偏离的弱线索','部分共同可比特征更接近其他参考；这是局部弱信号，仍需结合条件差异、服务记录和未核验项目解释。'
            if all(e.get('comparison_scope')=='contextual_reference_comparison'for e in subject['supporting']):
                title='存在需结合条件解释的偏离线索'
        elif any(e['kind']=='reference_distance_direction'for e in subject['counterevidence']):
            state,title,text='local_declared_alignment','局部观察与申报参考较一致','当前部分共同特征更接近申报型号的参考，反对相对偏离的怀疑，但不能认证后端身份。'
        elif subject['observations'] or subject['counterevidence']:
            state,title,text='observations_only','已形成局部观察，尚无型号方向','已有记录可以解释部分声明、服务或交付表现，但当前不足以形成相对申报型号的可靠方向。'
            if any(e['kind']=='local_check_failed'for e in subject['observations']):title='发现未通过的本地交付检查'
            elif any(e['kind'].startswith('process.')for e in subject['observations']):title='发现过程声明或核验的局部问题'
            elif any(e['kind']=='equal_reference_distance'for e in subject['observations']):title='共同参考暂未形成区分方向'
            elif subject['counterevidence']:title='可见声明一致，尚不能认证型号'
        else:
            state,title,text='insufficient_evidence','当前缺少可归因的证据','尚缺少可以绑定到本对象的声明或共同参考；保留缺口，不用空结果表示型号正常。'
        subject['conclusion']={'state':state,'title':title,'text':text}
        groups={}
        for category in CATEGORIES:
            for entry in subject[category]:
                group=groups.setdefault(entry['group'],{'group':entry['group'],'categories':set(),'evidence_refs':[],'independent_votes_computed':False})
                group['categories'].add(category)
                for ref in entry['evidence_refs']:
                    if ref not in group['evidence_refs']:group['evidence_refs'].append(ref)
        subject['evidence_groups']=[{**g,'categories':sorted(g['categories'])}for g in groups.values()]
        output.append({k:v for k,v in subject.items()if not k.startswith('_')})
    return {'schema':SCHEMA,'hypothesis':'存在相对申报型号偏离的弱线索','category_labels':CATEGORY_LABELS,
            'subjects':output,'duplicate_reports_ignored':duplicates,'bounded_scope_reached':bounded,
            'identity_probability':None,'mixture_proportion':None,'independent_votes_computed':False,
            'limits':['层级表示取证方式，不表示证据强弱。','来源声明差异、局部参考方向、服务替代解释与缺失证据分开保留。',
                      '同题族和同一原始回答的多项观察不重复计票；不同未绑定输入不合成一个型号画像。',
                      '数值更接近仅描述当前共同特征；不输出身份概率、混用比例或换型定论。']}
