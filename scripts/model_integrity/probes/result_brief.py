"""A single presentation card from an existing synthesis, never a new grader.

The full report remains untouched. This module does not follow evidence refs,
rank models, dispatch actions, read credentials, or estimate identity odds.
"""
from __future__ import annotations
import re
from ..l1.render import redact

SCHEMA='tokenclock-result-brief/v1'
SYNTHESIS_SCHEMA='tokenclock-evidence-synthesis/v1'
RECOMMENDATION_SCHEMA='tokenclock-next-detection/v1'
CATEGORIES=('source_conflicts','supporting','counterevidence','alternatives','gaps','observations')
GENERATION_LIMITS={'incomplete_generation','incomplete_sample','limited_output'}
DIMENSIONS={'behavior':'回答倾向','capability_delivery':'交付表现','process':'工作过程','resources':'资源投入'}
PROCESS_ISSUES={
    'process.test_exit_mismatch':('检查结果存在不一致','同次检查的退出码与返回内容不一致。'),
    'process.unverified_completion_claim':('部分完成声明缺少验证','部分完成声明没有对应的可见核验记录。'),
    'process.latest_change_unverified':('最近修改尚未见验证','最近一次修改之后，尚未看到对应的复验记录。'),
    'process.edit_outside_explicit_scope':('发现超出约定范围的修改','可见写入超出了任务明确允许的路径范围。'),
}


def _mapping(value):return value if isinstance(value,dict) else {}
def _array(value):return value if isinstance(value,list) else []


def _text(value,limit=150):
    if not isinstance(value,str):return ''
    text=redact(value)
    text=re.sub(r'https?://[^\s<>「」“”，。；]+','[地址已隐藏]',text,flags=re.I)
    text=re.sub(r'(?<!\w)/s/[A-Za-z0-9_-]{12,}/?','[本地会话地址已隐藏]',text)
    text=re.sub(r'(?<!\w)/(?:Users|Volumes|home|private|tmp|var|etc|opt|usr)/[^\s<>「」“”，。；]+','[本地路径已隐藏]',text)
    return ' '.join(text.split())[:limit]


def _entries(subject,category):
    return [row for row in _array(subject.get(category)) if isinstance(row,dict) and _text(row.get('text'))]


def _kinds(subject):
    return {row.get('kind') for category in CATEGORIES for row in _entries(subject,category) if isinstance(row.get('kind'),str)}


def _boundaries(subject):
    kinds=_kinds(subject);state=_mapping(subject.get('conclusion')).get('state')
    return {'demo':state=='demonstration' or 'controlled_input'in kinds,
            'generation_limited':bool(kinds & GENERATION_LIMITS),
            'reference_overlap':'reference_sample_overlap'in kinds,
            'assisted':'assisted_interpretation'in kinds or any(row.get('model_assisted')is True for c in CATEGORIES for row in _entries(subject,c)),
            'contextual':any(row.get('comparison_scope')=='contextual_reference_comparison' or
                             row.get('scope')=='contextual_reference_comparison' or
                             row.get('recorded_scope')=='contextual_reference_comparison'
                             for c in ('supporting','counterevidence')for row in _entries(subject,c)),
            'imported':any(row.get('scope')=='imported_report_claim'for c in CATEGORIES for row in _entries(subject,c))}


def _reason(entry,category):
    kind=entry.get('kind')
    known={
        'model_declaration_difference':'同一调用的请求与响应型号声明不一致。',
        'source.model_claim_difference':'请求与响应记录中的型号声明不一致。',
        'source.billing_claim_difference':'计费记录与调用记录中的型号声明不一致。',
        'source.binding_collision':'同一个记录标识对应了不同内容。',
        'declaration_alignment':'可见请求与响应的型号声明一致。',
        'equal_reference_distance':'共同参考的距离相同，暂未形成区分方向。',
        'reference_sample_overlap':'样本标识与参考记录重合，不能算作一次新的验证。',
        'incomplete_generation':'没有获得或确认完整的生成结果。',
        'incomplete_sample':'至少一份回答在记录的限制下未完成。',
        'limited_output':'输出在记录的限制下未完成。',
        'mandatory_check_unknown':'仍有必需的本地检查没有完成。',
        'local_check_failed':'本次交付有具体的本地检查未通过。',
        'missing_declared_model':'没有唯一且明确的申报型号。',
        'multiple_declared_models':'同一输入组包含多个申报型号，尚未唯一绑定。',
        'declared_model_not_in_panel':'申报型号尚未对应到当前可比参考。',
        'missing_panel_measurements':'共同测量存在缺失，无法给出单一方向。',
        'ordinary_session_not_task_reference':'已有会话缺少同题、同条件的型号参考。',
        'capture_incomplete':'无法确认会话记录是否完整。',
        'missing_route_fields':'没有可见的逐调用路由或回退字段。',
        'assisted_interpretation':'部分字段由模型辅助解析，解释本身仍可能有误。',
        'provider_or_gateway_change':'供应商或网关变化也可能解释服务字段差异。',
        'same_model_supplier_change':'同一型号也可能切换供应商。',
        'network_buffering_latency':'网络、排队和缓冲也会影响等待时间与分块。',
        'conditions_or_measurement_difference':'生成条件或测量方式差异也可能影响参考方向。',
        'controlled_input':'这些是演示或受控输入，不是真实模型的新样本。',
        'interpretation_without_panel':'已有解释缺少对应的可比面板，暂不能独立核对。',
        'missing_interpretation_panel':'缺少对应的可比面板，尚不能确认解释适用的范围。',
    }
    if kind=='reference_distance_direction':
        dimension=DIMENSIONS.get(entry.get('dimension'),'部分已测特征')
        if category=='supporting':return dimension+'在当前共同项目上更接近其他型号的参考。'
        if category=='counterevidence':return dimension+'在当前共同项目上更接近申报型号的参考。'
        return dimension+'已有局部数值观察，但当前不能将它归因为型号偏离。'
    return known.get(kind) or _text(entry.get('text'))


def _reasons(subject,categories,first=()):
    output=[]
    for text in first:
        clean=_text(text)
        if clean and clean not in output:output.append(clean)
    for category in categories:
        for entry in _entries(subject,category):
            clean=_text(_reason(entry,category))
            if clean and clean not in output:output.append(clean)
            if len(output)>=3:return output[:3]
    return output[:3]


def _next_action(recommendation,*,allow=True):
    none={'kind':'none'}
    r=_mapping(recommendation)
    if not allow or r.get('schema')!=RECOMMENDATION_SCHEMA or r.get('automatic_dispatch')is not False:return none
    if r.get('status')=='needs_configuration':return {'kind':'configure','label':'配置检测'}
    if r.get('status')!='recommended' or _array(r.get('stop_reasons')):return none
    actions=_array(r.get('actions'))
    if not actions or not isinstance(actions[0],dict):return none
    identifier=actions[0].get('id')
    if (not isinstance(identifier,str) or redact(identifier)!=identifier or
        not re.fullmatch(r'next-(?:[NCO]\d{2}-[AB]|H0[1-4](?:-ascii)?)',identifier)):return none
    # Return only the existing action ID; neither its patch nor connection data
    # is copied. The UI may configure it, and must still preview before sending.
    return {'kind':'recommendation','id':identifier,'label':'配置下一步检测'}


def _recorded_delivery_pass(result):
    """Read a completed score, rejecting contradictory recorded flags; no scoring."""
    score=_mapping(result.get('score'))
    if result.get('task_id')not in {'H01','H02'} or score.get('full_task_pass')is not True or score.get('mandatory_unknown')is not False:
        return False
    if score.get('invalid_checks'):return False
    counts=_mapping(score.get('group_counts'))
    if counts.get('fail',0) or counts.get('unknown',0):return False
    for group in _array(score.get('groups')):
        if isinstance(group,dict) and (group.get('status')in{'fail','unknown'} or group.get('mandatory_unknown')):return False
    for check in _array(result.get('checks')):
        if isinstance(check,dict) and (check.get('status')=='fail' or (check.get('status')=='unknown' and check.get('mandatory',True))):return False
    return True


def build_brief(report):
    report=_mapping(report);result=_mapping(report.get('result'))
    user=_mapping(report.get('user_summary'))
    synthesis=_mapping(user.get('synthesis'))
    subjects=[s for s in _array(synthesis.get('subjects'))if isinstance(s,dict)] if synthesis.get('schema')==SYNTHESIS_SCHEMA else []
    explicit_demo=(_mapping(report.get('scope')).get('synthetic')is True or _mapping(result.get('scope')).get('synthetic')is True or
                   result.get('source_scope')=='scripted_demo' or _mapping(result.get('source')).get('kind')in{'synthetic_fixture','scripted_demo','controlled_variant'} or
                   _mapping(report.get('source')).get('kind')in{'synthetic_fixture','scripted_demo','controlled_variant'})
    card={'schema':SCHEMA,'status':'insufficient_evidence','title':'暂时还不能下结论',
          'summary':'当前缺少足够且可绑定的来源记录或共同参考。',
          'reasons':[],'caveat':'没有形成判断，不等于型号正常或已经得到认证。',
          'next_action':_next_action(user.get('recommendation'))}
    if not subjects:
        if explicit_demo:
            card.update(status='demonstration',title='这是演示结果',summary='用于展示检测与解释流程。',
                        reasons=[],caveat='合成记录不代表真实模型的检测结论。')
            card['next_action']=_next_action(user.get('recommendation')) if _mapping(user.get('recommendation')).get('status')=='needs_configuration' else {'kind':'none'}
            return card
        return card
    if len(subjects)>1:
        boundaries=[_boundaries(s)for s in subjects]
        reasons=[]
        conflict_count=sum(bool(_entries(s,'source_conflicts')) or _mapping(s.get('conclusion')).get('state')=='source_conflict'for s in subjects)
        mixed_count=sum(_mapping(s.get('conclusion')).get('state')=='mixed_local_directions'for s in subjects)
        if conflict_count:
            reasons.append('其中有对象的来源声明或调用绑定需要核对。')
        limits=[]
        if explicit_demo or any(b['demo']for b in boundaries):limits.append('演示或受控输入')
        if any(b['generation_limited']for b in boundaries):limits.append('未完成生成')
        if any(b['reference_overlap']for b in boundaries):limits.append('参考样本重合')
        if limits:reasons.append('其中还涉及'+'、'.join(limits)+'，需要分别查看适用范围。')
        labels={'source_conflict':'声明或绑定待核对','mixed_local_directions':'局部方向不一致',
                'local_deviation_signal':'有偏离申报的弱线索','local_declared_alignment':'局部观察与申报较一致',
                'observations_only':'已有局部观察，尚无型号方向','insufficient_evidence':'现有信息不足','demonstration':'演示或受控结果'}
        for index,subject in enumerate(subjects):
            if len(reasons)>=3:break
            name=_text(subject.get('label'),45) or '对象 '+str(index+1)
            state=_mapping(subject.get('conclusion')).get('state')
            reasons.append(name+'：'+labels.get(state,'结果需要单独查看')+'。')
        summary=f'已分别整理 {len(subjects)} 个对象的结果'
        if conflict_count:summary+=f'，其中 {conflict_count} 个存在来源或绑定差异'
        if mixed_count:summary+=f'，{mixed_count} 个局部方向不一致'
        summary+='。'
        card.update(status='multiple_subjects',title='这些结果涉及多个对象',
                    summary=summary,
                    reasons=reasons[:3],caveat='不同对象不能合成一个型号裁决，也不能用最严重的一项代表全部。',next_action={'kind':'none'})
        return card
    subject=subjects[0];state=_mapping(subject.get('conclusion')).get('state');b=_boundaries(subject)
    b['demo']|=explicit_demo
    conflicts=_entries(subject,'source_conflicts');categories=('observations','gaps','alternatives');process_issue=None;delivery_pass=False
    boundary_reasons=[]
    if b['demo']:boundary_reasons.append('这些是演示或受控输入，不代表真实模型的新检测。')
    if b['generation_limited']:boundary_reasons.append('生成没有完整完成，相关数值只能保留为局部观察。')
    if b['reference_overlap']:boundary_reasons.append('样本与参考记录重合，不算新的独立验证。')
    if conflicts or state=='source_conflict':
        card.update(status='source_conflict',title='发现来源声明或记录绑定差异',
                    summary='记录中的型号声明或调用绑定存在需要核对的差异。')
        categories=('source_conflicts','alternatives','gaps')
        # The source issue is primary; controlled/truncated/reused boundaries
        # still remain visible without presenting them as real-world fraud.
        card['reasons']=_reasons(subject,categories)
        if boundary_reasons:
            names=[name for key,name in [('demo','演示或受控输入'),('generation_limited','未完成生成'),('reference_overlap','参考样本重合')]if b[key]]
            boundary=boundary_reasons[0] if len(names)==1 else '这份记录还涉及：'+'、'.join(names)+'。'
            card['reasons']=(card['reasons'][:2]+[boundary])[:3]
    elif b['demo']:
        card.update(status='demonstration',title='这是演示结果',summary='用于展示检测与解释流程。')
    elif b['generation_limited']:
        card.update(status='generation_limited',title='这次生成还没有完整完成',summary='生成没有完整完成，已有回答和局部观察仍保留。')
    elif b['reference_overlap']:
        card.update(status='reference_overlap',title='这次观察与参考样本有重合',summary='样本标识与已有参考重合，相关数值观察仍已保留。')
    elif state=='mixed_local_directions':
        card.update(status=state,title='现有线索还没有指向同一方向',
                    summary='已有项目分别指向相对偏离和与申报较一致的方向。')
        first=[]
        for category in ('supporting','counterevidence'):
            entries=_entries(subject,category)
            if entries:first.append(_reason(entries[0],category))
        card['reasons']=_reasons(subject,('alternatives','gaps'),first)
    elif state=='local_deviation_signal':
        card.update(status=state,title='出现了偏离申报的弱线索',summary='部分已测特征更接近其他型号的参考表现。')
        categories=('supporting','alternatives','gaps')
    elif state=='local_declared_alignment':
        card.update(status=state,title='当前局部观察与申报较一致',summary='已测的部分共同特征更接近申报型号的参考表现。')
        categories=('counterevidence','gaps','alternatives')
    elif any(e.get('kind')=='local_check_failed'for e in _entries(subject,'observations')):
        card.update(status='delivery_issue',title='这次交付有未通过的检查',summary='本地检查发现了本次交付的具体问题。')
    elif (state in {'observations_only','insufficient_evidence'} and _recorded_delivery_pass(result)
          and not any(e.get('kind')=='mandatory_check_unknown'for e in _entries(subject,'gaps'))):
        delivery_pass=True
        card.update(status='observations_only',title='本次交付检查已通过',summary='现有评分记录显示，本次任务的全部必需本地检查均已通过。',reasons=[])
    elif state=='observations_only':
        card.update(status=state,title='已有一些局部观察，暂不能判断型号',summary='已有记录呈现了部分声明、服务处理或交付表现。')
        observed_kinds={row.get('kind')for row in _entries(subject,'observations')if isinstance(row.get('kind'),str)}
        process_issue=next((kind for kind in PROCESS_ISSUES if kind in observed_kinds),None)
        if process_issue:
            card['title'],card['summary']=PROCESS_ISSUES[process_issue]
        categories=('observations','counterevidence','gaps')
    if card['status']=='demonstration':
        card['reasons']=list(dict.fromkeys(_text(_reason(row,'observations'))for row in _entries(subject,'observations')
                                         if row.get('kind')!='controlled_input'))[:3]
    elif not card['reasons'] and not delivery_pass:card['reasons']=_reasons(subject,categories,boundary_reasons)
    if not card['reasons'] and card['status']!='demonstration' and not delivery_pass:
        card['reasons']=[{'source_conflict':'现有综合解释记录了需要核对的声明或绑定差异。',
            'local_deviation_signal':'现有综合解释记录了指向其他参考的局部方向。',
            'local_declared_alignment':'现有综合解释记录了与申报参考较一致的局部方向。',
            'mixed_local_directions':'现有综合解释保留了方向不同的局部观察。',
            'observations_only':'现有记录仍有局部观察价值，详细依据保留在报告中。'}.get(card['status'],'目前缺少能够绑定到这个对象的有效观察。')]
    if b['demo']:card['caveat']='演示、合成或受控结果不代表真实模型的检测结论。'
    elif b['generation_limited']:card['caveat']='生成受限可能影响表现，不能将未完成直接等同于能力不足。'
    elif b['reference_overlap']:card['caveat']='样本与参考重合，本次不增加独立验证证据。'
    elif conflicts or state=='source_conflict':card['caveat']='别名、版本名称或网关映射也可能造成声明差异，尚不能直接证明换型。'
    elif delivery_pass:card['caveat']='这些检查只覆盖本次交付，不认证真实后端型号。'
    elif process_issue:card['caveat']='这里只反映可见工作记录中的核验或范围问题，不用于认证后端型号。'
    elif b['contextual']:card['caveat']='生成条件或测量来源并不完全一致，这里只能保留局部弱线索。'
    elif b['assisted']:card['caveat']='辅助解析仍可能误读含义，也不会为原回答增加一份独立证据。'
    elif b['imported']:card['caveat']='这些是导入报告里的已有观察，来源声明尚未重新认证。'
    elif card['status']=='delivery_issue':card['caveat']='本地检查只覆盖这次交付，不能据此识别后端型号。'
    elif card['status']=='local_declared_alignment':card['caveat']='局部特征较一致，不代表真实后端型号已得到认证。'
    elif card['status']=='local_deviation_signal':card['caveat']='局部参考方向不是型号身份概率，也不是换型定论。'
    elif card['status']=='mixed_local_directions':card['caveat']='相关题族和同一原始回答的观察不能重复投票。'
    if card['status']in{'source_conflict','demonstration','generation_limited','reference_overlap'}:
        # Even an inconsistent imported recommendation cannot offer another paid
        # detection while this card says to inspect an unresolved boundary first.
        card['next_action']=_next_action(user.get('recommendation'),allow=card['status']=='demonstration') if _mapping(user.get('recommendation')).get('status')=='needs_configuration' else {'kind':'none'}
    return card
