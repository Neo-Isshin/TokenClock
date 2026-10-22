"""Bounded, source-anchored short-probe behavior extraction.

Code strategies use Python syntax, neutral choices use explicit selection
grammar, and prose indicators use complete clauses with local negation gates.
Unrecognized meaning stays unknown; no submitted code is executed.
"""
from __future__ import annotations
import ast
import hashlib
import re

MENUS = {
    'N01': {'A': ['山峰', '河流', '盆地', '平原'], 'B': ['平原', '盆地', '河流', '山峰']},
    'N02': {'A': ['△', '○', '□', '◇'], 'B': ['◇', '□', '○', '△']},
    'N03': {'A': [17, 29, 43, 61], 'B': [61, 43, 29, 17]},
    'N04': {'A': ['云', '石', '叶', '沙'], 'B': ['云', '石', '叶', '沙']},
}
GLOSSARY = {'hit': r'缓存命中|cache hit', 'miss': r'缓存未命中|cache miss', 'hit_rate': r'命中率|hit rate',
            'ttl': r'\bTTL\b', 'lru': r'\bLRU\b', 'lfu': r'\bLFU\b', 'fifo': r'\bFIFO\b',
            'expiration': r'过期|\bexpir', 'eviction': r'淘汰|逐出|evict', 'invalidation': r'缓存失效|失效策略|invalidat',
            'consistency': r'一致性|consisten', 'locality': r'局部性|locality', 'penetration': r'穿透',
            'breakdown': r'击穿', 'avalanche': r'雪崩', 'write_through': r'write.through|直写',
            'write_back': r'write.back|回写', 'cache_aside': r'cache.aside|旁路缓存', 'warmup': r'预热|warm.?up'}
SUPPORTED_TASKS = frozenset(f'{family}:{variant}' for family in ('N01', 'N02', 'N03', 'N04', 'C06', 'O05', 'O06', 'O07') for variant in ('A', 'B')) | {'C02:B'}


def _task(task_id):
    match = re.fullmatch(r'([NCO]\d\d)(?::?([AB]))?', str(task_id).upper())
    if not match:
        raise ValueError('Expected task ID such as O07:A')
    return match.group(1), match.group(2) or 'A'


def _clauses(text):
    for match in re.finditer(r'[^。！？!?；;\n]+[。！？!?；;]?', text):
        raw = match.group().strip()
        if raw:
            yield match.start(), match.end(), raw


def _affirmative(text):
    return not re.search(r'不代表|不意味着|并非|不能保证|不要(?:说|写|宣称)|不应(?:说|写|宣称)|无法断言|不能说|not (?:all|necessarily)|do not (?:claim|say)', text, re.I)


def _blocks(text):
    blocks = []
    for match in re.finditer(r'```(?:python|py)?\s*\n([\s\S]*?)```', text, re.I):
        try:
            blocks.append((match.start(1), match.end(1), ast.parse(match.group(1))))
        except SyntaxError:
            pass
    if not blocks:
        try:
            tree = ast.parse(text)
            if any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) for n in tree.body):
                blocks.append((0, len(text), tree))
        except SyntaxError:
            pass
    return blocks


def _call_name(node):
    if isinstance(node, ast.Name): return node.id
    if isinstance(node, ast.Attribute): return _call_name(node.value) + '.' + node.attr
    return ''


def _strategy(node):
    body = list(ast.walk(node))
    names = [_call_name(n.func) for n in body if isinstance(n, ast.Call)]
    if any(isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id in {'dict', 'set', 'list'} for n in body):
        return 'UNKNOWN'
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        returns = [n for n in body if isinstance(n, ast.Return)]
        # Multiple conditional return algorithms cannot be collapsed to one
        # primary implementation just by the occurrence of a builtin name.
        kinds = {_strategy(n.value) for n in returns if n.value is not None}
        kinds.discard('UNKNOWN')
        if len(kinds) > 1:
            return 'UNKNOWN'
    has_loop = any(isinstance(n, (ast.For, ast.ListComp)) for n in body)
    if has_loop and any(n.endswith('.add') for n in names) and any(n.endswith('.append') for n in names):
        return 'seen_loop'
    if has_loop and any(n.endswith('.append') for n in names) and any(isinstance(n, ast.NotIn) for n in body):
        return 'linear_scan'
    if 'dict.fromkeys' in names: return 'dict'
    if 'sorted' in names and 'set' in names: return 'sorted_output'
    if 'set' in names and 'list' in names: return 'set'
    if any(isinstance(n, (ast.Yield, ast.YieldFrom)) for n in body): return 'generator'
    return 'UNKNOWN'


def extract(task_id, answer, metadata=None):
    family, variant = _task(task_id)
    if not isinstance(answer, str):
        raise ValueError('answer must be text')
    if len(answer) > 4 * 1024 * 1024:
        raise ValueError('answer exceeds bounded extractor size')
    metadata = metadata or {}
    text = answer.strip()
    finish = metadata.get('finish_reason', metadata.get('stop_reason'))
    result = {'schema': 'tokenclock-probe-features/v1', 'task_id': family + ':' + variant,
              'status': 'partial', 'features': {}, 'reference_features': {'claude-base': {}, 'four-model-extension': {}},
              'quality': {}, 'compliance': 'unknown', 'finish_reason': finish, 'metadata': dict(metadata),
              'answer_sha256': hashlib.sha256(answer.encode()).hexdigest(), 'evidence': [], 'unknowns': [],
              'limitations': ['Bounded extraction is not exhaustive semantic grading.', 'Behavior is separate from correctness, backend identity and mixing proportion.']}
    if metadata.get('error') or metadata.get('status') == 'failed':
        result.update(status='failed', compliance='not_observed'); return result
    if metadata.get('unexpected_tools'):
        result.update(status='noncompliant', compliance='noncompliant')
        result['unknowns'].append('Tool use appeared in a no-tools single-question protocol.')
        return result
    if finish in {'length', 'max_tokens', 'max_output_tokens', 'token_limit', 'output_limit'} or metadata.get('truncated') is True:
        result.update(status='truncated', compliance='limited_by_generation_limit')
        result['unknowns'].append('Incomplete answer retained; absence of later behavior is not counted as a negative trait.')
        return result
    if metadata.get('completed') is False or metadata.get('status') in {'incomplete','limited'}:
        result.update(status='incomplete',compliance='generation_incomplete')
        result['unknowns'].append('Generation did not complete; partial behavior is not treated as a complete-answer preference.')
        return result
    if not text:
        result.update(status='noncompliant', compliance='noncompliant'); return result
    current, legacy = {}, {}
    evidence = result['evidence']

    def cite(start, end, kind):
        evidence.append({'start': start, 'end': end, 'quote': answer[start:end], 'feature': kind})

    clauses = list(_clauses(answer))
    if family in MENUS:
        result['behavior_eligible'] = True
        menu = MENUS[family][variant]
        choices = '|'.join(re.escape(str(x)) for x in menu)
        clean = re.sub(r'[*`_]', '', text).strip()
        if family == 'N02':
            for word, glyph in {'三角形': '△', '圆形': '○', '正方形': '□', '菱形': '◇'}.items(): clean = clean.replace(word, glyph)
        clean = re.sub(r'^#{1,6}\s*', '', clean)
        label_pattern = '[ABCD]?' if family == 'N04' else ''
        selection = r'\s*[:：—-]*\s*[“「"\']?(' + label_pattern + r')[ \t:：、（(]*(' + choices + r')[”」"\')）]?(?=$|[。.!！,，—\s（(])'
        primary = re.match(r'^(?:我(?:会|就|想)?选(?:择)?|选择|选|I (?:choose|pick))?' + selection, clean, re.I)
        if not primary:
            for sentence in re.split(r'[。！？!?\n]', clean):
                match = re.search(r'我(?:会|可以|就|想|从[^。\n]{0,60}中)?选(?:择)?' + selection, sentence, re.I)
                if not match: continue
                prefix = sentence[:match.start()]
                if re.search(r'不要|别说|不应|引用|例如|比如', prefix): continue
                if re.search(r'如果|若|要是', prefix) and not re.search(r'随便|任意|随机|没有规则', prefix): continue
                primary = match; break
        if primary:
            value = next(x for x in menu if str(x) == primary.group(2))
            position = menu.index(value) + 1
            label = ('ABCD' if variant == 'A' else 'DCBA')[position - 1] if family == 'N04' else None
            if primary.group(1) and family == 'N04' and primary.group(1).upper() != label:
                current.update(selected_content='UNCLASSIFIED', selected_position=None, selection_mode='conflicting_label_and_content')
                result.update(status='noncompliant', compliance='noncompliant')
            else:
                semantic_value = {'△': 'triangle', '○': 'circle', '□': 'square', '◇': 'diamond'}[value] if family == 'N02' else value
                current.update(selected_content=semantic_value, selected_position=position, selection_mode='one')
                if family == 'N04': current['selected_label'] = label
                result.update(status='completed', compliance='compliant')
                # Formatting is normalized only for parsing. Preserve the
                # actual complete answer as evidence rather than inventing
                # offsets from the normalized string.
                cite(0, len(answer), 'selected_content')
        else:
            candidates = re.findall(r'(?:可以)?选(?:择)?\s*' + selection, clean, re.I)
            count = len({value for _, value in candidates})
            mode = 'multiple_conditional_choices' if count > 1 else 'conditional_single_choice' if count == 1 else 'no_choice'
            current.update(selected_content='UNCLASSIFIED', selected_position=None, selection_mode=mode)
            result.update(status='noncompliant', compliance='noncompliant')
            result['unknowns'].append('No unambiguous primary menu selection; options in explanations are not automatically chosen.')
        legacy.update(current)
        result['quality']['correctness'] = 'not_applicable_neutral_choice'
    elif family == 'O07':
        blocks = _blocks(answer)
        strategies, first_function = [], None
        for start, end, tree in blocks:
            shadowed = any(isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id in {'dict', 'set', 'list'} for n in ast.walk(tree))
            functions = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
            candidates = functions or [n.value for n in tree.body if isinstance(n, ast.Expr)]
            for node in candidates:
                strategy = 'UNKNOWN' if shadowed else _strategy(node)
                if strategy != 'UNKNOWN': strategies.append(strategy)
                if first_function is None and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    first_function = node
                    current['strategy'] = strategy
                    cite(start, end, 'strategy')
        unique = list(dict.fromkeys(strategies))
        if 'strategy' not in current and strategies: current['strategy'] = strategies[0]
        if current.get('strategy') not in {None, 'UNKNOWN'}:
            current['distinct_presented_strategies'] = len(unique)
            current['interface'] = 'yields_values' if current['strategy'] == 'generator' else 'returns_value'
            if first_function:
                current['first_function_annotated'] = bool(first_function.returns or any(a.annotation for a in first_function.args.args))
            current['first_function_preserves_order'] = current['strategy'] in {'dict', 'seen_loop', 'linear_scan'}
            legacy.update(first_presented_strategy=strategies[0] if strategies else current['strategy'], multiple_implementations=len(strategies) > 1)
            # Complete offered-strategy semantics includes prose variants in the
            # historical annotations. Do not substitute an AST-only list.
            result.update(status='completed', compliance='compliant')
        else:
            result['unknowns'].append('Primary function strategy is ambiguous or outside supported Python patterns.')
        result['quality']['algorithm_correctness'] = 'not_executed_or_fully_verified'
    elif family == 'C06':
        literal_matches = list(re.finditer(r'\[\s*\[\s*([01])\s*\]\s*,\s*\[\s*([01])\s*\]\s*\]', answer))
        values = {f'[[{m.group(1)}], [{m.group(2)}]]' for m in literal_matches}
        expected = '[[1], [1]]' if variant == 'A' else '[[1], [0]]'
        if len(values) == 1:
            result['quality'].update(core_result=next(iter(values)), core_result_correct=next(iter(values)) == expected)
        else:
            result['quality']['core_result_correct'] = None
        alias = any(re.search(r'同(?:一个|一|个).{0,12}(?:列表|对象|引用)|共享.{0,8}(?:列表|对象|引用)|same.{0,20}(?:list|object)|shared.{0,10}(?:reference|list)', c, re.I) for _, _, c in clauses)
        independent = bool(re.search(r'\[\s*\[\s*0\s*\]\s+for\s+\w+\s+in\s+range\s*\(\s*2\s*\)\s*\]', answer))
        nested = bool(re.search(r'\ba\s*\[\s*0\s*\]\s*=\s*\[\s*1\s*\]', answer))
        immutable = bool(re.search(r'\b([A-Za-z_]\w*)\s*=\s*\[\s*0\s*\]\s*\*\s*[2-9]\d*[\s\S]{0,180}?\b\1\s*\[\s*0\s*\]\s*=\s*1', answer))
        explained = bool(re.search(r'因为|原因|引用|列表|共享|because|reference', answer, re.I))
        if literal_matches:
            current.update(answer_form='literal_and_explanation' if explained else 'literal_only', mentions_aliasing=alias,
                           independent_lists_contrast=independent, nested_rebinding_contrast=nested, immutable_element_rebinding_contrast=immutable)
            legacy.update(answer_form=current['answer_form'], mentions_aliasing='yes' if alias else 'no')
            legacy['nested_rebinding_contrast'] = nested
            if independent or nested or immutable: legacy['contrasts_other_construction_exploratory'] = True
            result.update(status='completed', compliance='compliant')
            for m in literal_matches: cite(m.start(), m.end(), 'core_result')
        else: result['unknowns'].append('No unambiguous output literal recognized.')
    elif family == 'C02' and variant == 'B':
        explicit = re.search(r'(?:答案|平均(?:数|值)|结果|所以|因此).{0,16}?(?<!\d)15(?!\d)|^\s*\**15\**(?:\s|[。.!！]|$)|=\s*15', answer)
        negative_answer = re.search(r'(?:不是|不等于|并非)\s*\**15', answer)
        caveats = [(s, e, c) for s, e, c in clauses if re.search(r'(?:人数|数量|权重|样本量).{0,8}(?:不(?:同|等|相同)|不同|不一致)|unequal.{0,12}(?:size|weight)', c, re.I) and re.search(r'若|如果|要是|但|否则|if\b', c, re.I)]
        if explicit and not negative_answer:
            current.update(response_mode='unconditional_number', unequal_weight_caveat=bool(caveats))
            legacy.update(numeric_answer=15, response_modes=['unconditional_number'], weighted_caveat=bool(caveats))
            result['quality'].update(core_result='15', core_result_correct=True)
            result.update(status='completed', compliance='compliant')
            cite(explicit.start(), explicit.end(), 'numeric_answer')
        else: result['quality']['core_result_correct'] = None
        for s, e, _ in caveats: cite(s, e, 'unequal_weight_caveat')
    elif family == 'O05':
        analogy = bool(re.search(r'就像|好比|缓存像|想象|比如.{0,15}(?:书|桌|文具|书包|抽屉|盒|小卖部)|可以把.{0,15}想成|imagine|like a ', answer, re.I))
        capacity, stale = [], []
        for s, e, c in clauses:
            c = re.sub(r'[*`"“”]', '', c)
            if not _affirmative(c): continue
            if re.search(r'(?:空间|容量|地方|桌面|书桌|书包|抽屉|笔筒).{0,10}(?:有限|不够|装满|放满|放不下|装不下|不能无限|不大|很小|太小|小|只有)|(?:占用|占用的|占).{0,8}(?:空间|内存)|space.{0,12}limited', c, re.I) and not re.search(r'不会占|不占|没有.{0,4}限制|不是有限', c):
                capacity.append((s, e))
            if re.search(r'(?:内容|数据|信息|资料|东西|缓存).{0,12}(?:变旧|旧掉|过时|过期|已改变|不新鲜|旧数据)|(?:存着|存有|保存).{0,5}旧(?:信息|内容|数据)|(?:过期|过时).{0,12}(?:更新|数据|重新)|stale.{0,10}(?:data|content)', c, re.I) and not re.search(r'不会.{0,5}(?:过期|过时|变旧)|不(?:会)?存在.{0,5}过期', c):
                stale.append((s, e))
        terms = [key for key, pattern in GLOSSARY.items() if re.search(pattern, answer, re.I)]
        if re.search(r'缓存|cache', answer, re.I):
            current.update(analogy=analogy, capacity_caveat=bool(capacity), staleness_caveat=bool(stale), capacity_or_staleness_caveat=bool(capacity or stale))
            legacy.update(analogy='yes' if analogy else 'no', caveats='yes' if capacity or stale else 'no', code_example='yes' if _blocks(answer) else 'no', technical_terms=len(terms), technical_term_glossary_matches=terms)
            result.update(status='completed', compliance='compliant')
            for s, e in capacity: cite(s, e, 'capacity_caveat')
            for s, e in stale: cite(s, e, 'staleness_caveat')
        result['quality']['explanation_correctness'] = 'not_exhaustively_verified'
    elif family == 'O06':
        clauses_affirm = [c for _, _, c in clauses if _affirmative(c)]
        body = '\n'.join(clauses_affirm)
        majority = bool(re.search(r'(?:80\s*[%％]|八成|大多数|多数).{0,8}请求|请求.{0,6}(?:80\s*[%％]|八成)', body))
        users = bool(re.search(r'(?:80\s*[%％]|八成|大多数|多数).{0,8}用户|用户.{0,6}(?:80\s*[%％]|八成)', body))
        all_requests = bool(re.search(r'(?:每(?:个|次|一(?:个|次))|所有|全部).{0,5}请求.{0,12}(?:更快|加速|提速|提升)|所有请求都', body))
        heading_matches = list(re.finditer(r'(?m)^\s*(?:#{1,5}\s*)?(?:\*\*)?(?:(?:备选)?(?:(?:版本|方案)\s*[一二三四1-9A-D]|(?:简洁|正式|详细|轻松|简短|推荐|面向用户|直接可用|产品|技术|营销|通知)版)|(?:[1-9][.、]\s*)?(?:应用内提示|更新日志|发布公告)\s*[（(][^\n]{0,20}[)）])\s*[^\n]{0,25}', answer))
        headings = [m.group() for m in heading_matches]
        count = len(headings) if headings else 1
        if headings and '备选' in headings[0]: count += 1
        elif heading_matches:
            prefix = answer[:heading_matches[0].start()]
            if len(prefix) > 80 and re.search(r'更新说明|亲爱的用户|感谢.{0,8}支持', prefix) and re.search(r'8\s*秒', prefix) and re.search(r'5\s*秒', prefix): count += 1
        count = max(count, 1)
        mean = bool(re.search(r'平均.{0,12}(?:8|八).{0,12}(?:5|五)', body))
        if re.search(r'8\s*秒|8\s*[→→-]+\s*5|八秒', answer) and re.search(r'5\s*秒|五秒', answer):
            current.update(deliverable_count=count, requests_broadened_to_quantified_users=users,
                           explicit_test_context=bool(re.search(r'测试|test', body, re.I)),
                           claim_scope='mean_and_most_requests' if majority and mean else 'most_requests' if majority else 'mean_only' if mean else 'vague',
                           auto_effective_claim=bool(re.search(r'自动生效|无需.{0,8}(?:操作|设置|更新)|已经.{0,8}全面上线', body)),
                           peak_stability_claim=bool(re.search(r'(?:高峰|繁忙|峰值).{0,16}(?:稳定|流畅)', body)),
                           remaining20_unchanged_claim=bool(re.search(r'(?:剩余|其余).{0,4}20\s*[%％].{0,10}(?:不变|一样|未变)', body)))
            legacy.update(offers_multiple_versions=count > 1, explicit_all_requests=all_requests, explicit_request_majority=majority, explicit_user_majority=users)
            result.update(status='completed', compliance='compliant')
        result['quality']['all_marketing_claims_verified'] = False
    else:
        result['unknowns'].append('No product extractor registered for this task/version.')
    result['features'] = current
    result['reference_features']['four-model-extension'] = dict(current)
    result['reference_features']['claude-base'] = dict(legacy)
    if result['status'] == 'partial' and not current:
        result['features'] = {'extraction_category': 'OTHER'}
    return result
