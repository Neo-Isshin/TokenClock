"""Independent settlement evaluation; candidate Python runs only in isolation."""
from __future__ import annotations

from decimal import Decimal, InvalidOperation
import ast
from functools import lru_cache
from importlib.resources import files as resource_files
import hashlib
from itertools import combinations
import json
from pathlib import Path
import re
import tempfile

from .isolation import run_isolated
from .program_interface import select_python, infer_ledger, ledger_adapter

RESOURCES = resource_files(__package__).joinpath('resources')


def _load(path):
    return json.loads(path.read_text(encoding='utf-8'))


def _save(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True); path.parent.chmod(0o700)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n'); path.chmod(0o600)


def _code(text):
    return select_python(text)[0]


def _cent(value):
    if isinstance(value, bool): raise ValueError('Boolean is not an amount')
    try: amount = Decimal(str(value))
    except (InvalidOperation, ValueError): raise ValueError('Invalid cent amount') from None
    if not amount.is_finite() or amount.copy_abs() > Decimal('1000000000000'): raise ValueError('Cent amount exceeds bounded oracle range')
    if amount != amount.to_integral_value(): raise ValueError('Noninteger or nonfinite cents')
    return int(amount)


def allowed_nets(case, policy='any_conserving'):
    people = case['people']
    options = [{person: 0 for person in people}]
    for expense in case['expenses']:
        payer, amount, beneficiaries = expense['payer'], expense['amount_cents'], expense['beneficiaries']
        if not beneficiaries or len(set(beneficiaries)) != len(beneficiaries): raise ValueError('Fixture beneficiary definition invalid')
        quotient, remainder = divmod(amount, len(beneficiaries))
        if policy == 'any_conserving': extras = list(combinations(beneficiaries, remainder))
        else:
            order = sorted(beneficiaries) if policy == 'sorted_names' else list(beneficiaries)
            if policy == 'payer_first' and payer in order: order = [payer] + [p for p in order if p != payer]
            if policy not in ('payer_first', 'sorted_names', 'beneficiary_order'): raise ValueError('Unverified remainder policy')
            extras = [tuple(order[:remainder])]
        expanded = []
        for previous in options:
            for extra in extras:
                net = dict(previous); net[payer] += amount
                for person in beneficiaries: net[person] -= quotient + (person in extra)
                expanded.append(net)
        options = expanded
        if len(options) > 1024: raise ValueError('Independent remainder oracle bound exceeded')
    return options


def minimum_transfers(net):
    balances = [value for value in net.values() if value]
    if len(balances) > 12 or sum(balances) != 0: raise ValueError('Independent minimum-transfer oracle scope exceeded')
    n = len(balances)
    totals = [0] * (1 << n)
    for mask in range(1, 1 << n):
        bit = mask & -mask
        totals[mask] = totals[mask ^ bit] + balances[bit.bit_length() - 1]

    @lru_cache(None)
    def groups(mask):
        if not mask: return 0
        anchor, best, subset = mask & -mask, -100, mask
        while subset:
            if subset & anchor and totals[subset] == 0: best = max(best, 1 + groups(mask ^ subset))
            subset = (subset - 1) & mask
        return best
    return n - groups((1 << n) - 1)


def validate_case(case, response, policy='any_conserving'):
    people = case['people']; actual = {person: 0 for person in people}
    if isinstance(response, dict):
        if 'error' in response: return {'well_formed': False, 'error': 'Program reported an exception'}
        transfers = response.get('transfers')
        reported = response.get('reported_net', response.get('net_cents'))
    else: transfers, reported = response, None
    if not isinstance(transfers, list) or len(transfers) > 10000: return {'well_formed': False, 'error': 'Interface did not return a transfers list'}
    positive = 0
    try:
        for transfer in transfers:
            if not isinstance(transfer, (list, tuple)) or len(transfer) != 3: raise ValueError('Transfer must contain sender, recipient and cents')
            sender, recipient, amount = transfer
            amount = _cent(amount)
            if sender not in actual or recipient not in actual or amount < 0 or (sender == recipient and amount > 0): raise ValueError('Invalid participant, negative amount or positive self-transfer')
            actual[sender] -= amount; actual[recipient] += amount
            positive += amount > 0
        expected = allowed_nets(case, policy)
        settled = any(actual == net for net in expected)
        reported_ok = None if reported is None else isinstance(reported, dict) and {person: _cent(reported.get(person, 0)) for person in people} == actual and not (set(reported) - set(people))
        optimum = minimum_transfers(actual) if settled else None
        return {'well_formed': True, 'settled': settled, 'net_cents': actual, 'accepted_net_options': expected,
                'positive_transfers': positive, 'minimum_positive_transfers': optimum, 'optimal': settled and positive == optimum,
                'reported_net_consistent': reported_ok, 'remainder_policy': policy}
    except (ValueError, TypeError, KeyError) as exc:
        return {'well_formed': False, 'error': str(exc)}


def infer_public_interface(code):
    """Determine one explicitly public syntax contract, without executing it."""
    try: tree=ast.parse(code)
    except (SyntaxError,ValueError,RecursionError):return None
    definitions=[node for node in tree.body if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name=='settle']
    candidates=[]
    if len(definitions)==1:
        node=definitions[0]
        args=node.args
        valid=isinstance(node,ast.FunctionDef) and not node.decorator_list and not args.vararg and not args.kwarg and not args.kwonlyargs and [a.arg for a in args.posonlyargs+args.args]==['people','expenses']
        shadow=False
        for other in tree.body:
            if other is node:continue
            for child in ast.walk(other):
                if isinstance(child,ast.Name) and child.id=='settle' and isinstance(child.ctx,ast.Store):shadow=True
                if isinstance(child,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and child.name=='settle':shadow=True
                if isinstance(child,ast.alias) and (child.asname or child.name.split('.')[0])=='settle':shadow=True
        if valid and not shadow:candidates.append({'mode':'function','name':'settle','arguments':'people_expenses',
            'inference_basis':'unique_unshadowed_top_level_public_settle_people_expenses_signature'})
    documentation=ast.get_docstring(tree) or ''
    if re.search(r'(?im)^\s*(?:TokenClock\s+H01\s+interface:\s*stdin_json(?:/v1)?|H01\s+stdin_json\s+v1)\s*$',documentation):
        candidates.append({'mode':'stdin_json','inference_basis':'explicit_module_docstring_public_stdin_json_contract'})
    ledger = infer_ledger(code)
    if ledger is not None:
        if definitions: return None  # Never choose between two declared public entry styles.
        candidates.append(ledger)
    return candidates[0] if len(candidates)==1 else None


def _adapter(interface):
    mode = interface['mode']
    common = '''import json, sys, io, runpy, contextlib
from decimal import Decimal
cases = json.load(open('cases.json'))['cases']
rows = []
'''
    if mode != 'stdin_json': common += 'import submission as module\n'
    if mode == 'function':
        name = interface.get('name', 'settle')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}', name): raise ValueError('Invalid configured callable name')
        common += 'candidate = getattr(module, ' + repr(name) + ', None)\nif not callable(candidate):\n print(json.dumps({\"interface_error\": \"configured_function_not_found\"}))\n sys.exit(0)\n'
    common += 'for case in cases:\n try:\n'
    if mode == 'function':
        name = interface.get('name', 'settle')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}', name): raise ValueError('Invalid configured callable name')
        arguments = interface.get('arguments', 'people_expenses')
        expressions = {'people_expenses': "case['people'], case['expenses']", 'expenses_people': "case['expenses'], case['people']", 'payload': "{'people':case['people'],'expenses':case['expenses']}"}
        if arguments not in expressions: raise ValueError('Unsupported interface argument mapping')
        common += '  value = getattr(module, ' + repr(name) + ')(' + expressions[arguments] + ')\n'
        common += "  row = value if isinstance(value, dict) else {'transfers': value}\n"
    elif mode == 'stdin_json':
        common += '''  capture = io.StringIO()
  sys.stdin = io.StringIO(json.dumps({'people':case['people'],'expenses':case['expenses']}))
  sys.argv = ['submission.py']
  with contextlib.redirect_stdout(capture):
   try: runpy.run_path('submission.py',run_name='__main__')
   except SystemExit as exc:
    if exc.code not in (None,0): raise
  value = json.loads(capture.getvalue())
  row = value if isinstance(value, dict) else {'transfers':value}
'''
    elif mode == 'ledger_people':
        common += '''  ledger = module.Ledger(case['people'])
  for expense in case['expenses']:
   ledger.add_expense(expense['payer'],f"{expense['amount_cents']//100}.{expense['amount_cents']%100:02d}",expense['beneficiaries'])
  value = ledger.settle()
  row = {'transfers':[[t.from_,t.to,t.cents] for t in value], 'reported_net':ledger.balances_cents()}
'''
    elif mode == 'expense_settler':
        common += '''  ledger = module.ExpenseSettler()
  for expense in case['expenses']:
   ledger.add_expense(expense['payer'],expense['beneficiaries'],f"{expense['amount_cents']//100}.{expense['amount_cents']%100:02d}")
  value = ledger.settle()
  row = {'transfers':[[t['from'],t['to'],t['cents']] for t in value], 'reported_net':ledger.balances()}
'''
    elif mode == 'ledger_add':
        common += '''  ledger = module.Ledger()
  for expense in case['expenses']:
   ledger.add(expense['payer'],expense['beneficiaries'],f"{expense['amount_cents']//100}.{expense['amount_cents']%100:02d}")
  row = {'transfers':ledger.settle(), 'reported_net':ledger.balances()}
'''
    elif mode == 'expense_dataclass':
        common += '''  expenses = [module.Expense(payer=e['payer'],beneficiaries=e['beneficiaries'],amount=f"{e['amount_cents']//100}.{e['amount_cents']%100:02d}") for e in case['expenses']]
  value = module.settle_expenses(expenses)
  row = {'transfers':[[t.payer,t.payee,str(t.amount*100)] for t in value], 'reported_net':module.calculate_balances(expenses)}
'''
    elif mode == 'public_ledger':
        common += ledger_adapter(interface)
    else: raise ValueError('Unsupported interface mapping')
    common += "  row['id'] = case['id']\n  rows.append(row)\n except Exception as exc:\n  rows.append({'id':case['id'],'error':type(exc).__name__})\nprint(json.dumps(rows,ensure_ascii=False))\n"
    return common


def evaluate(source_path, output_dir, config=None, cancelled=None, progress=None):
    config = config or {}; source_path, output_dir = Path(source_path), Path(output_dir)
    if config.get('source_kind', 'real_artifact') not in ('real_artifact', 'controlled_variant', 'synthetic_fixture'): raise ValueError('Invalid artifact origin kind')
    if source_path.stat().st_size > 4 * 1024 * 1024: raise ValueError('Artifact exceeds 4 MiB source limit')
    raw = source_path.read_bytes()
    if len(raw) > 4 * 1024 * 1024: raise ValueError('Artifact exceeds 4 MiB source limit')
    sha = hashlib.sha256(raw).hexdigest()
    result = {'schema': 'tokenclock-task-result/v1', 'task_id': 'H01', 'status': 'limited', 'checks': [],
              'source': {'sha256': sha, 'kind': config.get('source_kind', 'real_artifact'), 'label_source': 'selected_file_not_backend_identity'},
              'execution': {'actor': 'evaluator', 'network_calls': 0, 'target_model_calls': 0}, 'artifacts': [],
              'limitations': ['Fixed settlement cases are not a proof of general program correctness or model identity.',
                              'Net and transfer-count checks share a case; scoring must respect their correlation groups.']}
    if output_dir.exists() and any(output_dir.iterdir()): raise ValueError('Refusing to replace existing evaluation evidence')
    output_dir.mkdir(parents=True, exist_ok=True); output_dir.chmod(0o700)
    try:
        code, selection = select_python(raw.decode('utf-8'))
        result['source']['program_selection'] = selection
    except (UnicodeError, ValueError):
        result['limitations'].append('A unique UTF-8 Python artifact could not be selected.')
        result['checks'].append({'id': 'interface.selection', 'status': 'unknown', 'mandatory': True,
                                'dimension': '能力与交付', 'group': 'H01-interface', 'evidence': [],
                                'reason': 'A unique original program cannot be selected without executing alternatives.'})
        _save(output_dir / 'result.json', result); return result
    code_hash = hashlib.sha256(code.encode()).hexdigest()
    result['source']['program_sha256'] = code_hash
    annotations = _load(RESOURCES / 'h01_adapters.json')['adapters']
    interface = config.get('interface')
    if interface is None:
        interface = annotations.get(code_hash)
        if interface is not None:
            result['source']['interface_mapping'] = 'previous_nonblind_annotation_bound_to_program_sha256'
        else:
            interface=infer_public_interface(code)
            if interface is not None:
                result['source']['interface_mapping']='statically_identified_public_contract_not_behavior_verification'
                result['source']['interface_inference_basis']=interface['inference_basis']
                if interface.get('evidence'):
                    _save(output_dir / 'interface-evidence.json', interface)
                    result['source']['interface_evidence_path'] = str(output_dir / 'interface-evidence.json')
    elif not isinstance(interface, dict) or interface.get('mode') not in ('function', 'stdin_json'):
        raise ValueError('New interfaces must select function or stdin_json; historical mappings require a known program hash')
    if interface is None:
        result['checks'].append({'id': 'interface.mapping', 'status': 'unknown', 'mandatory': True, 'observed': 'unmapped_program',
                                 'dimension': '能力与交付', 'group': 'H01-interface', 'evidence': [],
                                 'reason': 'Select the public function/stdin interface, or provide a recognized unchanged historical artifact.'})
        result['limitations'].append('Unknown interface is not a failed algorithm; no candidate code was executed.')
        _save(output_dir / 'result.json', result); return result
    policy = interface.get('remainder_policy', 'any_conserving')
    if interface.get('mode') in ('function', 'stdin_json') and policy not in ('any_conserving', 'payer_first', 'beneficiary_order', 'sorted_names'):
        raise ValueError('Unsupported remainder contract')
    scratch = Path(tempfile.mkdtemp(prefix='workspace-', dir=output_dir)); scratch.chmod(0o700)
    (scratch / 'submission.py').write_text(code); (scratch / 'submission.py').chmod(0o600)
    (scratch / 'adapter.py').write_text(_adapter(interface)); (scratch / 'adapter.py').chmod(0o600)
    cases = _load(RESOURCES / 'h01_cases.json')
    _save(scratch / 'cases.json', cases)
    if progress: progress({'stage': 'h01_execution', 'message': '在隔离环境运行程序并提取清偿方案'})
    execution = run_isolated(scratch, 'adapter.py', config.get('limits'), cancelled)
    _save(output_dir / 'execution.json', execution)
    result['execution'].update(execution)
    result['execution']['actor'] = 'evaluator'
    result['artifacts'] = [{'path': str(output_dir / 'execution.json'), 'media_type': 'application/json', 'purpose': 'isolated_execution_receipt'},
                           {'path': str(scratch / 'submission.py'), 'media_type': 'text/x-python', 'purpose': 'unchanged_program_copy'},
                           {'path': str(scratch / 'adapter.py'), 'media_type': 'text/x-python', 'purpose': 'explicit_interface_adapter'}]
    if execution['status'] != 'completed':
        result['status'] = execution['status']
        result['checks'].append({'id': 'execution.completed', 'status': 'unknown' if execution['status'] in ('unsupported', 'limited', 'cancelled') else 'fail',
                                'mandatory': True, 'observed': execution.get('termination_reason') or execution.get('returncode'),
                                'dimension': '能力与交付', 'group': 'H01-execution', 'evidence': [{'path': str(output_dir / 'execution.json')}],
                                'reason': 'Only completed isolated output can be assessed; a limit is not an algorithmic-capability conclusion.'})
        _save(output_dir / 'result.json', result); return result
    try:
        outputs = json.loads(execution['stdout'])
        if not isinstance(outputs, list) or len(outputs) != len(cases['cases']): raise ValueError('Unexpected result row count')
        ids = [row.get('id') for row in outputs if isinstance(row, dict)]
        if len(set(ids)) != len(cases['cases']): raise ValueError('Duplicate or missing result rows')
    except (ValueError, TypeError, RecursionError):
        result['status'] = 'limited'
        result['limitations'].append('Isolated output did not match the selected interface; automatic settlement checks remain unknown.')
        result['checks'].append({'id': 'interface.output', 'status': 'unknown', 'observed': 'unexpected_output', 'mandatory': True,
                                 'dimension': '能力与交付', 'group': 'H01-interface', 'evidence': [{'path': str(output_dir / 'execution.json')} ]})
        _save(output_dir / 'result.json', result); return result
    rows = []
    for case in cases['cases']:
        output = next((row for row in outputs if row.get('id') == case['id']), {'error': 'Missing case'})
        checked = validate_case(case, output, policy); rows.append({'id': case['id'], **checked})
        evidence = [{'path': str(output_dir / 'validation.json'), 'pointer': '/cases/' + str(len(rows) - 1)}]
        checks = [('transfers_well_formed', checked['well_formed'], True, 'format'),
                  ('net_settled', checked.get('settled'), True, 'settlement'),
                  ('minimum_transfers', checked.get('optimal') if checked.get('settled') else None, True, 'settlement'),
                  ('reported_net_consistent', checked.get('reported_net_consistent'), False, 'settlement')]
        for name, value, mandatory, group in checks:
            result['checks'].append({'id': case['id'] + '.' + name, 'status': 'unknown' if value is None and mandatory else 'not_applicable' if value is None else 'pass' if value else 'fail',
                                     'mandatory': mandatory, 'observed': checked, 'dimension': '能力与交付', 'group': 'H01-' + case['id'] + '-' + group, 'evidence': evidence})
    _save(output_dir / 'validation.json', {'cases': rows, 'oracle': 'independent_integer_accounting_and_zero_sum_partition', 'candidate_reported_scores_used': False})
    result['artifacts'].append({'path': str(output_dir / 'validation.json'), 'media_type': 'application/json', 'purpose': 'independent_case_checks'})
    result['status'] = 'failed' if any(check['status'] == 'fail' for check in result['checks']) else 'limited' if any(check['mandatory'] and check['status'] == 'unknown' for check in result['checks']) else 'completed'
    _save(output_dir / 'result.json', result)
    if progress: progress({'stage': 'h01_completed', 'message': '结算净额、清偿与最少转账已分别核验', 'status': result['status']})
    return result
