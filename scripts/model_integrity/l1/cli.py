"""Offline L1 internal command line: import one source and write a private report."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from .engine import analyze
from .ingest import load_observation
from .render import redact, render_report

MAX_MIB = 256
OUTPUT_FILES = ('observation.json', 'report.json', 'report.html')


def _mib(value: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError('max-mib 必须是整数') from exc
    if not 1 <= result <= MAX_MIB:
        raise argparse.ArgumentTypeError(f'max-mib 必须在 1–{MAX_MIB} 之间')
    return result


def _json_bytes(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')


def write_bundle(output: Path, observation: dict, report: dict, html: str) -> None:
    """Reserve a NEW directory exclusively; never overwrite an input or old bundle.

    Prepare all content before mkdir. If a write fails, remove only files created
    by this invocation and remove its empty directory; existing paths are never
    removed. No input or report-supplied path is traversed here.
    """
    payloads = (_json_bytes(observation), _json_bytes(report), html.encode('utf-8'))
    output = Path(output).expanduser().absolute()
    # os.mkdir rejects even an existing empty directory or a dangling symlink.
    os.mkdir(output, mode=0o700)
    created = []
    try:
        os.chmod(output, 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
        for name, body in zip(OUTPUT_FILES, payloads):
            path = output / name
            fd = os.open(path, flags, 0o600)
            created.append(path)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(path, 0o600)
    except BaseException:
        for path in created:
            try:
                path.unlink()
            except OSError:
                pass
        try:
            output.rmdir()
        except OSError:
            pass
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description='TokenClock：已有会话、轻量探针与重型交付评估工作台')
    subcommands = result.add_subparsers(dest='command', required=True)
    command = subcommands.add_parser('analyze', help='分析一个已有会话或 observation 文档')
    command.add_argument('input', type=Path)
    command.add_argument('--format', choices=('auto', 'codex', 'claude-code', 'observation'), default='auto')
    command.add_argument('--comparison-model', help='仅作为当前比较目标，不改变历史请求声明')
    command.add_argument('--output-dir', required=True, type=Path, help='必须是尚不存在的新目录；父目录须已存在')
    command.add_argument('--max-mib', type=_mib, default=64, help='输入上限 MiB，默认 64，最大 256')
    command.add_argument('--basic-only', action='store_true', help='仅运行兼容alpha的确定性观察器')
    command.add_argument('--semantic-config', type=Path, help='显式选择语义配置JSON；不会自动查找研究密钥')
    command.add_argument('--allow-external', action='store_true', help='同意按显式配置发送有界文本片段')
    probe=subcommands.add_parser('probe',help='运行L2/L3、服务检查或综合观察；默认不调用模型')
    probe.add_argument('input',type=Path,nargs='?')
    probe.add_argument('--config',required=True,type=Path)
    probe.add_argument('--output-dir',required=True,type=Path)
    probe.add_argument('--allow-live',action='store_true',help='同意本配置中的任务、外发接口及费用上限')
    server = subcommands.add_parser('serve', help='打开本机模型评估工作台')
    server.add_argument('--state-dir', type=Path)
    server.add_argument('--port', type=int, default=0)
    server.add_argument('--open', action='store_true', help='启动后打开浏览器')
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == 'serve':
        from .webui import serve
        try:
            serve(args.state_dir,args.port,args.open)
            return 0
        except (OSError,ValueError) as exc:
            print('无法启动会话评估：'+redact(str(exc)),file=sys.stderr)
            return 2
    if args.command=='probe':
        try:
            from ..probes.workflow import run_analysis,validate_config
            from ..probes.common import load_json
            import tempfile
            config=load_json(args.config)
            if config.get('workflow_mode') not in {'l2','l3','diagnostics','combined'}:raise ValueError('probe需要明确的评估流程')
            if (config.get('transport_mode')=='live' or (config.get('assessment',{}).get('enabled') and config.get('assessment',{}).get('transport_mode')=='live')) and not args.allow_live:raise ValueError('真实调用需要 --allow-live；尚未外发')
            if args.allow_live:
                config['allow_live']=True
                if config.get('assessment',{}).get('enabled'):config['assessment']['allow_live']=True
            config=validate_config(config)
            with tempfile.TemporaryDirectory(prefix='tc-probe-control-') as td:
                source=args.input
                if source is None:
                    if config.get('transport_mode') not in {'live','demo'}:raise ValueError('此模式需要输入文件')
                    source=Path(td)/'control.json';source.write_text('{}')
                report=run_analysis(source,semantic_config=config,output_dir=args.output_dir)
            print(json.dumps({'output_directory':str(args.output_dir),'summary':report['summary']},ensure_ascii=False));return 0
        except (OSError,ValueError,TypeError,KeyError) as exc:
            print('未完成评估：'+redact(str(exc)),file=sys.stderr);return 2
    output = args.output_dir.expanduser().absolute()
    try:
        if os.path.lexists(output):
            raise FileExistsError('输出目录已存在；请使用新目录，本工具不会覆盖旧报告或原件')
        if not output.parent.is_dir():
            raise ValueError('输出目录的父目录不存在；请先选择已有父目录')
        if args.basic_only:
            doc = load_observation(args.input, format=args.format, max_bytes=args.max_mib * 1024 * 1024)
            report = analyze(doc, comparison_model=args.comparison_model)
            write_bundle(output, doc, report, render_report(report, doc))
        else:
            from .pipeline import run_analysis
            from .ingest import strict_loads
            config = strict_loads(args.semantic_config.read_text()) if args.semantic_config else {'mode':'local'}
            if not isinstance(config,dict):raise ValueError('语义配置必须为JSON对象')
            external=config.get('external') or {}
            if not isinstance(external,dict):raise ValueError('external配置必须为对象')
            if external.get('enabled') is True and not args.allow_external:
                raise ValueError('外部语义增强需要显式 --allow-external；未发送任何文本')
            config.update(input_format=args.format,max_mib=args.max_mib)
            report=run_analysis(args.input,comparison_model=args.comparison_model,semantic_config=config,output_dir=output)
    except (OSError, ValueError, TypeError, KeyError, RecursionError) as exc:
        print('未生成报告：' + redact(str(exc)), file=sys.stderr)
        return 2
    print(json.dumps({'status': '完成', 'output_directory': str(output),
                      'records': report['coverage']['records_total'],
                      'facts': len(report['facts']), 'unknowns': len(report['unknowns']),
                      'identity_status': report['summary']['identity_status'],
                      'new_model_calls': 0}, ensure_ascii=False))
    return 0
