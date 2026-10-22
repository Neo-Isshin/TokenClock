"""User-facing conclusions follow evidence scope, not job completion or verbosity."""
from __future__ import annotations
from collections import Counter
from .assessment_quality import relationships_from_result, relationship_label
from .synthesis import synthesize, CATEGORY_LABELS


def summarize(report):
    result=report.get('result',report);lane=report.get('workflow_mode','l1')
    summary={'version':'model-detect-user-summary/v1','status':'observations_ready','title':'已整理本次观察',
             'findings':[],'limitations':[],'next_steps':[],'identity_authenticated':False}
    found,limits,steps=summary['findings'],summary['limitations'],summary['next_steps']
    if lane=='l1':
        source=report.get('summary',{}).get('source_status')
        facts=report.get('facts',[])
        conflicts=[f for f in facts if f.get('code') in {'source.model_claim_difference','source.billing_claim_difference','source.binding_collision'}]
        if conflicts:
            found.append('发现来源声明或调用绑定差异，请先查看对应原始记录。')
            steps.append('核对这些差异是否属于同一条调用，以及当时的型号别名；行为相近不能抵消来源差异。')
        concrete={
            'process.test_exit_mismatch':'工具退出码显示成功，但返回内容包含失败；系统已保留这个差异及后续检查。',
            'process.edit_outside_explicit_scope':'发现写入范围超出可见任务明确允许的路径，原指令和写入记录已保留。',
            'process.unverified_completion_claim':'部分完成声明缺少对应的可见核验依据；未记录的动作仍是可能原因。',
            'process.latest_change_unverified':'最近修改之后尚未见对应检查记录，不能据此确认修改已通过验证。',
            'source.provider_change':'供应商声明发生变化；这不能单独视为换成另一个型号。',
        }
        for code,message in concrete.items():
            if any(f.get('code')==code for f in facts):found.append(message)
        checks=report.get('verification_history',{})
        groups=checks.get('groups',[])
        if groups:
            found.append('已整理 '+str(len(groups))+' 组实际检查及其先后结果，历史失败继续保留。')
        if not found:found.append('已整理可见的来源、过程与语义记录；当前没有足以单独概括的明确异常。')
        if report.get('scope',{}).get('capture_complete') is not True:limits.append('会话完整性未得到独立确认；缺失部分不能当作没有执行。')
        limits.append('对旧会话的观察不认证真实后端型号。')
    if result.get('samples'):
        samples=result['samples'];partial=sum(s.get('metadata',{}).get('completed') is False or s.get('metadata',{}).get('truncated') is True or s.get('status') in {'limited','failed','cancelled'} for s in samples)
        found.append('已整理 '+str(len(samples))+' 份回答，分别保留题目、生成条件和提取结果。')
        if partial:limits.append(str(partial)+' 份回答带有未完成或受限记录，不据此认定模型能力不足。')
    score=result.get('score',{})
    if score:
        counts=Counter(g.get('status','unknown') for g in score.get('groups',[]))
        if counts:
            found.append('本地核验按相关证据分组：'+str(counts['pass'])+' 组通过、'+str(counts['fail'])+' 组未通过、'+str(counts['unknown'])+' 组未核验。')
        if score.get('full_task_pass') is True:found.append('当前任务的所有必需本地检查均通过；这说明本次交付通过这些检查。')
        elif score.get('mandatory_unknown') or score.get('score') is None:limits.append('仍有必需项目未核验，已检查部分的高分不等于整题通过。')
        if counts['fail']:steps.append('先看失败项的输入、输出和检查依据；确认是交付问题还是执行环境限制。')
    quality=result.get('assessment_quality') or result.get('reviewer_assessment',{}).get('quality')
    if quality:
        c=quality.get('coverage',{});usable=c.get('usable',0);unknown=c.get('unknown',0);disputed=c.get('disputed',0);contextual=c.get('contextual',0);excluded=c.get('excluded_by_local_conflict',0)
        found.append('模型评审：'+str(usable)+' 项可用于当前条件下的辅助比较，'+str(contextual)+' 项仅保留旧条件观察，'+str(unknown)+' 项缺少有效判断。')
        if disputed:limits.append(str(disputed)+' 项评审存在分歧，未强行选择一方。')
        if excluded:limits.append(str(excluded)+' 项评审意见与有充分依据的本地检查冲突，已从自动比较中排除，双方原记录保留。')
        if quality.get('status')=='no_usable_observations':
            summary['status']='partial_observations';limits.append('本次评审没有得到可用的语义观察；请求成功不等于评审有效。')
        if unknown or disputed or excluded:steps.append('查看评审未采用的具体原因；先处理缺少内容、错误引用或条件不匹配，再决定是否另做验证。')
        limits.append('模型评审是辅助意见，引用或格式核对通过不保证解释正确。')
    relations=relationships_from_result(result)
    if relations:
        summary['assessment_relationships']=relations
        for relation in relations[:3]:
            found.append('辅助解析连接：'+relationship_label(relation)+'。')
        limits.append('有引文且定义匹配的解析字段仍可用于描述性比较；它们来自原回答，不增加一份独立的型号证据。不同端点也不能证明供应商独立。')
        if any(r['same_endpoint'] is True for r in relations):
            limits.append('同端点承担解析职责不等于自己认证型号；客观核验照常保留，解析结果不会自动写入参考库。')
    visual=result.get('model_assessed_checks',[])
    if visual:
        names={'objects_recognizable':'对象可辨认','tie_adjustment':'整理领带动作','reflection_relation':'镜像关系','readability':'整体表达',
               'identity_consistency':'对象连续性','uphill_motion':'上坡移动','contact_support':'接触与支撑'}
        for status,label in [('pass','满足要求'),('fail','未满足要求')]:
            selected=[names.get(c.get('feature_id'),str(c.get('feature_id'))) for c in visual if c.get('status')==status]
            if selected:found.append('视觉评审认为：'+'、'.join(selected[:6])+label+'。这是辅助判断，原始观察已保留。')
        if any(c.get('status')=='fail' for c in visual):steps.append('可将上述具体关系作为本次交付的局部观察；不据单张作品认定后端型号。')
    fingerprint=result.get('fingerprints',{});overlap=fingerprint.get('reference_overlap',{})
    if overlap.get('sample_identity_overlap'):
        limits.append('检测到样本标识与参考记录重合，本次不计为独立验证。')
    elif overlap.get('answer_content_seen_in_reference'):
        limits.append('回答字面内容曾出现在参考中；短回答可能独立相同，不能仅据此认定同源。')
    scope=result.get('source_scope')
    demonstration=scope=='scripted_demo' or result.get('source',{}).get('kind') in {'scripted_demo','synthetic_fixture'}
    interpretation=result.get('fingerprint_interpretation',{})
    if lane not in {'l1','combined'} and not demonstration and not overlap.get('sample_identity_overlap'):
        directions=[s for s in interpretation.get('statements',[]) if s.get('state')=='local_descriptive_direction' and s.get('dimension') in {'behavior','capability_delivery','process'}]
        if directions:limits.append('这些接近方向只来自当前共同可比项目，不是具体型号的识别概率或混用比例。')
        elif any(s.get('state')=='equal_observed_distance' and s.get('dimension') in {'behavior','capability_delivery','process'} for s in interpretation.get('statements',[])):
            found.append('部分共同可比项目的参考距离相同，没有形成区分方向；其他观察仍分别保留。')
    if demonstration:
        summary.update(status='demonstration',title='演示流程已完成')
        limits.insert(0,'这些回答由脚本提供，比较方向仅演示展示方式，不构成真实模型检测结果。')
    elif result.get('status') in {'limited','unsupported','cancelled'}:
        summary.update(status='partial_observations',title='已保留部分观察，仍有未完成项目')
    elif score.get('group_counts',{}).get('fail',0):summary['title']='发现未通过的交付检查'
    elif lane=='l1':summary['title']='会话观察已整理'
    elif lane=='l2':summary['title']='回答倾向已整理'
    elif lane=='combined':
        summary['title']='已并列整理所选报告'
        limits.append('导入报告中的来源声明尚未认证；不同层级与相关证据不相加成身份概率。')
    if not steps:
        if lane=='l1':steps.append('如果现有记录不足，可选择核查同一实际入口的轻量探针；新调用只能说明新调用本身。')
        elif lane=='l2':steps.append('先查看有共同参考的题目和具体差异；需要实际交付证据时，再选择一项重型任务。')
        else:steps.append('保存报告和证据；按当前已观察到的范围使用结果。')
    if not found:found.append('本次可见信息已保留；请按下方项目查看具体观察和限制。')
    synthesis=synthesize(report);summary['synthesis']=synthesis
    subjects=synthesis['subjects']
    if subjects:
        if len(subjects)==1:
            summary['title']=subjects[0]['conclusion']['title']
        else:
            conflicts=sum(bool(s['source_conflicts'])for s in subjects)
            summary['title']=f'已分别整理 {len(subjects)} 个送测对象'+(f'，其中 {conflicts} 个存在声明或绑定差异' if conflicts else '')
        if all(s['conclusion']['state']=='demonstration'for s in subjects):summary['status']='demonstration'
        elif all(s['conclusion']['state']=='insufficient_evidence'for s in subjects):summary['status']='partial_observations'
        for subject in reversed(subjects[:3]):
            found.insert(0,subject['label']+'：'+subject['conclusion']['text'])
    for field in ('findings','limitations','next_steps'):summary[field]=list(dict.fromkeys(summary[field]))[:12]
    return summary


def brief_html(brief,escape):
    """One primary result, shared by the downloadable L1 and probe reports."""
    if not isinstance(brief,dict):return ''
    text=lambda value:escape(str(value or ''))
    display=brief.get('display') or {}
    blocks=['<section class="result-brief"><h1>'+text(display.get('title') or brief.get('title') or '目前的信息还不够')+'</h1>',
            '<p class="brief-description">'+text(display.get('summary') or brief.get('summary'))+'</p>']
    if display.get('suggestion'):blocks.append('<p>'+text(display['suggestion'])+'</p>')
    if display.get('note') or brief.get('caveat'):blocks.append('<p class="muted brief-caveat">'+text(display.get('note') or brief['caveat'])+'</p>')
    reasons=brief.get('reasons',[])
    if isinstance(reasons,list) and reasons:blocks.append('<details><summary>判断依据</summary><ul>'+''.join('<li>'+text(x)+'</li>'for x in reasons[:3])+'</ul></details>')
    return ''.join(blocks)+'</section>'


def html(summary,escape):
    blocks=['<section class="user-summary"><h2>'+escape(summary['title'])+'</h2>']
    for field,title in [('findings','主要发现'),('limitations','结果范围'),('next_steps','建议下一步')]:
        if summary.get(field):blocks.append('<h3>'+title+'</h3><ul>'+''.join('<li>'+escape(text)+'</li>' for text in summary[field])+'</ul>')
    synthesis=summary.get('synthesis',{})
    if isinstance(synthesis,dict) and synthesis.get('subjects'):
        blocks.append('<div class="evidence-synthesis"><h3>按送测对象综合解释</h3><p>支持与反对均指向“是否存在相对申报偏离的弱线索”，不评价模型好坏，也不计算身份概率。</p>')
        for subject in synthesis['subjects']:
            blocks.append('<section class="synthesis-subject"><h4>'+escape(subject['label'])+' · '+escape(subject['conclusion']['title'])+'</h4><p>'+escape(subject['conclusion']['text'])+'</p>')
            for category in ('source_conflicts','supporting','counterevidence','alternatives','gaps','observations'):
                entries=subject.get(category,[])
                if not entries:continue
                blocks.append('<details'+(' open' if category=='source_conflicts' else '')+'><summary>'+escape(CATEGORY_LABELS[category])+' · '+str(len(entries))+'</summary><ul>')
                for entry in entries:
                    refs='；'.join(str(r.get('pointer',''))+((' · '+str(r['record_id']))if r.get('record_id')else'')for r in entry['evidence_refs'])
                    blocks.append('<li>'+escape(entry['text'])+'<br><small>'+escape('范围：'+entry['scope']+'；相关组：'+entry['group']+'；依据：'+refs)+'</small></li>')
                blocks.append('</ul></details>')
            blocks.append('</section>')
        blocks.append('</div>')
    recommendation=summary.get('recommendation')
    if isinstance(recommendation,dict):
        blocks.append('<section class="detection-recommendation"><h3>下一步检测建议</h3><p>'+escape(str(recommendation.get('summary')or'当前没有可执行的自动推荐。'))+'</p>')
        reasons=recommendation.get('stop_reasons',[])
        if isinstance(reasons,list) and reasons:blocks.append('<h4>停止或先复核的原因</h4><ul>'+''.join('<li>'+escape(str(r))+'</li>'for r in reasons)+'</ul>')
        remaining=recommendation.get('remaining_budget_usd')
        blocks.append('<p>'+escape('可核对的剩余待测预算：$'+str(remaining) if remaining is not None else '尚未提供可核对的剩余待测预算。')+'</p>')
        actions=recommendation.get('actions',[])
        if isinstance(actions,list) and actions:
            blocks.append('<h4>备选动作（任选一项，不自动执行）</h4><ul>')
            for action in actions:
                if not isinstance(action,dict):continue
                title=str(action.get('title')or action.get('id')or'待配置动作')
                reason=str(action.get('reason')or'')
                reserve=action.get('estimated_reserve_usd')
                detail='请求数：'+str(action.get('request_count','未定'))+'；'+('完整预留：$'+str(reserve) if reserve is not None else '费用需在配置后重新预览')
                blocks.append('<li><strong>'+escape(title)+'</strong>：'+escape(reason)+'<br><small>'+escape(detail)+'</small></li>')
            blocks.append('</ul>')
        blocks.append('<p>这份离线报告不会发起调用。建议依据已有参考的局部差异与当前预算，不是识别准确率承诺；后续操作仍需在应用内配置并预览。</p></section>')
    return ''.join(blocks)+'</section>'
