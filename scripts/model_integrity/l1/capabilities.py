"""Local readiness and a deliberately small, opt-in support export."""
from __future__ import annotations
import platform
from pathlib import Path
import sys


def capabilities():
    from ..probes.browser_driver import runtime_paths
    paths=runtime_paths({})
    sandbox=sys.platform=='darwin' and Path('/usr/bin/sandbox-exec').is_file()
    node=bool(paths.get('node_path') and Path(paths['node_path']).is_file())
    modules=Path(paths['node_modules_path']) if paths.get('node_modules_path') else None
    browser=bool(paths.get('browser_executable') and Path(paths['browser_executable']).is_file())
    html=bool(node and browser and modules and (modules/'playwright').is_dir() and not paths.get('unavailable_reason'))
    visual=bool(html and modules and (modules/'sharp').is_dir())
    return {'platform':sys.platform,'architecture':platform.machine(),'python':platform.python_version(),
            'l1_local':True,'l2_api_and_import':True,'semantic_judge_api':True,
            'h01_h03_isolation_available':sandbox,'h02_browser_available':sandbox and html,
            'h04_svg_renderer_available':sandbox and visual,
            'runtime_source':'bundled' if paths.get('bundled') else 'host',
            'browser_unavailable_reason':paths.get('unavailable_reason'),
            'readiness_is_not_sandbox_validation':True,
            'truth_labelled_relay_accuracy_validated':False}


def support_summary(job):
    """Allowlist only. No model text, source paths, endpoints, IDs, keys, or errors."""
    cfg=job.get('semantic_config') or {}
    result={'schema':'tokenclock-model-detect-support/v1','runtime':capabilities(),
            'task':{'status':job.get('status'),'workflow_mode':cfg.get('workflow_mode','l1'),
                    'transport_mode':cfg.get('transport_mode','local')},
            'privacy':{'raw_content_included':False,'local_paths_included':False,'credentials_included':False,
                       'automatically_uploaded':False}}
    known_status={'completed','failed','cancelled','interrupted','action_required','queued','running','cancelling'}
    if result['task']['status'] not in known_status:result['task']['status']='unknown'
    for field,allowed in [('workflow_mode',{'l1','l2','l3','diagnostics','combined'}),('transport_mode',{'live','demo','replay','artifact','local'})]:
        if result['task'][field] not in allowed:result['task'][field]='unknown'
    billing=job.get('probe_billing') or job.get('semantic_billing') or {}
    result['billing']={}
    for key,value in (billing.get('totals') or {}).items():
        if key in {'reported_actual_cost_usd','estimated_only_cost_usd','pending_reserved_cost_usd','requests'} and isinstance(value,(int,float)):
            result['billing'][key]=value
    return result
