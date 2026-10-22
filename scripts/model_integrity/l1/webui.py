"""Authenticated loopback-only UI. No transcript instructions are executed."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import threading
from urllib.parse import urlsplit, parse_qs
import uuid

MAX_BODY_BYTES=90*1024*1024
MAX_UPLOAD_BYTES=64*1024*1024
STATIC=Path(__file__).parent/'web'
REPORT_FILES={'report.html':'text/html; charset=utf-8','report.json':'application/json; charset=utf-8','observation.json':'application/json; charset=utf-8','evidence.zip':'application/zip'}


def default_state_dir():
    if os.name=='nt':return Path(os.environ.get('LOCALAPPDATA',str(Path.home()/'AppData/Local')))/'TokenClock'/'ModelIntegrity'
    if os.uname().sysname=='Darwin':return Path.home()/'Library/Application Support/TokenClock/ModelIntegrity'
    return Path(os.environ.get('XDG_STATE_HOME',str(Path.home()/'.local/state')))/'tokenclock'/'model-integrity'


class LocalServer(ThreadingHTTPServer):
    daemon_threads=True
    allow_reuse_address=False

    def server_close(self):
        super().server_close()
        if getattr(self,'owns_manager',False):self.manager.close(wait=True,timeout=5)


def create_server(state_dir=None,host='127.0.0.1',port=0,manager=None):
    if host!='127.0.0.1':raise ValueError('L1界面仅允许绑定127.0.0.1')
    from .jobs import JobManager
    state=Path(state_dir or default_state_dir()).expanduser().resolve()
    state.mkdir(parents=True,exist_ok=True,mode=0o700);state.chmod(0o700)
    server=LocalServer((host,port),Handler)
    server.state_dir=state
    server.token=secrets.token_urlsafe(32)
    server.prefix='/s/'+server.token+'/'
    server.base_url=f'http://127.0.0.1:{server.server_port}'+server.prefix
    server.origin=f'http://127.0.0.1:{server.server_port}'
    server.owns_manager=manager is None
    server.manager=manager or JobManager(state/'jobs')
    from .connections import ConnectionStore
    server.connections=ConnectionStore(state/'connections')
    return server


class Handler(BaseHTTPRequestHandler):
    server_version='TokenClockLocal/2'

    def log_message(self,*args):pass  # URL token, paths and keys never enter access logs.

    def _headers(self,status,content_type,length,download=None):
        self.send_response(status)
        self.send_header('Content-Type',content_type)
        self.send_header('Content-Length',str(length))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src data:; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'")
        if download:self.send_header('Content-Disposition',f'attachment; filename="{download}"')
        self.end_headers()

    def _send(self,body,status=200,ctype='application/json; charset=utf-8',download=None):
        if not isinstance(body,bytes):body=json.dumps(body,ensure_ascii=False,allow_nan=False).encode()
        self._headers(status,ctype,len(body),download)
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass

    def _route(self):
        self.connection.settimeout(20)
        expected=f'127.0.0.1:{self.server.server_port}'
        if self.headers.get('Host')!=expected:
            self._send({'error':'无效的本地主机'},403);return None
        origin=self.headers.get('Origin')
        if origin and origin!=self.server.origin:
            self._send({'error':'不接受其他网页发起的请求'},403);return None
        if self.headers.get('Sec-Fetch-Site')=='cross-site':
            self._send({'error':'不接受跨站请求'},403);return None
        parsed=urlsplit(self.path)
        if parsed.netloc:
            self._send({'error':'不接受代理形式的请求地址'},403);return None
        if not parsed.path.startswith(self.server.prefix):
            self._send({'error':'缺少本地会话凭据'},403);return None
        return parsed.path[len(self.server.prefix):],parse_qs(parsed.query)

    def do_GET(self):
        routed=self._route()
        if routed is None:return
        route,query=routed
        try:
            if route in {'','index.html','app.js','style.css'}:
                name='index.html' if route in {'','index.html'} else route
                ctype={'index.html':'text/html; charset=utf-8','app.js':'text/javascript; charset=utf-8','style.css':'text/css; charset=utf-8'}[name]
                from importlib.resources import files
                self._send(files('scripts.model_integrity.l1').joinpath('web/'+name).read_bytes(),ctype=ctype);return
            if route=='api/sessions':
                from .catalog import discover_sessions
                self._send(discover_sessions(limit=100));return
            if route=='api/jobs':
                self._send({'jobs':self.server.manager.list(limit=100)});return
            if route=='api/probes':
                from ..probes.catalog import catalog
                self._send(catalog());return
            if route=='api/info':
                from .capabilities import capabilities
                from ..probes.reference_release import overview
                self._send({'version':'model-detect-simple-ui-v1','mode_default':'local','max_upload_bytes':MAX_UPLOAD_BYTES,
                            'external_default':False,'api_key_in_profile_json':False,'capabilities':capabilities(),'references':overview()});return
            if route=='api/connections':
                self._send(self.server.connections.list());return
            if route.startswith('support/'):
                from .capabilities import support_summary
                job=self.server.manager.get(route.split('/')[-1])
                self._send(support_summary(job),download='model-detect-support.json');return
            if route.startswith('partial-evidence/'):
                jobid=route.split('/')[-1]
                archive=self.server.manager.partial_evidence_path(jobid)
                self._send(archive.read_bytes(),ctype='application/zip',download='partial-evidence.zip');return
            if route.startswith('api/jobs/'):
                jobid=route[len('api/jobs/'):]
                if '/' in jobid:raise ValueError('无效任务ID')
                self._send(self.server.manager.get(jobid));return
            if route.startswith('reports/'):
                parts=route.split('/')
                if len(parts)!=3 or parts[2] not in REPORT_FILES:raise ValueError('无效报告路径')
                folder=self.server.manager.report_path(parts[1])
                if folder is None:raise ValueError('任务尚未完成，没有可下载报告')
                report=Path(folder)/parts[2]
                if report.is_symlink():raise ValueError('报告路径无效')
                if parts[2]=='report.json' and query.get('download')!=['1']:
                    # Derive the current compact presentation in memory only.
                    # Downloaded originals and frozen evidence remain byte-identical.
                    value=json.loads(report.read_bytes())
                    from ..probes.user_summary import summarize
                    from ..probes.result_brief import build_brief
                    previous=value.get('user_summary') if isinstance(value.get('user_summary'),dict) else {}
                    value['user_summary']=summarize(value)
                    if isinstance(previous.get('recommendation'),dict):value['user_summary']['recommendation']=previous['recommendation']
                    if hasattr(self.server.manager,'recommendation_for_display'):
                        fresh=self.server.manager.recommendation_for_display(parts[1])
                        if fresh is not None:value['user_summary']['recommendation']=fresh
                    value['user_summary']['brief']=build_brief(value)
                    value['presentation']={'version':'single-result-v1','derived_for_display':True,'stored_report_modified':False}
                    self._send(value);return
                self._send(report.read_bytes(),ctype=REPORT_FILES[parts[2]],download=parts[2] if parts[2]=='evidence.zip' or query.get('download')==['1'] else None);return
            self._send({'error':'入口不存在'},404)
        except (ValueError,KeyError,FileNotFoundError,PermissionError) as exc:
            self._send({'error':str(exc)},400)

    def _body(self):
        if self.headers.get('Content-Type','').split(';')[0]!='application/json':raise ValueError('请求必须为JSON')
        try:length=int(self.headers.get('Content-Length','0'))
        except ValueError:raise ValueError('无效请求长度')
        if length<1 or length>MAX_BODY_BYTES:raise ValueError('请求为空或超出大小上限')
        raw=self.rfile.read(length)
        if len(raw)!=length:raise ValueError('请求内容未完整到达')
        from .ingest import strict_loads
        body=strict_loads(raw.decode('utf-8'))
        if not isinstance(body,dict):raise ValueError('请求主体应为对象')
        return body

    def do_POST(self):
        routed=self._route()
        if routed is None:return
        route,_=routed
        try:
            body=self._body()
            if route=='api/history/compare':
                from ..probes.history_comparison import compare_history
                from .ingest import strict_loads
                reports=[];jobs=[]
                for key in ('left_job_id','right_job_id'):
                    identifier=body.get(key)
                    if not isinstance(identifier,str):raise ValueError('请选择两份已完成的结果')
                    job=self.server.manager.get(identifier)
                    path=Path(self.server.manager.report_path(identifier))/'report.json'
                    if path.is_symlink() or path.stat().st_size>32*1024*1024:raise ValueError('报告文件无法安全读取')
                    report=strict_loads(path.read_bytes())
                    if not isinstance(report,dict):raise ValueError('报告格式不完整')
                    reports.append(report);jobs.append(job)
                comparison=compare_history(*reports)
                for key,job in zip(('left','right'),jobs):
                    comparison[key].update(job_id=job['id'],input_name=job.get('input_name'),created_at=job.get('created_at'))
                self._send(comparison);return
            if route=='api/model-catalog':
                from .model_catalog import fetch_catalog
                self._send(fetch_catalog(body.get('endpoint')));return
            if route=='api/preview':
                from .preview import preview
                config=body.get('semantic_config') or {'mode':'local'}
                if not isinstance(config,dict):raise ValueError('检测配置无效')
                config=self.server.connections.resolve(config,preview=True)
                source=body.get('source_path')
                if body.get('resume_job_id'):
                    source,config=self.server.manager.preview_resume(body['resume_job_id'],config)
                follow_up=None
                if body.get('recommendation_origin_job_id') or body.get('recommendation_action_id'):
                    origin=body.get('recommendation_origin_job_id');action=body.get('recommendation_action_id')
                    if not isinstance(origin,str) or not isinstance(action,str):raise ValueError('补测来源不完整')
                    follow_up=self.server.manager.preview_recommendation(origin,action,config)
                result=preview(config,source)
                if follow_up:result['follow_up']={key:follow_up.get(key) for key in ('title','reason','purpose','request_count','estimated_reserve_usd')}
                if body.get('resume_job_id'):
                    result['resume_job_id']=body['resume_job_id']
                    job=self.server.manager.get(body['resume_job_id'])
                    for role in result['roles']:
                        key=('probe_budget_cap_usd' if role['role']=='target' else 'semantic_budget_cap_usd' if config.get('workflow_mode','l1')=='l1' else 'assessment_budget_cap_usd')
                        role['original_budget_usd']=job.get(key)
                    result['warnings'].append('重试使用原固定输入；已发生的费用保留，预览预算已扣除旧费用。不会退回费用或自动增加额度。')
                self._send(result);return
            if route=='api/connections':
                self._send(self.server.connections.save(body),201);return
            if route=='api/connections/delete':
                self._send(self.server.connections.delete(body.get('id')));return
            if route=='api/upload':
                name=body.get('name','session.jsonl');content=body.get('content')
                if not isinstance(name,str) or not isinstance(content,str):raise ValueError('缺少会话文件内容')
                raw=content.encode('utf-8')
                if not raw or len(raw)>MAX_UPLOAD_BYTES:raise ValueError('文件为空或超过64 MiB')
                suffix=Path(name).suffix.lower()
                if suffix not in {'.json','.jsonl','.py','.html','.svg','.txt'}:raise ValueError('支持JSON/JSONL、Python、HTML、SVG或纯文本文件')
                uploads=self.server.state_dir/'uploads';uploads.mkdir(exist_ok=True,mode=0o700);uploads.chmod(0o700)
                path=uploads/(uuid.uuid4().hex+suffix)
                fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                with os.fdopen(fd,'wb') as stream:stream.write(raw)
                self._send({'path':str(path),'name':Path(name).name,'bytes':len(raw)});return
            if route=='api/combine':
                ids=body.get('job_ids')
                if not isinstance(ids,list) or not 1<=len(ids)<=12 or len(ids)!=len(set(ids)):raise ValueError('请选择1–12份不同的完整报告')
                reports=[]
                for jobid in ids:
                    path=self.server.manager.report_path(jobid)/'report.json'
                    if path.is_symlink():raise ValueError('报告文件不安全')
                    from ..probes.common import load_json
                    reports.append(load_json(path))
                controls=self.server.state_dir/'controls';controls.mkdir(exist_ok=True,mode=0o700)
                source=controls/(uuid.uuid4().hex+'.json')
                from ..probes.common import write_json
                write_json(source,{'schema':'tokenclock-combined-input/v1','reports':reports})
                self._send(self.server.manager.submit(str(source),semantic_config={'workflow_mode':'combined'}),202);return
            if route=='api/jobs':
                source=body.get('source_path')
                if source is not None and not isinstance(source,str):raise ValueError('文件路径无效')
                semantic=body.get('semantic_config') or {'mode':'local'}
                if not isinstance(semantic,dict):raise ValueError('评估配置无效')
                semantic=self.server.connections.resolve(semantic)
                from ..probes.workflow import validate_config
                semantic=validate_config(semantic)
                if (semantic.get('transport_mode')=='live' or (semantic.get('assessment',{}).get('enabled') and semantic.get('assessment',{}).get('transport_mode')=='live')) and body.get('allow_external') is not True:raise ValueError('真实探针调用需要明确同意本次外发和预算')
                if not source:
                    if semantic.get('workflow_mode') not in {'l2','l3'} or semantic.get('transport_mode') not in {'live','demo'}:raise ValueError('请选择输入文件')
                    controls=self.server.state_dir/'controls';controls.mkdir(exist_ok=True,mode=0o700)
                    source=str(controls/(uuid.uuid4().hex+'.json'))
                    from ..probes.common import write_json
                    write_json(source,{'schema':'tokenclock-probe-control/v1','note':'Task is selected only by runtime configuration.'})
                external=semantic.get('external') or {}
                if not isinstance(external,dict):raise ValueError('外部语义配置无效')
                if external.get('enabled') is True and body.get('allow_external') is not True:
                    raise ValueError('外部语义增强需要你明确同意发送所选文本片段')
                result=self.server.manager.submit(source,comparison_model=body.get('comparison_model') or None,semantic_config=semantic,input_name=body.get('input_name'),
                    recommendation_origin_job_id=body.get('recommendation_origin_job_id'),recommendation_action_id=body.get('recommendation_action_id'))
                self._send(result,202);return
            parts=route.split('/')
            if len(parts)==4 and parts[:2]==['api','jobs']:
                if parts[3]=='cancel':self._send(self.server.manager.cancel(parts[2]));return
                if parts[3]=='resume':
                    if body.get('semantic_config'):
                        semantic=body['semantic_config']
                        if not isinstance(semantic,dict) or not isinstance(semantic.get('external',{}),dict):raise ValueError('语义配置无效')
                        semantic=self.server.connections.resolve(semantic)
                        if semantic.get('external',{}).get('enabled') and body.get('allow_external') is not True:
                            raise ValueError('恢复外部分析需要重新确认发送范围')
                        self._send(self.server.manager.resume(parts[2],semantic_config=semantic,allow_external=body.get('allow_external') is True));return
                    self._send(self.server.manager.resume(parts[2]));return
            self._send({'error':'入口不存在'},404)
        except (ValueError,KeyError,OSError,TypeError) as exc:
            from .render import redact
            self._send({'error':redact(str(exc))},400)


def serve(state_dir=None,port=0,open_browser=False):
    server=create_server(state_dir,port=port)
    print(json.dumps({'event':'ready','url':server.base_url,'pid':os.getpid()},ensure_ascii=False),flush=True)
    if open_browser:
        import webbrowser
        webbrowser.open(server.base_url)
    try:server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:pass
    finally:server.server_close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--state-dir');parser.add_argument('--port',type=int,default=0)
    parser.add_argument('--open',action='store_true');args=parser.parse_args()
    serve(args.state_dir,args.port,args.open)
