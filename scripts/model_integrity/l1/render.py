"""Static, escaped local L1 reports; references are displayed, never dereferenced."""
from __future__ import annotations

from html import escape
import json
import re
from typing import Any

MAX_FACTS = 1200
MAX_UNKNOWNS = 200
MAX_EVIDENCE = 1800
MAX_SNIPPET = 1600
MAX_VALUE = 4000

SOURCE_LABELS = {
    'declaration_difference': '发现有定位依据的型号声明差异',
    'consistent_declarations': '已匹配的可见声明一致',
    'insufficient_binding': '缺少足够的逐调用来源绑定',
}
QUALITY_LABELS = {
    'visible_issue_or_unverified_claim': '存在可见验证问题或尚未核实的交付声明',
    'limited_observations': '仅有局部交付与验证观察',
}
MODULE_LABELS = {'partial': '部分实现', 'limited': '范围受限', 'not_implemented': '尚未实现'}
ACTOR_LABELS = {'assistant': '目标助手', 'user': '用户', 'evaluator': '评测器',
                'child': '子代理', 'tool': '工具返回载体', 'system': '系统', 'unknown': '未知主体'}
FACT_LABELS = {
    'source.harness_model_observed': '原始结构化型号字段',
    'source.harness_model_difference': '同轮次请求与响应条目型号不同',
    'source.harness_model_consistent': '同轮次本地型号声明一致',
    'source.harness_model_change': '主调用型号记录变化',
    'source.harness_default_difference': '会话默认与轮次型号不同',
    'source.harness_multiple_models_in_turn': '同轮次存在多个型号声明',
    'source.harness_unbound_models': '未绑定字段出现多个型号',
    'source.comparison_target_difference': '比较目标与最近请求型号不同',
    'capture.record_count': '可见记录数量',
    'capture.duplicate_events': '重复事件',
    'source.model_claim_difference': '同调用型号声明差异',
    'source.model_claim_consistent': '同调用型号声明一致',
    'source.billing_claim_difference': '账单型号声明差异',
    'source.provider_change': '供应商字段变化',
    'process.test_result': '可见测试结果',
    'process.read_observed': '可见读取',
    'process.edit_observed': '可见修改',
    'process.edit_outside_explicit_scope': '修改路径超出明确范围',
    'process.unverified_completion_claim': '未获记录支持的完成声明',
    'process.latest_change_unverified': '最新修改未获后续验证',
    'resource.usage_fields': '报告的用量字段',
    'resource.usage_equation_mismatch': '用量计量等式不一致',
    'resource.stream_shape': '客户端接收事件形态',
}
UNKNOWN_LABELS = {
    'source.harness_response_missing': '缺少主响应型号字段',
    'source.harness_model_scope_unknown': '型号字段用途或轮次归属不完整',
    'capture.completeness_unknown': '无法确认会话记录完整',
    'capture.gap': '存在明确的会话记录缺口',
    'capture.malformed_records': '部分记录格式无法解释',
    'capture.order_or_binding_ambiguous': '事件顺序或绑定存在歧义',
    'capture.unsupported_record_kinds': '部分记录类型尚未支持',
    'source.unbound_model_claims': '型号声明缺少可匹配的逐调用绑定',
    'process.tool_binding_unknown': '工具结果无法唯一关联到此前调用',
    'process.test_result_unknown': '已见测试命令，但结果不明确',
    'process.read_coverage_incomplete': '读取返回内容不完整',
    'process.test_execution_not_observed': '有测试定义，但尚未观察到目标执行',
    'resource.usage_missing': '用量字段或计量口径不足',
    'resource.stream_timing_unknown': '流式事件时间缺失或不单调',
    'reference.comparison_not_calibrated': '本版不估计真实型号或能力档位',
    'delivery.semantic_review_not_implemented': '自然语言交付质量尚未完整自动核验',
}


def redact(value: Any) -> str:
    """Best-effort presentation redaction, without touching the retained input."""
    body = str(value)
    body = re.sub(r'(?i)(?<![A-Za-z0-9_])sk-(?:or-v\d+-)?[A-Za-z0-9_-]{12,}', '[密钥已隐藏]', body)
    body = re.sub(r'(?i)(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})',
                  '[密钥已隐藏]', body)
    body = re.sub(r'(?i)(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16}(?![A-Za-z0-9_])', '[访问密钥已隐藏]', body)
    body = re.sub(r'(?i)((?<![A-Za-z0-9_])Authorization(?![A-Za-z0-9_])[\s"\x27]*[:=][\s"\x27]*)(?:Bearer\s+|Basic\s+)?[^\s,"\x27<>\\]+',
                  r'\1[凭据已隐藏]', body)
    body = re.sub(r'(?i)(?<![A-Za-z0-9_])Bearer\s+[A-Za-z0-9._~+/-]{8,}=*', 'Bearer [凭据已隐藏]', body)
    body = re.sub(r'(?i)((?<![A-Za-z0-9_])(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|secret)(?![A-Za-z0-9_])[\s"\x27]*[:=][\s"\x27]*)[^\s,"\x27<>\\]+',
                  r'\1[凭据已隐藏]', body)
    body = re.sub(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                  '[私钥已隐藏]', body)
    body = re.sub(r'(?i)(https?://)[^/\s:@]+:[^/\s@]+@', r'\1[网址凭据已隐藏]@', body)
    return body


def safe(value: Any, limit: int | None = None) -> str:
    body = redact(value)
    if limit is not None and len(body) > limit:
        body = body[:limit] + '\n…（展示截断；完整内容在本地 observation.json）'
    return escape(body, quote=True)


def pretty(value: Any, limit: int = MAX_VALUE) -> str:
    return safe(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), limit)


def _pointer(document: Any, pointer: Any) -> Any:
    # Resolve only inside the supplied in-memory document. No file or URL access.
    if not isinstance(pointer, str) or not pointer.startswith('/'):
        return None
    current = document
    try:
        for component in pointer[1:].split('/'):
            key = component.replace('~1', '/').replace('~0', '~')
            if isinstance(current, list):
                if not key.isdigit():
                    return None
                current = current[int(key)]
            elif isinstance(current, dict):
                current = current[key]
            else:
                return None
        return current
    except (IndexError, KeyError, ValueError):
        return None


SEMANTIC_LABELS = {
    'semantic.user_requirement': '用户明确提出的要求', 'semantic.user_update': '用户补充的条件或信息',
    'semantic.decision_statement': '助手表达的判断', 'semantic.conditional_statement': '带适用条件的表述',
    'semantic.negative_statement': '助手的否定表述', 'semantic.validation_proposal': '建议采用的验证办法',
    'semantic.hypothesis_revision': '助手列出的假设与优先顺序', 'semantic.deadline_constraint': '提到的期限或观察周期',
    'semantic.explicit_candidate_set': '明确列出的候选方案',
}
FACT_LABELS.update(SEMANTIC_LABELS)
FACT_LABELS.update({
    'capture.role_counts': '各角色的可见记录', 'source.binding_collision': '同一记录标识存在不同内容',
    'source.display_model': '界面显示的型号', 'source.context_model_label': '上下文中声明的型号',
    'source.out_of_scope_claim': '型号或账单记录属于其他范围',
    'delivery.assistant_response_observed': '助手回答的可见范围', 'behavior.style_instructed': '用户明确要求了表达方式',
    'process.test_definition_present': '出现验证函数或测试定义', 'process.test_exit_mismatch': '退出码与失败报告不一致',
    'process.edit_path': '记录中的修改路径', 'process.read_visible': '实际可见的读取返回',
    'process.artifact_content_changed': '两个可见版本的内容发生变化',
    'resource.reasoning_reported': '服务报告的推理用量', 'resource.elapsed_seconds': '客户端记录的等待时间',
    'resource.usage_consistency': '计量字段是否符合当前口径', 'resource.usage_conflict_details': '计量差异的具体位置',
    'resource.stream_observed': '客户端收到的流式事件',
})
QUALITY_LABELS.update({
    'semantic_observations_only': '已整理要求、条件与表述；未判定整项任务正确性',
    'visible_checks_recovered': '同项可见检查已有后续通过记录，早期失败保留',
    'visible_checks_passed': '可见检查通过；其他交付要求仍按各自证据判断',
    'latest_version_unverified': '后续内容已修改，尚未见对应的新验证',
})
UNKNOWN_LABELS.update({
    'reference_missing': '严格参考比较暂不成立',
    'semantic.general_interpretation_unverified': '通用语义与隐含关系尚未完整核验',
    'semantic.external_unavailable': '外部语义增强未完成',
    'semantic.external_partial_context': '外部增强仅覆盖部分完整轮次',
    'semantic.external_proposals_rejected': '部分外部解释未通过引用或范围检查',
})
VERIFICATION_LABELS = {
    'no_checks': '未见可归属目标助手的检查结果', 'observed_pass': '最近可见检查通过',
    'observed_failure': '最近仍见失败结果', 'recovered_checks': '同项检查后续通过，保留早期失败',
    'latest_change_unverified': '检查后又有修改，最新版本未见验证',
    'unknown_after_gap': '后续存在记录缺口，当前结果未知', 'mixed_or_unknown': '部分检查的后续状态未知',
}
REFERENCE_REASONS = {
    'reference_catalog_not_configured': '当前未载入可用参考库。',
    'natural_or_multiturn_task_has_no_exact_probe_reference': '当前自然任务没有与短题库字面完全一致的题目；其他任务事实仍保留。',
    'task_or_exact_prompt_or_generation_conditions_missing': '题面无法唯一对应，或生成条件未完整记录。',
    'same_question_conditions_unknown_or_different': '找到了同一道题的历史计数，但部分请求条件不同或未知，因此仅作为背景参考。',
    'no_exact_task_prompt_and_condition_match': '没有找到同时满足题面与已记录条件的严格参考。',
    'supplied_prompt_hash_conflicts_with_literal_prompt': '所填题面标识与实际文字不一致，已停止使用这项参考。',
}
CONDITION_LABELS = {'reasoning_effort': '推理档位', 'generation_limit': '输出上限', 'system': '系统提示',
                    'history': '历史上下文', 'tools': '工具', 'feedback': '答案反馈', 'fresh_single_question': '独立单题请求'}
FEATURE_LABELS = {'candidate_count': '候选数量', 'selected_content': '所选类别', 'selected_position': '所选位置',
                  'selection_mode': '选择方式', 'offers_multiple_versions': '是否提供多个版本',
                  'first_presented_strategy': '首先采用的解法', 'multiple_implementations': '是否给出多个实现',
                  'mentions_aliasing': '是否解释共享引用', 'explicit_recommendations': '明确推荐项'}


def _condition(value):
    if value is None: return '未设置（null）'
    if value is True: return '是'
    if value is False: return '否'
    if value == 'additional_user_turns_visible': return '可见记录中还有其他用户轮次'
    if value == 'high': return 'high（高档）'
    if value == 'low': return 'low（低档）'
    if isinstance(value, (dict, list)): return '空集合' if not value else '已提供非空内容'
    return str(value)


def _fact_body(fact):
    code, value = fact.get('code'), fact.get('value')
    if code.startswith('source.harness_') or code=='source.comparison_target_difference':
        from .model_fields import describe
        return '<p>'+safe(describe(code,value),1000)+'</p>'
    if code.startswith('semantic.') and isinstance(value, dict):
        if code == 'semantic.explicit_candidate_set':
            names = [candidate.get('name', '') for candidate in value.get('candidates', [])]
            aliases = [name for candidate in value.get('candidates', []) for name in candidate.get('aliases', [])]
            text = f'明确候选 {value.get("candidate_count", "未知")} 个：' + '、'.join(names)
            extra = []
            if aliases: extra.append('别名单列：' + '、'.join(aliases))
            if value.get('excluded'): extra.append('明确排除：' + '、'.join(value['excluded']))
            if value.get('recommendations'): extra.append('推荐项：' + '、'.join(value['recommendations']))
            return '<p>' + safe(text, 1000) + '</p>' + ''.join('<p class="muted">' + safe(line, 800) + '</p>' for line in extra)
        tags = []
        if value.get('conditional'): tags.append('含适用条件')
        if value.get('negated'): tags.append('含否定表达')
        if value.get('quoted'): tags.append('引用或建议说法')
        result = '<blockquote>' + safe(value.get('text', ''), MAX_SNIPPET) + '</blockquote>'
        result += '<p>' + ''.join('<span class="tag">' + safe(tag) + '</span>' for tag in tags) + '</p>'
        return result
    if code in ('source.model_claim_difference', 'source.model_claim_consistent') and isinstance(value, dict):
        return f'<p>请求声明 <strong>{safe(value.get("requested", "未知"), 160)}</strong>；响应声明 <strong>{safe(value.get("reported", "未知"), 160)}</strong>。</p><p class="muted">范围限于已绑定的可见声明，不能据此认证实际后端权重。</p>'
    if code == 'source.billing_claim_difference' and isinstance(value, dict):
        return f'<p>响应声明 {safe(value.get("reported", "未知"), 160)}；同范围账单声明 {safe(value.get("billed", "未知"), 160)}。</p>'
    if code == 'source.provider_change' and isinstance(value, dict):
        return f'<p>供应商字段从 {safe(value.get("from", "未知"), 160)} 变为 {safe(value.get("to", "未知"), 160)}；型号声明为 {safe(value.get("model", "未知"), 160)}。供应商变化本身不等于型号变化。</p>'
    direct = {
        'process.unverified_completion_claim': '回答中有完成或已测试的表述，目前记录没有充分支持。自述不会覆盖实际失败。',
        'process.test_definition_present': '回答里提供了测试或验证定义；函数存在本身不说明已执行或已通过。',
        'process.test_exit_mismatch': '工具返回的退出码为成功，但可见报告包含失败，需按报告内容保留该失败。',
        'process.latest_change_unverified': '先前检查之后还发生了内容修改，旧结果不能自动覆盖最新版本。',
        'behavior.style_instructed': '用户明确要求了简洁、详尽或语言等表达方式；相应特征不应视为完全自发的偏好。',
        'source.out_of_scope_claim': '这条型号或账单记录没有落在当前可匹配调用的范围内，不能作为该调用的型号冲突。',
        'source.binding_collision': '同一个记录标识对应不同内容，依赖该标识的归属判断需要保留歧义。',
    }
    if code in direct: return '<p>' + direct[code] + '</p>'
    if code == 'process.test_result': return '<p>这一条可见检查结果为：<strong>' + ('通过' if value == 'pass' else '失败' if value == 'fail' else safe(value)) + '</strong>。它只说明对应检查与版本。</p>'
    if code == 'resource.usage_consistency': return '<p>' + ('当前已提供的计量字段符合所标明的口径。' if value is True else '当前计量字段不符合所标明的等式；这不直接判断模型身份或服务商意图。') + '</p>'
    if code == 'process.read_visible' and isinstance(value, dict):
        return '<p>可见读取返回来自 ' + safe(value.get('path', '未知路径'), 500) + ('，返回内容存在截断。' if value.get('truncated') else '；可见返回不自动证明完整理解。') + '</p>'
    if code == 'process.edit_path' and isinstance(value, dict): return '<p>记录中的修改路径：' + safe(value.get('path', '未知'), 500) + '。</p>'
    if code in ('process.edit_outside_explicit_scope', 'process.artifact_content_changed'): return '<p>对应路径：' + safe(value, 600) + '。</p>'
    if code == 'resource.elapsed_seconds': return '<p>客户端记录等待 ' + safe(value) + ' 秒；不能由此推算内部思考步骤。</p>'
    if code == 'resource.reasoning_reported': return '<p>字段报告值：' + safe('null（空值）' if value is None else value) + '。服务报告口径不等于完整内部思考过程。</p>'
    if isinstance(value, (str, int, float)) and not isinstance(value, bool): return '<p>' + safe(value, 700) + '</p>'
    return '<p class="muted">该项为结构化记录观察，具体字段可在详情查看。</p>'


def render_report(report: dict, observation: dict) -> str:
    """Readable, escaped HTML derived only from supplied evidence and results."""
    summary, scope = report.get('summary', {}), report.get('scope', {})
    coverage, semantic = report.get('coverage', {}), report.get('semantic', {})
    verification = report.get('verification_history', {})
    references = report.get('reference_comparison', {})
    facts, unknowns = report.get('facts', [])[:MAX_FACTS], report.get('unknowns', [])[:MAX_UNKNOWNS]
    index = report.get('record_index', {})
    native = {}
    for n, row in enumerate(observation.get('records', [])):
        if isinstance(row, dict): native.setdefault(str(row.get('id')), []).append((n, row))
    all_ids = [str(eid) for row in facts + unknowns for eid in row.get('evidence', [])]
    for stage in semantic.get('stages', []): all_ids += [str(stage.get('user_record_id'))] + [str(e) for e in stage.get('assistant_record_ids', [])]
    for group in verification.get('groups', []): all_ids += [str(e) for e in group.get('evidence', [])]
    all_evidence = list(dict.fromkeys(all_ids))
    evidence_ids = all_evidence[:MAX_EVIDENCE]
    anchors = {eid: f'evidence-{number}' for number, eid in enumerate(evidence_ids, 1)}

    def locate(eid):
        location = index.get(str(eid), {})
        pointer = location.get('pointer') if isinstance(location, dict) else None
        if pointer is None and str(eid).startswith('/'): pointer = str(eid)
        if pointer is not None: return pointer, _pointer(observation, pointer)
        matches = native.get(str(eid), [])
        return (f'/records/{matches[0][0]}', matches[0][1]) if len(matches) == 1 else (None, None)

    def links(values):
        return ' '.join(f'<a href="#{anchors[str(eid)]}">查看原文 {number}</a>' for number, eid in enumerate(values, 1) if str(eid) in anchors)

    def detail(fact):
        return '<details class="technical"><summary>字段与证据详情</summary><p><code>' + safe(fact.get('code', ''), 160) + '</code> · 共享证据组 ' + safe(fact.get('group', '未知'), 160) + '</p><pre>' + pretty(fact.get('value')) + '</pre></details>'

    def card(fact, css=''):
        code = str(fact.get('code', ''))
        role = ACTOR_LABELS.get(fact.get('actor'), fact.get('actor', ''))
        origin = ' · 外部解释，引用已核对；解释本身仍可出错' if fact.get('semantic_origin') == 'external' else ''
        return '<article class="observation ' + css + '"><h3>' + safe(FACT_LABELS.get(code, '局部记录观察'), 180) + '</h3>' + ('<p class="muted">' + safe(role + origin, 250) + '</p>' if role or origin else '') + _fact_body(fact) + '<p class="evidence-links">' + links(fact.get('evidence', [])) + '</p>' + detail(fact) + '</article>'

    parts = ['''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'">
<meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TokenClock · 检测结果</title><style>
:root{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif;background:#f4f6f9;color:#172333}body{max-width:1120px;margin:32px auto;padding:0 24px 60px;line-height:1.7}h1{font-size:28px;line-height:1.4}h2{font-size:22px;margin:36px 0 12px}h3{font-size:17px;margin:0 0 10px}a{color:#155eaa;overflow-wrap:anywhere}pre{font-family:ui-monospace,monospace;font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;background:#f0f3f7;padding:12px;border-radius:8px;max-height:400px;overflow:auto}code{font-size:12px;overflow-wrap:anywhere}table{border-collapse:collapse;width:100%;background:white}th,td{padding:12px;text-align:left;vertical-align:top;border-bottom:1px solid #dce3ec;overflow-wrap:anywhere}th{background:#edf1f6}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}.card,article,.panel{background:white;border:1px solid #dce3ec;border-radius:12px;padding:18px;margin:12px 0}.card p{margin:0}.muted{color:#5a687b;font-size:13px}.warning{background:#fff4d6;border-left:4px solid #ac6500;padding:16px;border-radius:10px}.source-warning{border-left:4px solid #b45c31}.tag{display:inline-block;font-size:12px;background:#e9eef6;padding:2px 8px;border-radius:5px;margin:0 6px 5px 0}blockquote{margin:10px 0;padding:12px 16px;border-left:3px solid #7196c2;background:#f6f8fc;white-space:pre-wrap;overflow-wrap:anywhere}.user-quote{border-left-color:#9a8b70}.timeline article{border-left:3px solid #b5c9e0}.evidence-links{font-size:13px}.evidence-links a{margin-right:12px}details{margin:12px 0}summary{cursor:pointer;font-weight:550}.technical{font-size:13px;color:#5a687b}footer{font-size:13px;color:#5a687b;margin-top:40px}.state{font-weight:650}.amount{font-size:19px;font-variant-numeric:tabular-nums}.step{display:inline-block;margin:4px 6px 4px 0;padding:4px 9px;border-radius:6px;background:#edf2f8}.table-wrap{overflow:auto}@media(prefers-color-scheme:dark){:root{background:#111927;color:#e5ebf5}.card,article,.panel,table{background:#192436;border-color:#35435a}pre,th,blockquote,.step{background:#202e42}td,th{border-color:#35435a}.muted,footer,.technical{color:#a6b4c8}a{color:#8fc5ff}.warning{background:#382b0f;color:#ffdfa2}.tag{background:#2d3d55}}
.result-brief{padding:28px 0}.result-brief h1{margin:0 0 18px}.brief-caveat{border-left:2px solid #b6c7be;padding-left:12px}.full-analysis{border-top:1px solid #dce3ec;padding-top:18px}body{max-width:820px}</style></head><body><p class="muted">TokenClock · 检测结果</p>''']
    from ..probes.user_summary import summarize, brief_html
    from ..probes.result_brief import build_brief
    compact_user=report.get('user_summary') or summarize(report)
    parts.append(brief_html(build_brief({**report,'user_summary':compact_user}),safe))
    parts.append('<details class="full-analysis"><summary>查看完整依据</summary>')
    if scope.get('synthetic'):
        parts.append('<div class="warning"><strong>合成／反事实样本</strong>：用于检验程序，不能计为新的真实模型回答或真实路由事件。</div>')
    parts.append('<h1>' + safe(summary.get('headline', '已整理可见记录与待确认范围'), 500) + '</h1>')
    parts.append('<div class="cards">')
    for title, text in [('来源声明', SOURCE_LABELS.get(summary.get('source_status'), '按可见来源字段判断')),
                        ('交付与检查', QUALITY_LABELS.get(summary.get('quality_status'), '当前只有局部观察')),
                        ('身份判断', '未估计真实型号概率或混用比例')]:
        parts.append('<section class="card"><h3>' + title + '</h3><p>' + safe(text, 500) + '</p></section>')
    parts.append('</div><p class="muted">来源差异、交付问题与行为偏好分别保留；同一句话产生的多项观察不会成为多张独立证据票。</p>')
    if report.get('user_summary'):
        from ..probes.user_summary import html
        parts.append(html(report['user_summary'],safe))
    complete = scope.get('capture_complete')
    completeness = '来源声明完整，尚未独立认证' if complete is True else '明确不完整或仅选定片段' if complete is False else '完整性未确定'
    parts.append('<p class="muted">记录范围：' + completeness + '。缺失只限制对应结论，不清除已经看见的事实。</p>')
    if scope.get('comparison_model') is not None:
        parts.append('<p>本次比较目标：<strong>' + safe(scope['comparison_model'], 160) + '</strong>，不会替换历史请求型号。</p>')

    parts.append('<h2>主要观察</h2>')
    primary_codes = {'source.model_claim_difference', 'source.billing_claim_difference', 'source.provider_change', 'source.binding_collision',
                     'process.edit_outside_explicit_scope', 'process.unverified_completion_claim', 'process.latest_change_unverified', 'process.test_exit_mismatch'}
    primary_codes.update({'source.harness_model_difference','source.harness_multiple_models_in_turn','source.harness_model_change',
                          'source.harness_default_difference','source.harness_unbound_models','source.comparison_target_difference'})
    selected = [fact for fact in facts if fact.get('code') in primary_codes or (fact.get('code') == 'resource.usage_consistency' and fact.get('value') is False)]
    if not verification.get('groups'): selected += [fact for fact in facts if fact.get('code') == 'process.test_result']
    semantic_selected = [fact for fact in facts if fact.get('code') in ('semantic.decision_statement', 'semantic.user_requirement', 'semantic.hypothesis_revision', 'semantic.validation_proposal', 'semantic.explicit_candidate_set')]
    selected += semantic_selected[-6:]
    selected_ids = {fact.get('id') for fact in selected[:24]}
    if not selected:
        parts.append('<p>当前没有可单独概括的实质异常或决策观察；可在下方检查范围与记录详情中查看已提取内容。</p>')
    for fact in selected[:24]: parts.append(card(fact, 'source-warning' if fact.get('code') in ('source.model_claim_difference', 'source.billing_claim_difference') else ''))
    if len(selected) > 24: parts.append('<p class="muted">其余观察保留在下方字段详情中。</p>')

    if report.get('process_profile'):
        parts.append('<h2>工作过程观察</h2><p>只计入记录中可绑定的助手工具调用。步骤多少不是思考深度；评测器动作另行排除。</p>')
        profile=report['process_profile']
        parts.append('<details><summary>过程特征与任务绑定依据</summary><pre>'+pretty(profile)+'</pre></details>')
        interpretation=report.get('fingerprint_interpretation',{})
        for item in interpretation.get('statements',[]):parts.append('<p>'+safe(item.get('text',''),1200)+'</p>')
        if report.get('fingerprints'):
            from ..probes.report import fingerprint_section
            parts.append(fingerprint_section(report['fingerprints']))

    if semantic.get('stages'):
        parts.append('<h2>用户条件与助手表述的脉络</h2><p class="muted">按用户轮次整理。下列判断、计划和验证办法是发言内容，不自动视为已经执行。</p><div class="timeline">')
        for number, stage in enumerate(semantic['stages'][:40], 1):
            eid = str(stage.get('user_record_id'))
            _, user = locate(eid)
            body = user.get('data', {}).get('text', '') if isinstance(user, dict) else ''
            parts.append('<article><h3>第 ' + str(number) + ' 轮 · 用户提出或补充</h3><blockquote class="user-quote">' + safe(body, 1000) + '</blockquote><p>' + links([eid]) + '</p>')
            assistant_ids = set(stage.get('assistant_record_ids', []))
            grouped = {}
            for fact in facts:
                if not str(fact.get('code', '')).startswith('semantic.') or fact.get('actor') != 'assistant' or not assistant_ids.intersection(fact.get('evidence', [])): continue
                value = fact.get('value', {})
                key = (tuple(fact.get('evidence', [])), value.get('text') if isinstance(value, dict) else '')
                grouped.setdefault(key, []).append(fact)
            items = list(grouped.values())
            if items:
                parts.append('<p><strong>助手对应表述</strong></p>')
                for n, group in enumerate(items):
                    if n == 3: parts.append('<details><summary>本轮其他有原文依据的表述</summary>')
                    parts.append('<p>' + '、'.join(safe(FACT_LABELS.get(f.get('code'), '局部表述')) for f in group) + '</p>' + _fact_body(group[0]) + '<p>' + links(group[0].get('evidence', [])) + '</p>')
                if len(items) > 3: parts.append('</details>')
            else:
                parts.append('<p class="muted">本轮尚未提取出可确定的语义结构；保留助手原文供回查。</p><details><summary>助手回答片段</summary>')
                for aid in stage.get('assistant_record_ids', []):
                    _, answer = locate(aid)
                    if isinstance(answer, dict): parts.append('<blockquote>' + safe(answer.get('data', {}).get('text', ''), 1000) + '</blockquote><p>' + links([aid]) + '</p>')
                parts.append('</details>')
            parts.append('</article>')
        parts.append('</div>')

    parts.append('<h2>检查历史与最近可见状态</h2>')
    current = verification.get('current_status', 'no_checks')
    parts.append('<p class="state">' + safe(VERIFICATION_LABELS.get(current, '状态范围尚未确定')) + '</p><p class="muted">只汇总相同检查、主体与可见范围。后续通过不自动证明整项任务正确，也不证明一定修好了生产代码。</p>')
    for number, group in enumerate(verification.get('groups', [])[:60], 1):
        state = VERIFICATION_LABELS.get(group.get('state'), '局部状态未确定')
        actor = ACTOR_LABELS.get(group.get('actor'), '未知主体')
        parts.append('<article><h3>检查 ' + str(number) + ' · ' + safe(actor) + '</h3><p class="state">' + safe(state) + '</p>')
        for n, check in enumerate(group.get('checks', []), 1):
            result = '通过' if check.get('result') == 'pass' else '失败' if check.get('result') == 'fail' else '未知'
            parts.append('<span class="step">第 ' + str(n) + ' 次：' + result + '</span>')
        failures = group.get('historical_failures', [])
        recovered = group.get('resolved_failure_ids', [])
        parts.append('<p>早期及历史失败记录 ' + str(len(failures)) + ' 条；其中 ' + str(len(recovered)) + ' 条之后出现了同项检查通过记录。</p>')
        parts.append('<p>' + links(group.get('evidence', [])) + '</p><details class="technical"><summary>检查命令、阶段与绑定范围</summary><pre>' + pretty({key: group.get(key) for key in ('signature', 'generation_id', 'stage', 'actor')}) + '</pre></details></article>')

    def reference_section(comparison):
        result = []
        if comparison.get('per_question'):
            for i, item in enumerate(comparison['per_question'], 1):
                result.append('<h3>字面匹配题目 ' + str(i) + '</h3>' + reference_section(item))
            return ''.join(result)
        strict, context = comparison.get('matches', []), comparison.get('contextual_matches', [])
        if not strict:
            result.append('<p>' + safe(REFERENCE_REASONS.get(comparison.get('reason'), '目前没有条件完全匹配的严格参考。')) + '</p>')
        if strict: result.append('<p>找到了题面与所提供条件一致的描述性参考。计数保持原分母，不换算成型号身份概率。</p>')
        for title, rows, contextual in [('条件匹配的局部参考', strict, False), ('同题背景参考：条件不同或未知', context, True)]:
            if not rows: continue
            result.append('<h3>' + title + '</h3>')
            if contextual: result.append('<p class="muted">只展示同一道字面题目的历史观察；这些计数不进入严格比较，不代表当前回答应当复现该偏好。</p>')
            result.append('<div class="table-wrap"><table><thead><tr><th>参考标签</th><th>原有回答</th><th>局部观察计数</th><th>条件说明</th></tr></thead><tbody>')
            for cell in rows[:24]:
                counts = []
                for name, observed in cell.get('feature_comparison', {}).items():
                    label = FEATURE_LABELS.get(name, '该项行为特征')
                    if observed.get('status') == 'descriptive_count': counts.append(label + '：' + str(observed.get('same_value_count', '?')) + ' / ' + str(observed.get('observed_denominator', '?')) + ' 份出现相同取值，另缺失 ' + str(observed.get('missing', 0)) + ' 份')
                    else: counts.append(label + '：没有可比计数')
                if not counts:
                    for name, values in list(cell.get('features', {}).items())[:3]:
                        freq = sorted(values.get('value_hash_counts', {}).values(), reverse=True)
                        counts.append(FEATURE_LABELS.get(name, '记录类别') + '：各类别分别 ' + '、'.join(str(v) for v in freq[:8]) + ' 份；缺失 ' + str(values.get('missing', 0)) + ' 份')
                differences = []
                for difference in cell.get('condition_differences', []):
                    field = CONDITION_LABELS.get(difference.get('field'), '请求条件')
                    differences.append(field + ('：当前未知' if difference.get('state') == 'unknown' else '：当前 ' + _condition(difference.get('current'))) + '；参考 ' + _condition(difference.get('reference')))
                if not differences: differences = ['已提供条件与该参考一致；端点、时间等其他影响仍未全部隔离']
                result.append('<tr><td>' + safe(cell.get('model_label', '未知'), 160) + '</td><td>' + safe(cell.get('n', '未知')) + ' 份</td><td>' + '<br>'.join(safe(line, 500) for line in counts) + '</td><td>' + '<br>'.join(safe(line, 300) for line in differences) + '</td></tr>')
            result.append('</tbody></table></div>')
        if comparison.get('matched_user_record_id'): result.append('<p>' + links([comparison['matched_user_record_id']]) + '</p>')
        result.append('<details class="technical"><summary>题面标识、完整条件与参考计数</summary><pre>' + pretty(comparison, 12000) + '</pre></details>')
        return ''.join(result)

    parts.append('<h2>参考覆盖与适用范围</h2>' + reference_section(references))
    parts.append('<p class="muted">不同特征可能来自同一份回答，不能重复相加。任意自然任务不会按主题猜测研究题号；同题也需要单独说明生成条件。</p>')

    external = semantic.get('external', {})
    requests = external.get('requests', 0)
    dispatched = external.get('dispatched')
    sent = requests if dispatched is True or (dispatched is None and requests and external.get('status') not in ('disabled', 'not_dispatched', 'reserved')) else 0
    parts.append('<h2>分析方式与费用</h2><div class="panel">')
    mode = '本地提取＋外部语义解释' if sent else '本地提取'
    parts.append('<p><strong>' + mode + '</strong> · 外部已发送请求 ' + safe(sent) + ' 次。</p>')
    status_labels = {'disabled': '外部增强未启用', 'validated_proposals': '外部结果已完成引用与范围检查', 'cancelled_after_dispatch': '发送后已取消，仍需保留费用记录', 'failed_or_not_dispatched': '外部增强未完成', 'reserved': '已预留费用，尚未确认发送', 'not_dispatched': '未发送'}
    parts.append('<p>' + safe(status_labels.get(external.get('status', 'disabled'), '外部处理状态未确定')) + '</p>')
    actual = external.get('actual_cost_usd')
    estimated = external.get('estimated_cost_usd')
    held = external.get('reserved_cost_usd') if external.get('reservation_released') is False else '0' if external.get('reservation_released') is True or not sent else None
    def money(value): return '$' + safe(value, 100) if value is not None else '未提供'
    if not requests and not sent: actual = '0'
    parts.append('<div class="cards">')
    for title, value, explanation in [('接口报告的实际费用', actual, '有接口费用回执才列为实际费用；不把预留额当消费。'),
                                       ('按用量和配置价格估算', estimated, '这是估算，与实际账单分开。'),
                                       ('尚未结算的预留', held, '缺少用量或请求中断时保留，避免重复花费。')]:
        parts.append('<section class="card"><h3>' + title + '</h3><p class="amount">' + money(value) + '</p><p class="muted">' + explanation + '</p></section>')
    parts.append('</div>')
    if external.get('safe_reason'): parts.append('<p>' + safe(external['safe_reason'], 800) + '</p>')
    if external.get('omitted_record_ids'): parts.append('<p>外部增强未覆盖 ' + str(len(external['omitted_record_ids'])) + ' 条消息；本地已有观察继续保留。</p>')
    parts.append('<details class="technical"><summary>请求、用量及结算字段</summary><pre>' + pretty(external, 6000) + '</pre></details></div>')

    parts.append('<h2>仍需保留的未知范围</h2><p class="muted">缺失、尚未实现与不适用分别记录；它们不是模型能力失败。</p><ul>')
    for item in unknowns:
        code = str(item.get('code', ''))
        title = UNKNOWN_LABELS.get(code, '该项观察尚未确定')
        reason = str(item.get('reason', ''))
        chinese_reason = reason if re.search(r'[\u4e00-\u9fff]', reason) else ''
        parts.append('<li><strong>' + safe(title, 200) + '</strong>' + ('：' + safe(chinese_reason, 600) if chinese_reason else '') + ' ' + links(item.get('evidence', [])) + '<details class="technical"><summary>具体限制</summary><p><code>' + safe(code, 200) + '</code></p><p>' + safe(reason, 900) + '</p></details></li>')
    parts.append('</ul>')

    parts.append('<details><summary>结构记录、其余观察与模块覆盖</summary><p class="muted">记录数量和文本长度仅用于说明可见范围，不计为语义理解或任务完成。</p>')
    for fact in facts:
        if fact.get('id') not in selected_ids: parts.append(card(fact))
    parts.append('<h3>覆盖情况</h3><p>总记录 ' + safe(coverage.get('records_total', '未知')) + ' · 去重后 ' + safe(coverage.get('records_unique', '未知')) + ' · 用于观察 ' + safe(coverage.get('records_used', '未知')) + '。使用比例不是检测准确率。</p><table><thead><tr><th>模块</th><th>当前支持</th></tr></thead><tbody>')
    for module, status in coverage.get('modules', {}).items(): parts.append('<tr><td>' + safe(module, 100) + '</td><td>' + safe(MODULE_LABELS.get(status, status), 160) + '</td></tr>')
    parts.append('</tbody></table><pre>' + pretty(semantic.get('coverage', {})) + '</pre></details>')
    parts.append('<h2>可回查的原始片段</h2><p class="muted">只读取本次传入的会话文档，不按来源路径重新打开文件。展示时隐藏常见凭据。0、null 与字段缺失分别保留。</p>')
    for eid in evidence_ids:
        pointer, record = locate(eid)
        parts.append('<details id="' + anchors[eid] + '"><summary>' + safe(eid, 180) + ' · ' + safe(pointer or '位置未确定', 160) + '</summary>')
        if pointer is None: parts.append('<p>当前文档没有唯一可回查位置。</p></details>'); continue
        if isinstance(record, dict):
            parts.append('<p>角色：' + safe(ACTOR_LABELS.get(record.get('role'), record.get('role', '未知')), 100) + ' · 类型：' + safe(record.get('kind', '字段'), 100) + '</p>')
            if record.get('source_pointer'): parts.append('<p class="muted">原件定位（仅展示）：</p><pre>' + pretty(record['source_pointer'], 1200) + '</pre>')
            if record.get('actor_source_pointer'): parts.append('<p class="muted">角色来源定位：</p><pre>' + pretty(record['actor_source_pointer'], 1200) + '</pre>')
            parts.append('<pre>' + pretty(record.get('data', record), MAX_SNIPPET) + '</pre>')
        else: parts.append('<pre>' + pretty(record, MAX_SNIPPET) + '</pre>')
        parts.append('</details>')
    if len(all_evidence) > MAX_EVIDENCE: parts.append('<p>其余证据可通过本地 report.json 的位置索引回查。</p>')
    footer_mode = '本次报告生成未向外部模型发送请求。' if not sent else '本次报告生成曾向已配置的外部语义服务发送 ' + str(sent) + ' 次请求，费用与未结预留见上方。'
    parts.append('<footer>' + safe(footer_mode) + '报告呈现不会执行日志命令或重新读取来源引用。L1 层级不代表证据强弱；本报告不提供模型身份概率，也不把局部语言观察当作通用任务正确性认证。</footer></details></body></html>')
    return ''.join(parts)
