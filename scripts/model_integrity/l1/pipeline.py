"""Complete local L1 workflow, shared by CLI, background jobs and local UI."""
from __future__ import annotations

from pathlib import Path
import copy

from .engine import analyze
from .ingest import load_observation
from .render import render_report


class AnalysisCancelled(Exception):
    """The user cancelled before the result could be published."""


def run_analysis(source_path, comparison_model=None, semantic_config=None,
                 progress=None, cancelled=None, output_dir=None):
    notify=progress or (lambda *args,**kwargs:None)
    is_cancelled=cancelled or (lambda:False)

    def stage(name,message,fraction):
        if is_cancelled():raise AnalysisCancelled('分析已取消')
        notify(name,message,fraction)

    config=dict(semantic_config or {'mode':'local'})
    from ..probes.reference_release import reference as verified_reference,overview
    release=overview()  # Before any optional paid interpretation.
    max_mib=config.pop('max_mib',64)
    if type(max_mib) is not int or not 1<=max_mib<=256:
        raise ValueError('输入上限必须在1–256 MiB之间')
    fmt=config.pop('input_format','auto')
    stage('importing','读取并固定所选会话',0.1)
    observation=load_observation(source_path,format=fmt,max_bytes=max_mib*1024*1024)
    stage('extracting','提取来源、工具与计量事实',0.3)
    report=analyze(observation,comparison_model=comparison_model)
    stage('semantics','分析有原文依据的语义与行为',0.5)
    from .semantic import enrich
    report=enrich(observation,report,config=config,cancelled=is_cancelled,progress=notify)
    from .verification import attach_verification
    report=attach_verification(observation,report)
    from ..probes.process_reference import attach_l1
    report=attach_l1(observation,report)
    from .references import attach_reference
    reference_config={'catalog':verified_reference('behavior')}
    report=attach_reference(observation,report,reference_config)
    report['reference_release']={k:release[k] for k in ('release_id','manifest_sha256','data_version','verified_on')}
    if report.get('process_profile'):
        from ..probes.fingerprints import compare
        from ..probes.fingerprint_summary import summarize
        report['fingerprints']=compare(report)
        report['fingerprint_interpretation']=summarize(report['fingerprints'])
    # Keep the limit, but no longer claim that no semantic extraction ran.
    for item in report.get('unknowns',[]):
        if item.get('code')=='delivery.semantic_review_not_implemented':
            item['reason']='已提取有原文引用的局部语义；通用任务正确性与隐含关系仍未完整核验。'
    report.setdefault('coverage',{}).setdefault('modules',{}).update({'semantic':'cited_local_observations',
        'references':report['reference_comparison']['status'],'verification_history':'scope_bound_visible_checks'})
    stage('reporting','整理支持、限制与证据报告',0.85)
    report.setdefault('workflow',{}).update({'version':'tokenclock-l1-workflow/v2',
        'stages':['importing','extracting','semantics','reporting'],
        'comparison_target_is_runtime_choice':True,'target_probe_calls':0})
    from ..probes.user_summary import summarize as user_summary
    report['user_summary']=user_summary(report)
    from ..probes.recommendations import recommend
    report['user_summary']['recommendation']=recommend(report,{'comparison_target':comparison_model})
    from ..probes.result_brief import build_brief
    report['user_summary']['brief']=build_brief(report)
    html=render_report(report,observation)
    if output_dir is not None:
        stage('saving','保存本地报告',0.95)
        # Import lazily: CLI also invokes this pipeline.
        from .cli import write_bundle
        write_bundle(Path(output_dir),observation,report,html)
    if is_cancelled():raise AnalysisCancelled('分析已取消，未发布结果')
    notify('completed','报告已完成',1.0)
    return report
