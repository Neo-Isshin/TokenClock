"""Static, escaped reports with check coverage and explicit source limits."""
from __future__ import annotations
import base64
from html import escape
import json
from pathlib import Path
from ..l1.render import redact
from .assessment_quality import relationships_from_result, relationship_label

LABELS={'pass':'通过','fail':'未通过','unknown':'未核验','not_applicable':'不适用','completed':'已完成',
        'limited':'受限','unsupported':'当前环境不支持','cancelled':'已取消','failed':'请求失败',
        'artifact':'已有产物','replay_record':'记录回放','synthetic_fixture':'受控样本',
        'real_artifact':'已有产物（来源声明未认证）','live_probe':'本次真实调用'}

def e(value):return escape(redact(value),quote=True)
def j(value):return json.dumps(value,ensure_ascii=False,indent=2)
def short(value,limit=500):
    text=j(value) if isinstance(value,(dict,list)) else str(value)
    return e(text[:limit])+('…' if len(text)>limit else '')
def table(headers,rows):
    return '<div class="table"><table><thead><tr>'+''.join('<th>'+e(h)+'</th>' for h in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+str(v)+'</td>' for v in row)+'</tr>' for row in rows)+'</tbody></table></div>'
def details(title,value):return '<details><summary>'+e(title)+'</summary><pre>'+e(j(value))+'</pre></details>'
def num(value):return '未报告' if value is None else e(f'{value:.2f}' if isinstance(value,(int,float)) else value)

def fingerprint_section(value):
    dimensions={'behavior':'行为偏好','capability_delivery':'逐项得失分','process':'工作过程','resources':'资源投入'}
    panels=value.get('comparison_panels',[]);rows=[]
    for panel in panels:
        models=panel.get('per_model',[])
        if isinstance(models,dict):models=[{'model_label':k,**v} for k,v in models.items()]
        for model in models:
            rows.append([e(panel.get('subject_label',panel.get('subject_id','未绑定输入组'))),e(dimensions.get(panel.get('dimension'),panel.get('dimension'))),e(panel.get('task_family','')),
                         e('条件匹配' if panel.get('mode')=='strict' else '条件不全或不同'),e(model.get('model_label')),
                         num(model.get('distance')),e(len(panel.get('feature_ids',[]))),short(model.get('coverage',''),100)])
    html='<h2>多维指纹比较</h2><p>不同送测对象分组展示。同一行组使用各候选共同可比的特征；距离越小，仅表示这些已见特征越接近。没有强制获胜型号或身份概率。</p>'
    overlap=value.get('reference_overlap',{})
    if overlap.get('sample_identity_overlap'):html+='<p class="notice">检测到样本标识与参考记录重合，本次不计为独立验证。局部距离只描述这份已有记录。</p>'
    elif overlap.get('answer_content_seen_in_reference'):html+='<p class="notice">回答字面内容曾出现在参考中；短回答可能独立相同，不能仅据此认定同源。</p>'
    if rows:html+=table(['送测对象／声明','维度','题族','比较条件','历史参考型号','分布距离','共同特征数','覆盖'],rows)
    else:html+='<p>当前没有足够的共同可比项目；已观察到的特征仍保留。</p>'
    html+=details('各型号覆盖、局部贡献和未匹配观察',value)
    if any(p.get('origin')=='model_assessed' for p in panels):html+='<p>辅助解析与原回答共享证据来源。同端点解析的有效字段也保留距离比较；解析没有产生额外独立证据，不能直接据此认证型号或换型。</p>'
    if value.get('conflicts'):html+='<p class="notice">存在需单独解释的来源或证据冲突，指纹相近不会抵消这些记录。</p>'
    return html


def result_section(result,depth=0,imported=False):
    pieces=[]
    relations=relationships_from_result(result)
    if relations:
        pieces.append('<h2>待测与辅助解析连接</h2>'+table(['控制器记录的关系','比较用途','来源独立性'],[
            [e(relationship_label(r)),e('保留定义匹配的有引文观察，不增加独立证据票'),e('未得到认证')] for r in relations]))
        pieces.append('<p>'+('以下为导入报告的关系声明，未重新认证。' if imported else '关系由本次控制器配置计算，未使用模型自报的型号身份。')+'客观检查结果保持原样；解析结果不会自动加入参考库。</p>')
    if result.get('source_scope'):
        scope={'scripted_demo':'受控脚本演示：没有模型生成这些回答，不能作为型号测试结果。','recorded_response_replay':'已有请求/回答记录回放：本次没有再次调用模型。','new_live_requests':'本次真实API调用；只解释此次调用。','imported_answers':'已有回答导入：本次没有重新调用待测模型，评审费用另列。'}.get(result['source_scope'],result['source_scope'])
        if imported:scope='原报告的采样声明（本次仅导入，未重新调用或核验）：'+scope.replace('本次真实API调用；只解释此次调用。','原报告称其采样时进行了真实API调用。')
        pieces.append('<p class="notice">'+e(scope)+'</p>')
    if result.get('fingerprint_interpretation') and not imported:
        interpretation=result['fingerprint_interpretation']
        if result.get('source_scope')=='scripted_demo' or result.get('source',{}).get('kind') in {'scripted_demo','synthetic_fixture'}:pieces.append('<p class="notice">下面的局部方向使用脚本演示数据，不构成真实模型检测结果。</p>')
        pieces.append('<h2>局部指纹观察</h2><p>以下只解释共同特征上的距离，尚未验证为稳定型号识别率。</p><ul>'+''.join('<li>'+e(s.get('subject_label',''))+'：'+e(s['text'])+'</li>' for s in interpretation['statements'])+'</ul>'+details('方向一致性与解释范围',interpretation))
    if result.get('fingerprints') and not imported:pieces.append(fingerprint_section(result['fingerprints']))
    if result.get('source'):pieces.append('<p class="muted">输入来源：'+short(result['source'])+'</p>')
    score=result.get('score')
    if isinstance(score,dict):
        pieces.append('<div class="metrics">'+''.join('<div><span>'+e(k)+'</span><strong>'+v+'</strong></div>' for k,v in [
            ('完整任务分数',num(score.get('score'))),('已核验检查覆盖',num(100*score.get('coverage',0))+'%'),
            ('所有必需检查通过','是' if score.get('full_task_pass') else '否'),('相关证据组',str(len(score.get('groups',[]))))])+'</div>')
        if score.get('score') is None:pieces.append('<p>仍有必需检查未核验，不能将已检查部分的得分当作全题得分。</p>')
    if result.get('checks'):
        pieces.append('<h2>逐项核验</h2>'+table(['检查 / 证据组','结果','观察','依据'],[
            [e(c['id'])+'<br><small>'+e(c.get('group',''))+'</small>',e(LABELS.get(c.get('status'),c.get('status'))),
             short(c.get('observed',c.get('reason',''))),short(c.get('evidence',[]),300)] for c in result['checks']]))
    if result.get('model_assessed_checks'):
        pieces.append('<h2>模型辅助视觉观察</h2><p>对象与动作由评审模型判断，定位和引用经过格式校验；不等于独立的客观认证。</p>'+table(['判据','模型判断','一致性','依据'],[[e(c.get('feature_id')),e(LABELS.get(c.get('status'),c.get('status'))),e(c.get('observed',{}).get('agreement')),short(c.get('observed',{}).get('review_observations'),600)] for c in result['model_assessed_checks']]))
    if result.get('assessment_quality'):
        quality=result['assessment_quality'];coverage=quality.get('coverage',{});reviews=quality.get('reviews',{})
        pieces.append('<h2>评审有效性</h2>'+table(['可用于当前条件比较','仅旧条件观察','缺少判断','分歧','与本地依据冲突'],[[e(coverage.get(k,0)) for k in ['usable','contextual','unknown','disputed','excluded_by_local_conflict']]]))
        if reviews.get('single_opinion') or reviews.get('single_opinion_assessments'):pieces.append('<p>包含单次评审意见；没有因此获得独立认证。</p>')
        if reviews.get('repeated_same_reviewer') or reviews.get('repeated_same_reviewer_assessments'):pieces.append('<p>重复请求使用同一个评审型号；一致并不等于来自两位独立评审者。</p>')
        pieces.append(details('引用、版本绑定、未采用原因及原始意见',quality))
    if result.get('visual_assessment'):pieces.append(details('视觉提案、分歧和条件几何',result['visual_assessment']))
    if result.get('process_assessment'):pieces.append(details('模型辅助的过程解释',result['process_assessment']))
    if len(result.get('subject_comparisons',[]))>1:
        for group in result['subject_comparisons']:
            pieces.append('<details><summary>答题分布 · '+e(group['subject'].get('label'))+'</summary>'+result_section({'comparison':group['comparison']},depth+1,imported)+'</details>')
    comparison=result.get('comparison')
    if comparison:
        pieces.append('<h2>回答分布与参考</h2><p>距离为0表示该特征的已见分布相同，1表示不重叠。不同题目、条件和参考字段覆盖的距离不能当成校准后的型号排名。</p>')
        pieces.append(table(['题目','回答记录 / 可比较','合规与受限','未提取或参考外'],[
            [e(q['task_id']),e(str(q['raw_requests'])+' / '+str(q['eligible_responses'])),short({'状态':q['status_counts'],'合规':q.get('compliance_counts',{})}),short(q.get('unclassified_or_other_responses'))]
            for q in comparison['questions']]))
        rows=[]
        for q in comparison['questions']:
            for model in q['models']:
                for f in model['features']:
                    rows.append([e(q['task_id']),e(model['model_label']),e(f['feature']),e(f'{f["observed_n"]} / {f["reference_n"]}'),
                        num(f['total_variation_distance']),e(f'{f["outside_reference_pool_count"]}/{f["observed_n"]}'),
                        e('记录条件一致' if model['comparison_scope']=='exact_recorded_conditions' else '条件不同或缺失')])
        pieces.append('<details><summary>查看逐特征参考比较（'+str(len(rows))+'项）</summary>'+table(['题目','参考型号声明','特征','本次 / 参考N','分布距离','参考池外','条件'],rows)+'</details>')
        pieces.append('<p class="muted">多项特征可能来自同一回答；A/B版本属于同一个题目族。完整逐题贡献、条件差别及缺失比例保存在JSON中。</p>')
    if result.get('samples'):
        pieces.append('<h2>逐题回答</h2>')
        for s in result['samples']:
            pieces.append(details(s.get('task_id','')+' · 第'+str(s.get('repeat'))+'次',{'answer':s.get('answer'),
                'features':s.get('extracted',{}),'semantic_assessment':s.get('semantic_assessment'),'local_model_conflicts':s.get('assessment_conflicts',[]),'request':s.get('record',{})}))
    if result.get('trajectory'):
        pieces.append(details('工具证据与恢复链',result['trajectory']))
    if result.get('tool_events'):
        pieces.append('<h2>实际工具轨迹</h2>'+table(['阶段','动作','结果','工作区是否改变'],[
            [e(t.get('stage')),e(t.get('name')),e(t.get('status')),'是' if t.get('workspace_before')!=t.get('workspace_after') else '否'] for t in result['tool_events']]))
        pieces.append('<p class="muted">脚本回放动作、目标调用动作和评测器动作分别记录。它们不代表模型的内部思考步骤。</p>')
    if result.get('accounting'):
        a=result['accounting'];pieces.append('<h2>调用与费用</h2><p>'+('原报告记录的请求数（非本次调用） ' if imported else '真实请求 ')+e(a.get('live_requests','未报告'))+' 次 · 接口报告费用 $'+e(a.get('reported_cost_usd','未报告'))+' · 按配置估算 $'+e(a.get('estimated_cost_usd','未报告'))+' · 未结预留 $'+e(a.get('pending_reserved_usd','未报告'))+'</p>'+details('完整费用与预留记录',a))
    if result.get('reviewer_assessment'):
        assessment=result['reviewer_assessment'];a=assessment.get('accounting',{})
        pieces.append('<h2>评审请求与费用</h2><p>'+('原报告记录的评审请求 ' if imported else '本次评审请求 ')+e(a.get('live_requests',0))+' 次 · 已报告 $'+e(a.get('reported_cost_usd','未报告'))+' · 估算 $'+e(a.get('estimated_cost_usd','未报告'))+' · 未结预留 $'+e(a.get('pending_reserved_usd','未报告'))+'</p>'+details('评审条件、原始提案与停止原因',assessment))
    diag=result.get('diagnostics')
    if diag:
        pieces.append(('<h2>原报告中的服务记录</h2>' if imported else '<h2>本次调用的服务记录</h2>')+details('型号声明、字段、计量与流式记录',diag))
    if result.get('observations'):pieces.append('<h2>服务处理观察</h2>'+''.join(details(o.get('type','观察'),o) for o in result['observations']))
    if result.get('components') and depth<2:
        for index,c in enumerate(result['components']):
            r=c['report'];pieces.append('<section class="component"><h2>报告 '+str(index+1)+' · '+e(r.get('workflow_mode','L1'))+'</h2><p class="muted">此处展示导入的报告内容，未重新执行核验；报告中的来源声明没有因此获得认证。</p>')
            if r.get('schema')=='tokenclock-product-report/v1':pieces.append(result_section(r.get('result',{}),depth+1,imported=True))
            else:
                pieces.append(details('来源与结论',r.get('summary',{})))
                pieces.append(details('已有观察',r.get('facts',r)))
            pieces.append('</section>')
        pieces.append('<p>完全相同的报告已去重：'+e(result.get('duplicate_reports_ignored',0))+'份。其余报告并列展示，不合计分数；来源冲突不会被能力得分抵消。</p>')
    limits=result.get('limitations') or result.get('limits') or []
    if limits:pieces.append('<h2>解释范围</h2><ul>'+''.join('<li>'+e(x)+'</li>' for x in limits)+'</ul>')
    return ''.join(pieces)


def render_report(report,root=None):
    result=report['result'];content=result_section(result)
    from .user_summary import html, brief_html, summarize
    from .result_brief import build_brief
    user=report.get('user_summary') or summarize(report)
    compact=brief_html(build_brief({**report,'user_summary':user}),e)
    content=html(user,e)+content
    previews=[]
    if root is not None:
        for path in sorted((Path(root)/'evidence').rglob('*.png')):
            if len(previews)>=6:break
            if path.is_symlink() or path.stat().st_size>3*1024*1024:continue
            raw=path.read_bytes()
            if not raw.startswith(b'\x89PNG\r\n\x1a\n'):continue
            previews.append('<figure><img alt="隔离环境生成的检查截图" src="data:image/png;base64,'+base64.b64encode(raw).decode()+'"><figcaption>'+e(path.relative_to(root))+'</figcaption></figure>')
    if previews:content+='<h2>核验截图</h2>'+''.join(previews)
    status_label='存在未通过检查' if any(c.get('status')=='fail' for c in result.get('checks',[])) else LABELS.get(result.get('status'),result.get('status','已记录'))
    title='检测结果'
    content=compact+'<details class="full-analysis"><summary>查看完整依据</summary><p>执行状态：'+e(status_label)+'</p>'+content+'</details>'
    return '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TokenClock · '+title+'</title><style>body{font:15px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;color:#233c30;background:#fafcf9;margin:0;padding:28px;max-width:1150px}h1{font-size:29px}.notice{background:#fff0cf;padding:14px;border-left:4px solid #b18932;border-radius:5px}h2{font-size:20px;margin-top:28px}p,li{max-width:960px}.muted,small{color:#65776c;font-size:12px}.metrics{display:flex;flex-wrap:wrap;gap:14px}.metrics div{background:#edf3ec;border-radius:12px;padding:14px 20px}.metrics span{display:block;font-size:12px}.metrics strong{display:block;font-size:23px}.table{overflow:auto}table{width:100%;border-collapse:collapse;font-size:12px}th,td{text-align:left;vertical-align:top;padding:10px;border-bottom:1px solid #dde7d9;overflow-wrap:anywhere;max-width:340px}th{background:#ecf2e8}pre{white-space:pre-wrap;word-break:break-word;font-size:12px;max-height:560px;overflow:auto;background:#f0f4ed;padding:12px}details{margin:12px 0}summary{cursor:pointer}img{max-width:100%;border:1px solid #dae4d5}figure{margin:20px 0}.component{border:1px solid #d5dfd0;border-radius:14px;padding:18px;margin:20px 0}.result-brief{padding:28px 0}.result-brief h1{margin:0 0 18px}.brief-caveat{border-left:2px solid #ccd8cf;padding-left:12px}.full-analysis{border-top:1px solid #dde7d9;padding-top:18px}body{max-width:820px;margin:28px auto}</style><body><p class="muted">TokenClock · 检测结果</p>'+content+'</body></html>'
