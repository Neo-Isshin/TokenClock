"""Bounded, non-executing H01 public-interface interpretation.

These are declarations, not verified behavior. Syntax evidence selects one
adapter before execution; candidate scores never select an entry or a unit.
"""
import ast
import hashlib
import re


def select_python(text):
    matches = list(re.finditer(r'```(?:python|py)\s*\n([\s\S]*?)\n```', text, re.I))
    if not matches:
        return text, {'kind': 'whole_file', 'selected_block': None, 'ignored_blocks': []}
    selected = 0
    usage_links = []
    if len(matches) > 1:
        programs = []
        trees = []
        for index, match in enumerate(matches):
            try: tree = ast.parse(match.group(1))
            except (SyntaxError, ValueError, RecursionError):
                raise ValueError('Multiple blocks include unparseable or ambiguous Python') from None
            trees.append(tree)
            if any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) for n in ast.walk(tree)):
                programs.append(index)
        if len(programs) != 1:
            raise ValueError('Multiple Python programs need explicit selection')
        selected = programs[0]
        names = {n.name for n in trees[selected].body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
        for index, tree in enumerate(trees):
            if index == selected: continue
            linked = sorted({n.id for n in ast.walk(tree) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id in names})
            stdin_contract = re.search(r'(?i)stdin_json|H01\s+interface', ast.get_docstring(tree) or '')
            reads_input = any(isinstance(n, ast.Name) and n.id == 'input' or isinstance(n, ast.Attribute) and n.attr in ('stdin', '__stdin__') for n in ast.walk(tree))
            if not linked or stdin_contract or reads_input:
                raise ValueError('Other Python block is not a linked, non-input usage example')
            usage_links.append({'block': index, 'declared_names_used': linked})
    match = matches[selected]
    return match.group(1), {'kind': 'unique_definition_block' if len(matches) > 1 else 'single_code_block',
        'selected_block': selected, 'source_start': match.start(1), 'source_end': match.end(1),
        'ignored_blocks': [i for i in range(len(matches)) if i != selected],
        'usage_links': usage_links,
        'ignored_blocks_executed': False, 'selection_uses_execution_results': False}


def _args(node):
    return [x.arg for x in node.args.posonlyargs + node.args.args]


def _method(node, names):
    return isinstance(node, ast.FunctionDef) and not node.decorator_list and not node.args.vararg and not node.args.kwarg and _args(node)[:len(names)] == names


def _defaults_after(node, supplied):
    return len(_args(node)) - len(node.args.defaults) <= supplied and all(x is not None for x in node.args.kw_defaults)


def _evidence(code, node, purpose):
    return {'purpose': purpose, 'line': node.lineno, 'end_line': node.end_lineno,
            'quote': ast.get_source_segment(code, node)}


def _shadowed(tree, node, name):
    for other in tree.body:
        if other is node: continue
        for child in ast.walk(other):
            if isinstance(child, ast.Name) and child.id == name and isinstance(child.ctx, (ast.Store, ast.Del)): return True
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and child.name == name: return True
            if isinstance(child, ast.alias) and (child.asname or child.name.split('.')[0]) == name: return True
            if isinstance(child, ast.Attribute) and isinstance(child.value, ast.Name) and child.value.id == name and isinstance(child.ctx, (ast.Store, ast.Del)): return True
    return False


def _scale(tree, direction):
    for n in ast.walk(tree):
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Mult if direction == 1 else ast.Div) and isinstance(n.right, ast.Constant) and n.right.value == 100:
            return True
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'scaleb' and len(n.args) == 1:
            value = n.args[0]
            if direction == 1 and isinstance(value, ast.Constant) and value.value == 2: return True
            if direction == -1 and isinstance(value, ast.UnaryOp) and isinstance(value.op, ast.USub) and isinstance(value.operand, ast.Constant) and value.operand.value == 2: return True
    return False


def infer_ledger(code):
    """Recognize conventional Ledger declarations with explicit monetary units.

    No dynamic classes/decorated public methods, optimizer override, competing
    entry attempts, hidden member access, or candidate mutation is supported.
    """
    try: tree = ast.parse(code)
    except (SyntaxError, ValueError, RecursionError): return None
    if any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in
           {'exec', 'eval', 'setattr', 'delattr', 'globals', 'locals'} for n in ast.walk(tree)):
        return None  # Runtime rebinding cannot be established by this syntax adapter.
    classes = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Ledger']
    if len(classes) != 1: return None
    cls = classes[0]
    if cls.bases or cls.keywords or cls.decorator_list or _shadowed(tree, cls, 'Ledger'): return None
    methods = [n for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
    by_name = {n.name: n for n in methods}
    if len(by_name) != len(methods): return None
    if set(by_name) & {'__getattribute__', '__getattr__', '__new__'}: return None
    # Assignments/deletes of any public method also make its runtime binding uncertain.
    for n in ast.walk(cls):
        if isinstance(n, ast.Attribute) and n.attr in {'add', 'add_expense', 'settle', 'balances', 'balances_cents'} and isinstance(n.ctx, (ast.Store, ast.Del)): return None
    for n in cls.body:
        if isinstance(n, (ast.Assign, ast.AnnAssign)):
            targets = n.targets if isinstance(n, ast.Assign) else [n.target]
            if any(isinstance(t, ast.Name) and t.id in by_name for t in targets): return None
    init, settle = by_name.get('__init__'), by_name.get('settle')
    if not init or not _method(init, ['self']) or not settle or not _method(settle, ['self']) or not _defaults_after(settle, 1): return None
    constructor = 'people' if _args(init)[1:2] == ['people'] else 'noargs'
    if not _defaults_after(init, 2 if constructor == 'people' else 1): return None
    adds = [n for n in methods if n.name in ('add', 'add_expense') and _method(n, ['self'])
            and set(_args(n)[1:4]) == {'payer', 'amount', 'beneficiaries'} and _defaults_after(n, 4)]
    if len(adds) != 1: return None
    add = adds[0]
    functions = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    conversions = [n for n in functions.values() if n.name in ('to_cents', 'yuan_to_cents') and not n.decorator_list
                   and _scale(n, 1) and not _shadowed(tree, n, n.name)]
    reachable = [add]
    # The public convenience wrapper may pass Expense(...), whose implementation
    # supplies the documented conversion. Only these local definitions are read.
    if any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'Expense' for n in ast.walk(add)):
        reachable += [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Expense']
    conversion = next((fn for fn in conversions if any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == fn.name for owner in reachable for n in ast.walk(owner))), None)
    if conversion is None: return None
    evidence = [_evidence(code, init, 'constructor_defaults'), _evidence(code, add, 'expense_argument_order'),
                _evidence(code, conversion, 'declared_major_currency_to_cents'), _evidence(code, settle, 'public_settlement_output')]
    transfer = None
    annotation = ast.unparse(settle.returns) if settle.returns else ''
    if annotation in ('list[Transfer]', 'List[Transfer]'):
        ts = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Transfer']
        if len(ts) != 1 or _shadowed(tree, ts[0], 'Transfer'): return None
        fields = {n.target.id: ast.unparse(n.annotation) for n in ts[0].body if isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name)}
        pair = next((p for p in (['from_', 'to'], ['payer', 'payee']) if all(fields.get(k) == 'str' for k in p)), None)
        if pair and fields.get('cents') == 'int':
            transfer = {'kind': 'attributes', 'fields': pair + ['cents'], 'unit': 'cents'}
            evidence.append(_evidence(code, ts[0], 'declared_transfer_fields_and_cent_unit'))
    else:
        # Dollar tuples need an explicit per-transfer conversion, not float type
        # guessing. Cent tuples require the public method's explicit unit contract.
        dollar_calls = [n for n in ast.walk(settle) if isinstance(n, ast.Tuple) and len(n.elts) == 3
                        and isinstance(n.elts[2], ast.Call) and isinstance(n.elts[2].func, ast.Name)
                        and n.elts[2].func.id in functions and _scale(functions[n.elts[2].func.id], -1)]
        if dollar_calls:
            annotations = []
            for node in ast.walk(settle):
                if isinstance(node, ast.AnnAssign): annotations.append(node.annotation)
                if isinstance(node, ast.arg) and node.annotation is not None: annotations.append(node.annotation)
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.returns is not None: annotations.append(node.returns)
            annotation_nodes = {n for annotation in annotations for n in ast.walk(annotation)}
            if any(isinstance(n, ast.Tuple) and len(n.elts) == 3 and n not in dollar_calls and n not in annotation_nodes for n in ast.walk(settle)):
                return None  # Mixed/ambiguous monetary tuple declarations stay unknown.
            names = {n.elts[2].func.id for n in dollar_calls}
            if len(names) != 1: return None
            conversion_out = functions[next(iter(names))]
            if conversion_out.decorator_list or _shadowed(tree, conversion_out, conversion_out.name): return None
            transfer = {'kind': 'triples', 'unit': 'major_currency'}
            evidence.append(_evidence(code, conversion_out, 'explicit_return_amount_conversion'))
        elif re.search(r'\([^\n)]*(?:付款人|sender)[^\n)]*,\s*(?:收款人|recipient)[^\n)]*,\s*(?:分|cents)\s*\)', ast.get_docstring(settle) or '', re.I):
            transfer = {'kind': 'triples', 'unit': 'cents'}
    if transfer is None: return None
    balance = None
    for name in ('balances_cents', 'balances'):
        n = by_name.get(name)
        if n is None or not _method(n, ['self']) or not _defaults_after(n, 1): continue
        if name == 'balances_cents' or re.search(r'（分）|\(cents\)', ast.get_docstring(n) or '', re.I):
            balance = {'method': name, 'unit': 'cents'}
        elif any(isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in functions and _scale(functions[c.func.id], -1) for c in ast.walk(n)):
            balance = {'method': name, 'unit': 'major_currency'}
        if balance:
            evidence.append(_evidence(code, n, 'reported_balance_unit')); break
    return {'mode': 'public_ledger', 'class': 'Ledger', 'constructor': constructor,
            'add': add.name, 'arguments': _args(add)[1:4], 'transfer': transfer, 'balance': balance,
            'program_sha256': hashlib.sha256(code.encode()).hexdigest(),
            'inference_basis': 'bounded_ast_public_ledger_declarations_v1',
            'evidence': evidence, 'interpretation_scope': 'declared_interface_not_behavior_or_semantic_certification',
            'settle_options_overridden': False, 'remainder_policy': 'any_conserving'}


def ledger_adapter(interface):
    """Render only a parser-produced finite interface; no user expression eval."""
    if interface.get('class') != 'Ledger' or interface.get('constructor') not in ('people', 'noargs') or interface.get('add') not in ('add', 'add_expense'):
        raise ValueError('Unsupported Ledger interface')
    args = interface.get('arguments')
    if not isinstance(args, list) or len(args) != 3 or set(args) != {'payer', 'amount', 'beneficiaries'}: raise ValueError('Unsupported expense mapping')
    transfer = interface.get('transfer', {})
    if transfer.get('kind') == 'attributes':
        if transfer.get('fields') not in (['from_', 'to', 'cents'], ['payer', 'payee', 'cents']) or transfer.get('unit') != 'cents': raise ValueError('Unsupported transfer mapping')
        projection = '[' + ','.join('getattr(t,' + repr(k) + ')' for k in transfer['fields']) + ']'
    elif transfer.get('kind') == 'triples': projection = 'list(t)'
    else: raise ValueError('Unsupported transfer representation')
    if transfer.get('unit') not in ('cents', 'major_currency'): raise ValueError('Unsupported amount unit')
    balance = interface.get('balance')
    if balance and (balance.get('method') not in ('balances', 'balances_cents') or balance.get('unit') not in ('cents', 'major_currency')): raise ValueError('Unsupported balance mapping')
    expr = {'payer': "expense['payer']", 'beneficiaries': "expense['beneficiaries']", 'amount': 'amount'}
    code = '  ledger = module.Ledger(' + ("case['people']" if interface['constructor'] == 'people' else '') + ')\n'
    code += '  for expense in case[\'expenses\']:\n   amount = f"{expense[\'amount_cents\']//100}.{expense[\'amount_cents\']%100:02d}"\n'
    code += '   ledger.' + interface['add'] + '(' + ','.join(expr[k] for k in args) + ')\n'
    code += '  transfers = [' + projection + ' for t in ledger.settle()]\n'
    if transfer['unit'] == 'major_currency': code += '  transfers = [[a,b,str(Decimal(str(c))*100)] for a,b,c in transfers]\n'
    code += "  row = {'transfers':transfers}\n"
    if balance:
        code += '  reported = ledger.' + balance['method'] + '()\n'
        code += "  row['reported_net'] = " + ("{p:str(Decimal(str(v))*100) for p,v in reported.items()}" if balance['unit'] == 'major_currency' else 'reported') + '\n'
    return code
