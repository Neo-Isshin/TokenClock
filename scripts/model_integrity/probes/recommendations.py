"""Bounded local next-step planning, without dispatch, credentials or new budgets.

Reference separation is a transparent ordering heuristic, not calibrated
information gain. Related A/B items share a task family and are not extra votes.
"""
from collections import defaultdict
from decimal import Decimal
from importlib.resources import files
from itertools import combinations
import json
from urllib.parse import urlsplit

from .catalog import catalog, get_task
from .common import digest
from .features import SUPPORTED_TASKS
from .reference_labels import MODEL_FAMILIES, reference_label
from .transport import money, quote_request, request_body, ProbeStop

SCHEMA = 'tokenclock-next-detection/v1'
DIMENSIONS = {'N': '中性选择', 'C': '前提与自发补充', 'O': '回答方案与表达'}
FEATURE_LABELS = {'selected_content':'选择的内容','selected_position':'选项位置','selection_mode':'选择方式',
                  'deliverable_count':'提供的完整文案数量','unequal_weight_caveat':'是否自发补充人数不等的情形',
                  'capacity_or_staleness_caveat':'是否提醒容量或内容过时','staleness_caveat':'是否提醒内容过时',
                  'strategy':'采用的程序方案','first_strategy':'首个程序方案',
                  'nested_rebinding_contrast':'是否补充嵌套对象重新赋值的对照','independent_lists_contrast':'是否补充独立列表的对照',
                  'distinct_presented_strategies':'提供的不同方案数量','explicit_test_context':'是否自发联系测试情境',
                  'analogy':'是否使用类比','peak_stability_claim':'是否无依据增加高峰稳定的说法'}


def _reference():
    from .reference_release import reference
    return reference('fingerprint')


def _label(value):
    return reference_label(value)


def _budget(provider, accounting):
    if not isinstance(provider, dict) or not isinstance(accounting, dict):
        return None, False
    try:
        cap = money(provider['max_cost_usd'])
        pending = money(accounting['pending_reserved_usd'])
        used = money(accounting['budget_accounted_usd'])
        # A missing or malformed receipt is not a fresh, unspent budget.
        return max(Decimal(0), cap - used - pending), pending > 0
    except (KeyError, TypeError, ValueError):
        return None, True


def _binding(config):
    if config.get('transport_mode') != 'live':
        return None
    provider = config.get('provider') or {}
    endpoint = provider.get('endpoint')
    if not isinstance(endpoint, str):
        return None
    try:
        u = urlsplit(endpoint)
        if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment:
            return None
    except ValueError:
        return None
    if not isinstance(provider.get('model'), str):
        return None
    return {k: provider.get(k, 'responses' if k == 'api_format' else '') for k in ('endpoint', 'api_format', 'model')}


def _seen(result, subject=None, depth=0):
    if depth > 4:
        return set(), set()
    tasks = set()
    dimensions = set()
    current = result.get('subject', {}).get('id')
    if subject is None or current == subject:
        for sample in result.get('samples', []):
            if subject and sample.get('subject', {}).get('id', current) != subject:
                continue
            if isinstance(sample.get('task_id'), str):
                tasks.add(sample['task_id'])
        task = result.get('task_id')
        if isinstance(task, str):
            tasks.add(task)
        for observation in result.get('fingerprints', {}).get('observations', []):
            if subject is None or observation.get('subject_id') == subject:
                dimensions.add(observation.get('dimension'))
    for component in result.get('components', [])[:12]:
        report = component.get('report', {})
        child_tasks, child_dimensions = _seen(report.get('result', report), subject, depth + 1)
        tasks.update(child_tasks)
        dimensions.update(child_dimensions)
    return tasks, dimensions


def _candidates(reference, labels, declared):
    """Compare only same-condition, same-extractor cells with a common feature.

    Never pool sample counts across measurement contracts or annotation origins.
    Max separation per task avoids rewarding tasks simply for more features.
    """
    from .fingerprints import measurement_contract
    strata = defaultdict(dict)
    for cell in reference.get('cells', []):
        if cell.get('bank') != 'behavior' or cell.get('dimension') != 'behavior' or cell.get('origin') != 'deterministic_extractor':
            continue
        task_id = cell.get('task_id')
        if cell.get('model_label') not in labels or task_id not in SUPPORTED_TASKS:
            continue
        task = get_task(task_id)
        condition = cell.get('conditions', {})
        expected = {'system': None, 'history': None, 'tools': None, 'feedback': None,
                    'reasoning_effort': 'high', 'generation_limit': task['output_limit'], 'fresh_single_question': True}
        if any(k not in condition or condition[k] != value for k, value in expected.items()):
            continue
        if cell.get('measurement_contract') != measurement_contract(task_id):
            continue
        key = (task_id, digest(condition), digest(cell.get('measurement_contract', {})))
        model = cell['model_label']
        # Ambiguous duplicate strata are discarded, not silently counted twice.
        if model in strata[key]:
            strata[key][model] = None
        else:
            strata[key][model] = cell
    best = {}
    for (task_id, _, _), models in strata.items():
        models = {k: v for k, v in models.items() if v is not None}
        if declared and declared not in models:
            continue
        for left, right in combinations(sorted(models), 2):
            if declared and declared not in (left, right):
                continue
            a, b = models[left]['descriptors'], models[right]['descriptors']
            for feature in sorted(a.keys() & b.keys()):
                x, y = a[feature], b[feature]
                nx, ny = x.get('known_n', 0), y.get('known_n', 0)
                if min(nx, ny) < 2 or x.get('encoding') != y.get('encoding'):
                    continue
                cx, cy = x.get('counts', {}), y.get('counts', {})
                distance = sum(abs(cx.get(k, 0) / nx - cy.get(k, 0) / ny) for k in cx.keys() | cy.keys()) / 2
                if distance <= 0:
                    continue
                item = {'task_id': task_id, 'reference_separation': round(distance, 6),
                        'reference_min_n': min(nx, ny), 'reference_models': [left, right],
                        'reference_feature': feature, 'reference_cell_ids': [models[left]['id'], models[right]['id']],
                        'heuristic_not_accuracy': True}
                if task_id not in best or (distance, min(nx, ny)) > (best[task_id]['reference_separation'], best[task_id]['reference_min_n']):
                    best[task_id] = item
    return list(best.values())


def _repeat_targets(result, provider, candidates, prior_tasks):
    """One additional pair per family in this budget lineage, never endless retry."""
    from .reference_readiness import conditions
    by_task={c['task_id']:c for c in candidates};prior={x.split(':')[0] for x in prior_tasks}
    grouped=defaultdict(list)
    for sample in result.get('samples',[]):
        if isinstance(sample,dict) and sample.get('task_id') in by_task:grouped[sample['task_id']].append(sample)
    supported=set()
    from .direction_guard import evaluate
    for panel in result.get('fingerprints',{}).get('comparison_panels',[]):
        if panel.get('dimension')=='behavior' and evaluate(panel)['status']=='repeat_supported':supported.add(panel.get('task_family'))
    output=[]
    for task_id,samples in sorted(grouped.items()):
        task=get_task(task_id)
        if task_id.split(':')[0] in prior or len(samples)<2:continue
        if any(s.get('metadata',{}).get('completed')is not True or s.get('metadata',{}).get('truncated') or
               s.get('metadata',{}).get('conditions')!=conditions(task,provider) or s.get('prompt_sha256')!=task['prompt_sha256'] for s in samples):continue
        ids={s.get('record',{}).get('client_request_id') for s in samples}
        if None in ids or len(ids)!=len(samples):continue
        features=[s.get('extracted',{}).get('features',{}) for s in samples]
        common=set.intersection(*(set(f) for f in features))
        from .fingerprints import _known
        varies=any(all(_known(f[name],name) for f in features) and len({digest(f[name]) for f in features})>1 for name in common)
        if varies or task_id.split(':')[0] in supported:
            output.append((task_id,'前两次回答有差别，再独立回答两次，确认这个现象是否重复出现。' if varies else '这道题已出现一致的接近方向，再独立回答两次，确认这个线索是否重复出现。',by_task[task_id]))
    return output


def recommend(report, config=None, *, reference=None):
    config = config or {}
    result = report.get('result', report)
    lane = report.get('workflow_mode', 'l1')
    binding = _binding(config) if lane in {'l2', 'l3'} else None
    provider = config.get('provider') or {}
    remaining, pending = _budget(provider, result.get('accounting')) if binding else (None, False)
    assessment = config.get('assessment') or {}
    judge_remaining, judge_pending = _budget(assessment.get('provider'), result.get('reviewer_assessment', {}).get('accounting')) if binding and assessment.get('enabled') else (None, False)
    output = {'schema': SCHEMA, 'status': 'stop', 'summary': '', 'actions': [], 'stop_reasons': [],
              'remaining_budget_usd': str(remaining) if remaining is not None else None,
              'remaining_judge_budget_usd': str(judge_remaining) if judge_remaining is not None else None,
              'target_binding': binding, 'automatic_dispatch': False,
              'notes': ['推荐依据已有参考的局部差异、未测题族和完整费用预留；不是预测识别准确率。',
                        '点击仅配置下一次检测，仍需预览；每题独立两次，不自动重试或缩减原题输出余量。',
                        '此版优先推荐本地可核验项目；工具多轮与视觉语义任务仍可手动选择并单独预览。']}

    def stop(reason, status='stop'):
        output.update(status=status, summary=reason)
        output['stop_reasons'].append(reason)
        return output

    if result.get('l2_method')=='numeric':
        return stop('数字指纹结果已整理；不会自动追加调用。如需核对，可重新检测或选择其他方法。')

    if result.get('source_scope') == 'scripted_demo' or result.get('source', {}).get('kind') in {'scripted_demo', 'synthetic_fixture'}:
        return stop('当前是演示数据；请先配置真实送测对象，不依据演示结果追加付费检测。', 'needs_configuration')
    if pending or judge_pending:
        return stop('本次费用尚未结清或费用回执不完整；先核对费用，再决定是否继续。', 'review_first')
    if remaining is not None and remaining <= 0:
        return stop('本次授权预算已用完；保存当前观察，不自动获得新的预算。')
    if binding and provider.get('reasoning_effort','high')!='high':
        return stop('当前推理条件与题库的 high 参考不同；先明确比较条件，不能把现有差异参考直接用于此条件的推荐。', 'review_first')
    conflicts = [s for s in report.get('user_summary', {}).get('synthesis', {}).get('subjects', []) if s.get('source_conflicts')]
    if any(f.get('code') in {'source.harness_model_difference','source.harness_multiple_models_in_turn',
                            'source.comparison_target_difference','source.harness_unbound_models'} for f in result.get('facts',[])):
        return stop('先查看已定位的型号字段与调用归属；新增行为题不能追溯证明旧会话来源。','review_first')
    if conflicts or any(f.get('code') in {'source.model_claim_difference', 'source.billing_claim_difference', 'source.binding_collision'} for f in result.get('facts', [])):
        return stop('先复核具体调用的来源声明或绑定冲突；增加行为题不能解释或抵消这类记录差异。', 'review_first')
    quality = result.get('assessment_quality') or {}
    if any(s.get('metadata',{}).get('completed') is False or s.get('metadata',{}).get('truncated') or s.get('status') in {'failed','cancelled','incomplete','limited'} for s in result.get('samples',[]) if isinstance(s,dict)):
        return stop('先检查未完成回答的原因；已有内容会保留，暂不推荐继续购买其他题目。','review_first')
    if quality.get('status') == 'no_usable_observations':
        return stop('先处理已有回答的解析失败或引用问题；重新购买目标回答通常不能补上这个缺口。', 'review_first')
    if result.get('status') in {'limited', 'unsupported', 'cancelled'} and (result.get('stop') or result.get('task_id')):
        return stop('先检查本次受限或未完成原因，当前不自动推荐重复购买同类任务。', 'review_first')

    label = _label(binding['model'] if binding else config.get('comparison_target'))
    if not label:
        return stop('请先指定已有参考覆盖的比较型号和本次连接；未知型号仍可手动做交付核验。', 'needs_configuration')
    family = next(k for k, values in MODEL_FAMILIES.items() if label in values)
    peers=set()
    overlap=result.get('fingerprints',{}).get('reference_overlap',{})
    if not overlap.get('sample_identity_overlap'):
        for statement in result.get('fingerprint_interpretation',{}).get('statements',[]):
            if statement.get('state')=='local_descriptive_direction' and statement.get('mode')=='strict' and statement.get('dimension')=='behavior' and statement.get('direction_guard',{}).get('status')=='repeat_supported':
                peers.update(m for m in statement.get('nearest_labels',[]) if m in MODEL_FAMILIES[family] and m!=label)
    labels=sorted(peers|{label}) if peers else list(MODEL_FAMILIES[family])
    output['focus_reference_labels']=labels
    output['focus_reason']='优先补查当前同条件行为观察指向的其他参考；未据此确认型号。' if peers else '当前尚无可用于缩小比较范围的同条件行为方向，保留家族内参考。'
    subject = result.get('subject', {}).get('id')
    seen, observed_dimensions = _seen(result, subject)
    # Added only by the job controller from the same target's budget lineage.
    seen.update(t for t in config.get('_planning_history', []) if isinstance(t, str))
    seen_families = {task.split(':')[0] for task in seen}
    reference = reference if reference is not None else _reference()
    all_candidates=_candidates(reference, labels, label)
    candidates = [c for c in all_candidates if c['task_id'].split(':')[0] not in seen_families]
    used_categories = {task[0] for task in seen if task and task[0] in DIMENSIONS}
    candidates.sort(key=lambda c: (c['task_id'][0] in used_categories, -c['reference_separation'], -c['reference_min_n'], c['task_id']))
    rejected_budget = 0
    selected_families = set()

    def action(task_id, explanation, *, evidence=None, purpose='extend_behavior'):
        nonlocal rejected_budget
        task = get_task(task_id)
        count = 2 if task['layer'] == 'L2' else 1
        if binding and provider.get('max_requests',20)<count:
            return
        reserve = None
        if binding:
            try:
                p = {**provider, 'transport_mode': 'live'}
                reserve = money(quote_request(p, request_body(p, prompt=task['prompt'], output_limit=task['output_limit']))['reserved_usd']) * count
            except (ValueError, KeyError, TypeError, ProbeStop):
                reserve = None
            if reserve is None or remaining is None or reserve > remaining:
                rejected_budget += 1
                return
        patch = {'workflow_mode': task['layer'].lower(), 'transport_mode': 'live',
                 'provider': {'max_cost_usd': str(remaining) if remaining is not None else None},
                 'assessment': {'enabled': False, 'provider': {'max_cost_usd': str(judge_remaining) if judge_remaining is not None else None}}}
        if task['layer'] == 'L2':
            patch.update(family=family, task_ids=[task_id],repeats=2)
        else:
            patch['task_id'] = task_id
        output['actions'].append({'id': 'next-' + task_id.replace(':', '-'), 'title': ('再确认：' if purpose.startswith('repeat') else '')+task['title'],
                                  'purpose':purpose,'expected_answer':explanation,
                                  'reason': explanation, 'subject_id': subject, 'workflow_mode': patch['workflow_mode'],
                                  'family': family, 'task_ids': [task_id] if count == 2 else None,
                                  'task_id': task_id if count == 1 else None, 'request_count': count,
                                  'estimated_reserve_usd': str(reserve) if reserve is not None else None,
                                  'assessment_required': False, 'configuration_patch': patch,
                                  'reference_basis': evidence})

    if binding:
        repeats=_repeat_targets(result,provider,all_candidates,config.get('_planning_history',[]))
        if repeats:
            task_id,reason,basis=repeats[0]
            action(task_id,reason,evidence=basis,purpose='repeat_behavior')
            if output['actions']:selected_families.add(task_id.split(':')[0])
        task_id=result.get('task_id')
        if (task_id in {'H01','H02'} and result.get('status')=='completed' and task_id not in config.get('_planning_history',[])
                and any(c.get('status')=='fail' for c in result.get('checks',[]))
                and all(c.get('status')in{'pass','fail'} for c in result.get('checks',[]))):
            action(task_id,'同一任务再做一次，确认未通过的项目是否再次出现；不会把单次失败直接当作型号问题。',purpose='repeat_delivery')
    for candidate in candidates:
        task_id = candidate['task_id']
        task_family = task_id.split(':')[0]
        if task_family in selected_families:
            continue
        before = len(output['actions'])
        description=FEATURE_LABELS.get(candidate['reference_feature'],'回答的具体表现')
        action(task_id, '补充尚未测过的' + DIMENSIONS[task_id[0]] + '；同条件参考在“' + description + '”上曾有差异，较小一侧仅 ' + str(candidate['reference_min_n']) + ' 份观察。', evidence=candidate)
        if len(output['actions']) > before:
            selected_families.add(task_family)
        if len(output['actions']) >= 2:
            break

    # Complementary deterministic delivery checks, not an automatic expensive
    # agent escalation. H03/visual remain manually available with their own quote.
    needs_delivery=any(c.get('status')=='fail' for c in result.get('checks',[]))
    if seen and needs_delivery and not any(a['purpose']=='repeat_delivery' for a in output['actions']) and len(output['actions']) < 3:
        for task_id in ('H01', 'H02'):
            if task_id in seen_families:
                continue
            models = {c.get('model_label') for c in reference.get('cells', []) if c.get('bank') == 'heavy' and c.get('task_id') == task_id and c.get('dimension') == 'capability_delivery'}
            if label not in models:
                continue
            before = len(output['actions'])
            limitation='家族内只有一个型号的该项参考，不作家族内判型比较。' if len(models & set(MODEL_FAMILIES[family]))<2 else '历史作品参考数量不均，不能仅凭一次通过或失败判定型号。'
            action(task_id, '补充实际交付维度，由本地检查核验；'+limitation)
            if len(output['actions']) > before:
                break
    if not output['actions']:
        return stop('剩余预算无法完整预留一项有补充价值的检测；保留当前结果，未缩减输出上限。' if rejected_budget else '现有本地可提取题中没有合适的未测参考差异项；建议在当前范围停止，可手动选择其他交付任务。')
    output['status'] = 'recommended' if binding else 'needs_configuration'
    output['summary'] = '建议选择下面一项补充检测；它们是备选项，不是必须全部执行。' if binding else '已有参考可支持以下补充项；先明确本次接口与预算，新调用只说明新调用本身。'
    return output
