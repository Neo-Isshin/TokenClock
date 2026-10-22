"""Immutable, application-bundled reference releases. No remote update channel.

Hashes establish which files were used, not the truth of historical model labels.
Unreviewed candidate data is never loaded as an active reference.
"""
from copy import deepcopy
from functools import lru_cache
from importlib.resources import files
import hashlib,json,re
from .reference_labels import MODEL_FAMILIES

SCHEMA='tokenclock-reference-release/v1'
ASSETS={'fingerprint':'fingerprint-reference-v1.json','process':'process-reference-v1.json',
        'behavior':'behavior-reference-v1.json','catalog':'catalog.json','validation':'candidate-validation-summary-v1.json'}
MAX_BYTES=8*1024*1024
# Reviewed application data. A self-supplied manifest is not an approval.
# Future data changes require an explicit registry/code review as well as a
# matching offline validation receipt; no web payload can amend this registry.
TRUSTED_DATA={
    'fingerprint':{'652ec16ffa4b799f448d930573d0eb250348a4e9d6457a12f28a64968902874f'},
    'process':{'4e3e8b62b9d7a8017004dcd9986c82ae21f805275efd3de749e256f803f4121b'},
    'behavior':{'823b577fd3e73bed806cda78319aa584f4de13070e2baf13b8ca89ffbd016a5c'},
}


def _json(raw):
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise ValueError('Duplicate reference field')
            result[key]=value
        return result
    return json.loads(raw,object_pairs_hook=unique,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Non-finite reference value')))


def _hash(raw):return hashlib.sha256(raw).hexdigest()


def _counts(values,total):
    if not isinstance(values,dict) or any(not isinstance(k,str) or not re.fullmatch(r'[a-f0-9]{64}',k) or type(v)is not int or v<=0 for k,v in values.items()):
        raise ValueError('Reference counts invalid')
    if sum(values.values())!=total:raise ValueError('Reference counts do not match sample denominator')


def _validate_reference(ref,legacy=False):
    expected='tokenclock-l1-behavior-reference/v1' if legacy else 'tokenclock-fingerprint-reference/v1'
    known={m for models in MODEL_FAMILIES.values() for m in models}
    if not isinstance(ref,dict) or ref.get('schema')!=expected or not isinstance(ref.get('cells'),list) or not 1<=len(ref['cells'])<=10000:raise ValueError('Unsupported reference schema')
    if ref.get('identity_probability') is not None or ref.get('mixture_proportion') is not None:raise ValueError('Reference similarity must not claim identity or mixture probabilities')
    labels=ref.get('model_labels')
    if not isinstance(labels,list) or not labels or len(labels)!=len(set(labels)) or not set(labels)<=known:raise ValueError('Reference models require explicit registration')
    strata=set();ids=set()
    for cell in ref['cells']:
        if not isinstance(cell,dict):raise ValueError('Malformed reference cell')
        n=cell.get('n')
        if type(n)is not int or not 1<=n<=100000 or cell.get('model_label') not in labels:raise ValueError('Invalid reference sample count or model')
        identity={k:cell.get(k) for k in ('bank','task_id','model_label','dimension','origin','conditions','measurement_contract','sample_source')}
        key=json.dumps(identity,sort_keys=True,separators=(',',':'))
        if key in strata:raise ValueError('Duplicate reference stratum')
        strata.add(key)
        if not isinstance(cell.get('conditions'),dict):raise ValueError('Reference conditions missing')
        if not legacy:
            if cell.get('id') in ids:raise ValueError('Duplicate reference cell ID')
            ids.add(cell.get('id'))
            hashes=cell.get('sample_hashes')
            if not isinstance(hashes,list) or len(hashes)!=n or len(set(hashes))!=n or any(not re.fullmatch(r'[a-f0-9]{64}',str(h)) for h in hashes):raise ValueError('Reference sample identities invalid')
        descriptors=cell.get('features' if legacy else 'descriptors')
        if not isinstance(descriptors,dict):raise ValueError('Reference features missing')
        for descriptor in descriptors.values():
            if not isinstance(descriptor,dict):raise ValueError('Malformed reference descriptor')
            known_n=descriptor.get('observed' if legacy else 'known_n');missing=descriptor.get('missing' if legacy else 'unknown_or_missing_n')
            if type(known_n)is not int or type(missing)is not int or min(known_n,missing)<0 or known_n+missing!=n:raise ValueError('Reference missingness denominator inconsistent')
            _counts(descriptor.get('value_hash_counts' if legacy else 'counts'),known_n)


def verify_bundle(resource_root=None,legacy_root=None,*,inspect_unapproved=False):
    root=resource_root or files('scripts.model_integrity.probes').joinpath('resources')
    legacy=legacy_root or files('scripts.model_integrity.l1').joinpath('resources')
    manifest_raw=root.joinpath('reference-release-v1.json').read_bytes()
    if len(manifest_raw)>256*1024:raise ValueError('Reference manifest too large')
    manifest=_json(manifest_raw)
    if not isinstance(manifest,dict) or manifest.get('schema')!=SCHEMA or set(manifest.get('files',{}))!=set(ASSETS):raise ValueError('Reference manifest incomplete')
    if manifest.get('activation')!='application_bundle_only' or manifest.get('candidate_formal_enabled')!=[]:raise ValueError('Unreviewed candidate activation is not permitted')
    bindings=manifest.get('implementation_bindings') or {}
    if set(bindings)!={'features.py','candidate_style.py'}:raise ValueError('Reference implementation bindings missing')
    for name,expected in bindings.items():
        if _hash(files('scripts.model_integrity.probes').joinpath(name).read_bytes())!=expected:raise ValueError('Reference extractor version changed')
    data={}
    for kind,name in ASSETS.items():
        raw=(legacy if kind=='behavior' else root).joinpath(name).read_bytes();record=manifest['files'][kind]
        if len(raw)>MAX_BYTES or record.get('sha256')!=_hash(raw) or record.get('bytes')!=len(raw):raise ValueError('Reference file verification failed: '+kind)
        data[kind]=_json(raw)
    for kind in ('fingerprint','process','behavior'):_validate_reference(data[kind],legacy=kind=='behavior')
    approved=all(manifest['files'][kind]['sha256'] in allowed for kind,allowed in TRUSTED_DATA.items())
    if not approved and not inspect_unapproved:raise ValueError('Reference data is not in the reviewed application registry')
    tasks={}
    for task in data['catalog'].get('tasks',[]):
        key=task.get('id');prompt=task.get('prompt')
        if not isinstance(key,str) or key in tasks or not isinstance(prompt,str) or _hash(prompt.encode())!=task.get('prompt_sha256'):raise ValueError('Registered task prompt invalid')
        tasks[key]=task['prompt_sha256']
    if tasks!=manifest.get('task_prompts'):raise ValueError('Task prompts differ from the reviewed release')
    for cell in data['behavior']['cells']:
        if tasks.get(cell['task_id'])!=cell.get('prompt_sha256'):raise ValueError('Historical prompt does not match registered task')
    validation=data['validation']
    if validation.get('schema')!='tokenclock-candidate-validation-summary/v1' or validation.get('formal_admission')is not False or validation.get('formal_direction_use')is not False:raise ValueError('Candidate validation policy is incomplete')
    if validation.get('extractor_sha256')!=bindings['candidate_style.py']:raise ValueError('Candidate validation does not match its extractor')
    replay=manifest.get('historical_behavior_reextract') or {}
    if replay.get('exact_match')is not True:raise ValueError('Historical reference re-extraction has not been verified')
    return {'manifest':manifest,'manifest_sha256':_hash(manifest_raw),'data':data,'approved_for_runtime':approved}


@lru_cache(maxsize=1)
def _verified():
    try:return verify_bundle()
    except (ValueError,TypeError,KeyError,OSError,AttributeError) as exc:
        raise ValueError('参考资料未通过校验，请更新或修复应用后再检测。') from exc


def reference(kind='fingerprint'):
    if kind not in {'fingerprint','process','behavior'}:raise ValueError('Unknown reference kind')
    return deepcopy(_verified()['data'][kind])


def overview():
    value=_verified();manifest=value['manifest'];data=value['data'];validation=data['validation']
    from .numeric_fingerprint import overview as numeric_overview
    return {'schema':'tokenclock-reference-overview/v1','status':'verified','release_id':manifest['release_id'],
            'verified_on':manifest['verified_on'],'models':list(data['fingerprint']['model_labels']),
            'original_behavior_answers':data['fingerprint']['banks']['behavior']['original_samples'],
            'manifest_sha256':value['manifest_sha256'],'data_version':data['fingerprint']['version'],
            'title':'参考资料已校验','summary':'本次补充了校验和验证说明，研究样本未变。检测中途不会替换参考。' if manifest.get('reference_data_changed') is False else '参考随应用更新并固定版本，检测中途不会替换。',
            'update_policy':'新参考先核对文件、题目、条件和样本，再通过离线验证；旧报告保留原版本。',
            'candidate_summary':[deepcopy(r) for r in validation['user_summary'] if r.get('id')!='modeltrace-sequence-v1'],'candidate_formal_enabled':False,
            'external_numeric':numeric_overview(),'external_numeric_enabled':True,
            'identity_accuracy_validated':False,'historical_labels_authenticated':False,
            'note':'来自既有研究样本，可作表现对照，不是模型身份证明。'}


def assess_update(current,candidate):
    """Admission for an application release, not an untrusted remote importer.

    Call verify_bundle on both inputs first. The approval receipt links a reviewed
    study to exact old/new data. It does not authenticate serving model weights.
    """
    old=current['manifest'];new=candidate['manifest']
    byte_changed=[kind for kind in ('fingerprint','process','behavior') if old['files'][kind]['sha256']!=new['files'][kind]['sha256']]
    changed=[kind for kind in ('fingerprint','process','behavior') if current['data'][kind]!=candidate['data'][kind]]
    result={'schema':'tokenclock-reference-update-review/v1','data_changed':changed,'can_package':False,
            'file_bytes_changed':byte_changed,
            'old_release':old['release_id'],'new_release':new['release_id'],'old_reports_rewritten':False,
            'new_model_labels':sorted(set(candidate['data']['fingerprint']['model_labels'])-set(current['data']['fingerprint']['model_labels']))}
    if changed and old['release_id']==new['release_id']:
        result['reason']='参考数据改变时必须使用新的版本号。';return result
    if not changed:
        result.update(can_package=bool(candidate.get('approved_for_runtime')),status='metadata_only' if not byte_changed else 'equivalent_data_repack',
                      reason='只更新校验说明；参考数据未改变。' if not byte_changed else '参考内容相同，但重新打包的文件仍需登记校验值；不需伪造新的采样。');return result
    receipt=candidate['data']['validation'].get('reference_update') or {}
    if (receipt.get('base_manifest_sha256')!=current['manifest_sha256'] or
            receipt.get('candidate_files')!={k:new['files'][k]['sha256'] for k in ('fingerprint','process','behavior')}):
        result.update(status='needs_validation',reason='更新缺少与旧、新参考精确对应的验证回执。');return result
    flags=('source_hashes_verified','task_conditions_checked','heldout_review_passed','unknown_control_review_passed','independent_temporal_window')
    hashes=('protocol_sha256','evaluation_sha256','source_manifest_sha256')
    if not all(receipt.get(k)is True for k in flags) or not all(isinstance(receipt.get(k),str) and re.fullmatch(r'[a-f0-9]{64}',receipt[k]) for k in hashes):
        result.update(status='needs_validation',reason='新参考尚未通过来源、留出对照、未知型号和独立时间窗口检查。');return result
    if not candidate.get('approved_for_runtime'):
        result.update(status='requires_application_registration',reason='回执已齐备，但数据尚未进入应用的受信参考登记。');return result
    result.update(can_package=True,status='reviewed_data_update',reason='更新回执与数据一致，可随已审核的应用版本发布。')
    return result
