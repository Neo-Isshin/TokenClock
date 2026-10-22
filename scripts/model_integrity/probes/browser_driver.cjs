'use strict';
const fs = require('fs'), path = require('path'), http = require('http');
const {chromium} = require('playwright');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const source = fs.readFileSync(cfg.input_path);
const out = cfg.output_dir;
let context, server, origin, stopped = false;
const result = {driver_status:'completed', actor:'evaluator', actions:[], snapshots:[], screenshots:[], blocked_requests:[], console_errors:[], checks:[]};
function write(name, value) { const p=path.join(out,name); fs.writeFileSync(p,JSON.stringify(value,null,2)+'\n',{mode:0o600}); }
function action(type, data={}) { if(result.actions.length>=cfg.limits.max_steps) throw Error('step_limit'); result.actions.push({actor:'evaluator',type,...data}); }
async function shutdown() { if(stopped)return; stopped=true; try {if(context)await context.close();}catch{} if(server)server.close(); }
process.on('SIGTERM',()=>{result.driver_status='cancelled';write('browser-result.json',result);shutdown().finally(()=>process.exit(2));});
async function launch() {
  const executable=cfg.browser_executable||[chromium.executablePath(),'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','/usr/bin/chromium','/usr/bin/google-chrome'].find(p=>fs.existsSync(p));
  context=await chromium.launchPersistentContext(cfg.profile,{headless:true,viewport:{width:1280,height:1000},
    executablePath:executable||undefined,serviceWorkers:'block',acceptDownloads:false,
    permissions:[],args:['--disable-background-networking','--disable-component-update','--disable-extensions','--disable-sync','--disable-crash-reporter','--disable-breakpad','--no-proxy-server','--no-first-run'],chromiumSandbox:false});
  await context.route('**/*',route=>{const u=new URL(route.request().url());
    if(u.origin===origin && u.pathname==='/artifact' && route.request().method()==='GET')return route.continue();
    if(result.blocked_requests.length<100)result.blocked_requests.push({scheme:u.protocol,host:u.hostname,method:route.request().method()});return route.abort('blockedbyclient');});
  if(context.routeWebSocket)await context.routeWebSocket('**/*',socket=>{result.blocked_websocket_routes=(result.blocked_websocket_routes||0)+1;socket.close();});
  await context.addInitScript(()=>{for(const key of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport']){try{Object.defineProperty(globalThis,key,{value:undefined,writable:false,configurable:false});}catch{}}});
  context.on('page',page=>attach(page));
  const page=context.pages()[0]||await context.newPage();attach(page);
  await page.goto(origin+'/artifact',{waitUntil:'domcontentloaded',timeout:10000});
  return page;
}
function attach(page){page.on('dialog',async d=>{if(result.actions.length<cfg.limits.max_steps)action('dialog',{kind:d.type(),message:d.message().slice(0,300)});await d.accept();});page.on('download',d=>d.cancel());page.on('pageerror',e=>{if(result.console_errors.length<30)result.console_errors.push(String(e).slice(0,500));});}
async function shot(page,name){const p=path.join(cfg.screenshot_dir,name+'.png');await page.screenshot({path:p,fullPage:cfg.full_page===true,timeout:5000});fs.chmodSync(p,0o600);result.screenshots.push(p);}
async function snapshot(page,label) {
  const state=await page.locator('body').evaluate(body=>{
    const controls=[...body.querySelectorAll('input,select,textarea,button,[role="button"],[role="radio"],a')].map((e,index)=>{
      const box=e.getBoundingClientRect();const visible=box.width>0&&box.height>0&&getComputedStyle(e).visibility!=='hidden';
      let label=(e.labels&&[...e.labels].map(x=>x.innerText).join(' '))||e.getAttribute('aria-label')||e.placeholder||e.innerText||'';
      const group=e.closest('[role="radiogroup"],[data-choice],.chips');
      const groupLabel=group&&(group.getAttribute('aria-label')||group.parentElement?.querySelector(':scope > label,:scope > legend')?.innerText||'');
      const isChoice=!!(group&&groupLabel&&group.querySelectorAll('button,[role="radio"]').length>=2&&group.querySelectorAll('button,[role="radio"]').length<=12&&(e.tagName==='BUTTON'||e.getAttribute('role')==='radio'));
      const associatedLabels=e.labels?[...e.labels].map(x=>[...document.querySelectorAll('label')].indexOf(x)).filter(x=>x>=0):[];
      const ancestry=[];for(let n=e;n&&n!==body;n=n.parentElement){ancestry.push(n.tagName+':'+[...n.parentElement.children].filter(s=>s.tagName===n.tagName).indexOf(n));}
      return {index,tag:e.tagName.toLowerCase(),type:e.type||'',id:e.id||'',field:e.getAttribute('data-field')||e.getAttribute('data-f')||'',dom_path:ancestry.reverse().join('/'),name:e.name||'',label:label.trim().slice(0,180),visible,disabled:!!e.disabled,readOnly:!!e.readOnly,required:!!e.required,value:e.value??null,checked:e.checked??null,associatedLabels,
        choice_group:isChoice?groupLabel.trim().slice(0,180):null,choice_selected:isChoice?(e.getAttribute('aria-checked')==='true'||e.getAttribute('aria-pressed')==='true'||e.classList.contains('on')||e.classList.contains('selected')):null,
        options:e.tagName==='SELECT'?[...e.options].map(o=>({value:o.value,text:o.text,disabled:o.disabled})):[],min:e.min||'',max:e.max||''};});
    return {controls,text:body.innerText.slice(0,10000),table_rows:[...body.querySelectorAll('tbody tr')].map(r=>r.innerText.slice(0,1500)).slice(0,100)};});
  result.snapshots.push({label,...state});return state;
}
function key(c){return [c.tag,c.type,c.id||c.field||c.name||((c.label||'')+'@'+c.dom_path),...(c.type==='radio'?[c.value]:[])].join('|');}
function values(state){const map={};for(const c of state.controls){if(['input','select','textarea'].includes(c.tag)&&!['hidden','button','submit','file'].includes(c.type))map[key(c)]=['checkbox','radio'].includes(c.type)?c.checked:c.value;else if(c.choice_group)map['choice|'+c.choice_group+'|'+c.label]=c.choice_selected;}return map;}
async function checked(page,loc,c){
  if(await loc.isChecked())return;
  // Native labels are part of the actual UI. Never force-click through an overlay
  // or inject a checked property; verify that the visible action changed the input.
  const labels=c.associatedLabels||[];let used=false;
  for(const index of labels){const label=page.locator('label').nth(index);if(await label.isVisible()){await label.click({timeout:3000});used=true;action('click_associated_label',{key:key(c),label:c.label});break;}}
  if(!used){await loc.check({timeout:3000});action('check',{key:key(c)});}
  if(!await loc.isChecked())throw Error('visible_check_action_did_not_select_control');
}
async function fill(page,label){let done=new Set();
  for(let loop=0;loop<40;loop++){
    const state=await snapshot(page,label+'-discover');
    const choice=state.controls.find(x=>x.visible&&!x.disabled&&x.choice_group&&!state.controls.some(y=>y.choice_group===x.choice_group&&y.choice_selected)&&!done.has('choice|'+x.choice_group));
    if(choice){done.add('choice|'+choice.choice_group);await page.locator('input,select,textarea,button,[role="button"],[role="radio"],a').nth(choice.index).click({timeout:3000});action('select_visible_choice',{group:choice.choice_group,label:choice.label});continue;}
    const c=state.controls.find(x=>x.visible&&!x.disabled&&!x.readOnly&&['input','select','textarea'].includes(x.tag)&&!['hidden','button','submit','reset','file','color','range'].includes(x.type)&&!done.has(key(x)));
    if(!c)break;done.add(key(c));const loc=page.locator('input,select,textarea,button,[role="button"],[role="radio"],a').nth(c.index);
    if(c.type==='radio'){if(state.controls.some(x=>x.type==='radio'&&x.name===c.name&&x.checked))continue;await checked(page,loc,c);}
    else if(c.type==='checkbox'){await checked(page,loc,c);}
    else if(c.tag==='select'){const option=c.options.find(o=>!o.disabled&&o.value!==''&&!/选择|select|choose/i.test(o.text));if(option){await loc.selectOption(option.value);action('select',{key:key(c),value:option.value});}}
    else {let value=c.type==='email'?'probe@example.invalid':c.type==='tel'||/电话|手机|phone/i.test(c.label)?'13800138000':c.type==='date'?'2026-09-12':c.type==='time'?'10:30':c.type==='datetime-local'?'2026-09-12T10:30':c.type==='number'?String(Math.max(Number(c.min||1),1)):c.type==='url'?'https://example.invalid':c.tag==='textarea'?'本地流程回归检查：设备无法启动。':'回归样本甲';if(c.type==='number'&&c.max)value=String(Math.min(Number(value),Number(c.max)));if(['date','datetime-local','time'].includes(c.type)){if(c.min&&value<c.min)value=c.min;if(c.max&&value>c.max)value=c.max;}await loc.fill(value);action('fill',{key:key(c),value});}
  }
  return snapshot(page,label+'-filled');
}
const NEXT=/下一步|下一页|继续|next|continue/i, BACK=/上一步|上一页|返回|previous|back/i, SUBMIT=/完成|提交|确认登记|保存登记|保存记录|submit|finish|register|save/i;
async function click(page,pattern,label){const state=await snapshot(page,label+'-discover');const c=state.controls.find(c=>c.visible&&!c.disabled&&['button','a','input'].includes(c.tag)&&pattern.test(c.label||c.value||'')&&!(pattern===NEXT&&BACK.test(c.label))&&!(pattern===SUBMIT&&/新建|清空|重置|取消|删除|导出|打印|new|reset|clear|cancel|delete|export|print/i.test(c.label)));if(!c)return false;await page.locator('input,select,textarea,button,[role="button"],[role="radio"],a').nth(c.index).click({timeout:3000});action('click',{key:key(c),label:c.label});await page.waitForTimeout(120);return true;}
function compare(expected,state){const current=values(state);return Object.entries(expected).map(([key,value])=>({key,expected:value,observed:current[key],present:Object.hasOwn(current,key),matches:current[key]===value}));}
function visibleFields(state){const map={};const all=values(state);for(const c of state.controls)if(c.visible&&!c.readOnly&&Object.hasOwn(all,key(c)))map[key(c)]=all[key(c)];return map;}
async function htmlCheck(page){
  let entry=await snapshot(page,'entry');const editable=entry.controls.find(c=>c.visible&&!c.disabled&&!c.readOnly&&['input','textarea','select'].includes(c.tag)&&!['hidden','button','submit','file'].includes(c.type));
  if(editable){const locator=page.locator('input,select,textarea,button,[role="button"],[role="radio"],a').nth(editable.index);let obstruction=null;
    try{await locator.click({trial:true,timeout:1800});}catch(e){obstruction=String(e).slice(0,1600);const close=entry.controls.find(c=>c.visible&&!c.disabled&&c.tag==='button'&&/^(关闭|關閉|我知道了|close|dismiss)$/i.test(c.label));if(close){await page.locator('input,select,textarea,button,[role="button"],[role="radio"],a').nth(close.index).click({timeout:1800});action('dismiss_visible_overlay',{label:close.label});await page.waitForTimeout(120);try{await locator.click({trial:true,timeout:1800});obstruction=null;}catch(e){obstruction=String(e).slice(0,1600);}}}
    if(obstruction){const blockers=await page.locator('[hidden]').evaluateAll(es=>es.filter(e=>getComputedStyle(e).display!=='none'&&e.getBoundingClientRect().width>200&&e.getBoundingClientRect().height>200).map(e=>({tag:e.tagName,hidden:e.hidden,display:getComputedStyle(e).display,position:getComputedStyle(e).position})));result.checks.push({id:'h02.entry_interaction',status:blockers.length?'fail':'unknown',observed:{obstruction,visible_hidden_elements:blockers,dismissal_attempted:result.actions.some(a=>a.type==='dismiss_visible_overlay')}});await shot(page,'entry-blocked');return;}
    result.checks.push({id:'h02.entry_interaction',status:'pass',observed:{editable_control_actionable:true}});
  }
  await shot(page,'01-initial');const first=await fill(page,'step1');const expect1=visibleFields(first);await shot(page,'02-step1');
  const next1=await click(page,NEXT,'next1');const second=next1?await fill(page,'step2'):await snapshot(page,'no-step2');const expect2=visibleFields(second);await shot(page,'03-step2');
  const back=next1&&await click(page,BACK,'back1');const backState=await snapshot(page,'after-back');const backward=compare(expect1,backState);
  if(back)await click(page,NEXT,'forward-again');const forwardState=await snapshot(page,'after-forward');const forward=compare(expect2,forwardState);
  result.checks.push({id:'h02.backward_retention',status:back?(backward.every(x=>x.matches)?'pass':'fail'):'unknown',observed:backward});
  result.checks.push({id:'h02.forward_retention',status:back?(forward.every(x=>x.matches)?'pass':'fail'):'unknown',observed:forward});
  await page.waitForTimeout(800);action('wait_for_autosave',{milliseconds:800});action('close_browser',{before_unload:true});await page.close({runBeforeUnload:true});await context.close();context=null;page=await launch();action('reopen_browser_same_origin');await shot(page,'04-reopened');
  const expected={...expect1,...expect2};const observed={};let state=await snapshot(page,'reopened');Object.assign(observed,values(state));
  for(let i=0;i<2;i++){if(await click(page,BACK,'restore-back')){state=await snapshot(page,'restore-back-state');Object.assign(observed,values(state));}}
  for(let i=0;i<2;i++){if(await click(page,NEXT,'restore-next')){state=await snapshot(page,'restore-next-state');Object.assign(observed,values(state));}}
  const persistence=Object.entries(expected).map(([key,value])=>({key,expected:value,observed:observed[key],present:Object.hasOwn(observed,key),matches:observed[key]===value}));
  result.checks.push({id:'h02.browser_restart_persistence',status:Object.keys(expected).length?(persistence.every(x=>x.matches)?'pass':'fail'):'unknown',observed:persistence});
  const third=await fill(page,'step3');await shot(page,'05-step3');const beforeSubmitAction=result.actions.length;const finalClick=await click(page,SUBMIT,'submit');const final=await snapshot(page,'after-submit');await shot(page,'06-final');
  const states=[first,second,third].map(s=>s.controls.filter(c=>c.visible).map(c=>key(c)+':'+c.label).join('\n'));
  result.checks.push({id:'h02.three_step_flow',status:next1&&new Set(states).size===3?'pass':'unknown',observed:{distinct_visible_states:new Set(states).size,fields_per_step:[Object.keys(expect1).length,Object.keys(expect2).length,Object.keys(visibleFields(third)).length]}});
  const newLines=final.text.split('\n').filter(l=>!third.text.split('\n').includes(l));const newRows=final.table_rows.filter(r=>!third.table_rows.includes(r));
  const success=newLines.some(l=>/登记成功|提交成功|已完成|已提交|成功保存|已保存|提交完成|登记完成|success|thank you/i.test(l))||result.actions.slice(beforeSubmitAction).some(a=>a.type==='dialog'&&/成功|success|完成|已保存/.test(a.message))||newRows.some(row=>Object.values(expected).filter(v=>typeof v==='string'&&v.length>2&&row.includes(v)).length>=2);
  result.checks.push({id:'h02.completion_feedback',status:finalClick&&success?'pass':'unknown',observed:{submit_clicked:finalClick,completion_feedback_visible:success,new_record_rows:newRows.length,new_feedback_lines:newLines.slice(0,12)}});
}
async function svgCheck(page){
  const sharp=require('sharp');const png=path.join(cfg.screenshot_dir,'svg.png');const raster=sharp(source,{limitInputPixels:20000000});const sourceInfo=await raster.metadata();const renderedInfo=await raster.png().toFile(png);fs.chmodSync(png,0o600);result.screenshots.push(png);result.renderer='sharp';
  result.render_coverage={kind:'full_intrinsic_svg_viewport',artifact_sha256:require('crypto').createHash('sha256').update(source).digest('hex'),source_width:sourceInfo.width,source_height:sourceInfo.height,output_width:renderedInfo.width,output_height:renderedInfo.height,cropped:false,resized:false,complete:sourceInfo.width===renderedInfo.width&&sourceInfo.height===renderedInfo.height,excludes_geometry_outside_defined_svg_viewport:true};
  const geometry=await page.evaluate(annotation=>{
    const root=document.documentElement,els=[root,...root.querySelectorAll('*')];
    const matrix=(role)=>{const el=els[role.element];let m=el.getCTM();if(role.instance!==undefined){const use=els[role.instance];const href=use.getAttribute('href')||use.getAttributeNS('http://www.w3.org/1999/xlink','href');const group=document.getElementById((href||'').slice(1));if(!group||!group.contains(el))throw Error('instance does not reference selected object');const parent=group.parentElement.getCTM();m=use.getCTM().multiply(parent.inverse()).multiply(m);}return m;};
    const bounds=role=>{const e=els[role.element],b=e.getBBox(),m=matrix(role);const points=[[b.x,b.y],[b.x+b.width,b.y],[b.x+b.width,b.y+b.height],[b.x,b.y+b.height]].map(([x,y])=>new DOMPoint(x,y).matrixTransform(m));return {x:Math.min(...points.map(p=>p.x)),y:Math.min(...points.map(p=>p.y)),right:Math.max(...points.map(p=>p.x)),bottom:Math.max(...points.map(p=>p.y))};};
    const inside=(role,x,y)=>{const e=els[role.element],p=new DOMPoint(x,y).matrixTransform(matrix(role).inverse());const style=getComputedStyle(e);return (style.fill!=='none'&&e.isPointInFill?.(p))||(style.stroke!=='none'&&e.isPointInStroke?.(p));};
    const inventory=els.map((e,index)=>{let b=null;try{if(e.getBBox)b=bounds({element:index});}catch{}const href=e.tagName==='use'?(e.getAttribute('href')||e.getAttributeNS('http://www.w3.org/1999/xlink','href')):null;const target=href?.startsWith('#')?document.getElementById(href.slice(1)):null;return {index,tag:e.tagName,bounds:b,parent_index:els.indexOf(e.parentElement),use_target_index:target?els.indexOf(target):null};});
    if(!annotation)return {inventory};const roles=annotation.roles;
    const tie=bounds(roles.tie),mirror=bounds(roles.mirror),head=bounds(roles.reflection_head);
    const contacts=roles.hands.map(hand=>{const h=bounds(hand);const x0=Math.max(h.x,tie.x),x1=Math.min(h.right,tie.right),y0=Math.max(h.y,tie.y),y1=Math.min(h.bottom,tie.bottom);let witness=null;if(x1>=x0&&y1>=y0){const dx=Math.max(.25,(x1-x0)/80),dy=Math.max(.25,(y1-y0)/80);for(let y=y0;y<=y1&&!witness;y+=dy)for(let x=x0;x<=x1;x+=dx)if(inside(hand,x,y)&&inside(roles.tie,x,y)){witness=[x,y];break;}}return {hand,bounds:h,overlap_witness:witness,bounds_gap:Math.max(0,tie.x-h.right,h.x-tie.right,tie.y-h.bottom,h.y-tie.bottom)};});
    const contained=head.x>=mirror.x&&head.right<=mirror.right&&head.y>=mirror.y&&head.bottom<=mirror.bottom;
    let reflection_transform=null,reflection_reverses_orientation=null;if(roles.reflection_head.instance!==undefined){const m=matrix(roles.reflection_head).multiply(els[roles.reflection_head.element].getCTM().inverse());reflection_transform=[m.a,m.b,m.c,m.d,m.e,m.f];reflection_reverses_orientation=(m.a*m.d-m.b*m.c)<0;}
    return {inventory,tie_bounds:tie,mirror_bounds:mirror,reflection_head_bounds:head,contacts,reflection_head_inside_mirror:contained,reflection_transform,reflection_reverses_orientation};
  },cfg.annotation||null);
  result.geometry=geometry;
}
(async()=>{try{
  server=http.createServer((req,res)=>{if(req.url!='/artifact'||req.method!=='GET'){res.writeHead(404);return res.end();}result.loopback_requests=(result.loopback_requests||0)+1;res.setHeader('Content-Type',cfg.mode==='svg'?'image/svg+xml':'text/html; charset=utf-8');res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; worker-src 'none'; child-src 'none'; form-action 'self'; base-uri 'none'");res.end(source);});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(cfg.artifact_port,'127.0.0.1',resolve);});origin='http://127.0.0.1:'+server.address().port;result.origin_scope='new_disposable_loopback_origin';
  const net=require('net');const blocked=await new Promise(resolve=>{const probe=net.connect({host:'127.0.0.1',port:cfg.network_canary_port});probe.once('connect',()=>{probe.destroy();resolve('CONNECTED');});probe.once('error',e=>resolve(e.code));probe.setTimeout(1500,()=>{probe.destroy();resolve('TIMEOUT');});});
  let fileBlocked;try{fs.readFileSync(cfg.filesystem_canary);fileBlocked='READ_ALLOWED';}catch(e){fileBlocked=e.code;}
  result.network_guard={kind:'macos_sandbox_exec_network_and_file_scopes',blocked_connect_error:blocked,blocked_read_error:fileBlocked,allowed_artifact_port:cfg.artifact_port};if(!['EPERM','EACCES'].includes(blocked)||!['EPERM','EACCES'].includes(fileBlocked))throw Error('network_sandbox_verification_failed');
  const page=await launch();if(cfg.mode==='html')await htmlCheck(page);else await svgCheck(page);
 }catch(e){result.driver_status=/step_limit/.test(String(e))?'limited':/Executable doesn't exist|browserType.launchPersistentContext|network_sandbox_verification/.test(String(e))?'unsupported':'failed';result.error=String(e).slice(0,12000);}finally{write('browser-result.json',result);await shutdown();}})();
