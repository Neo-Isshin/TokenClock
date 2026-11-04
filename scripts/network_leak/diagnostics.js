(function () {
  'use strict';
  function sameFamily(a, b) { return a.includes(':') === b.includes(':'); }
  function exitsVerdict(baseline, rows) {
    const values = rows.filter(x => x.category === 'exit' && x.state === 'observed' && x.ip);
    if (!values.length) return 'incomplete';
    if (values.some(x => !sameFamily(x.ip, baseline) || x.ip !== baseline)) return 'review';
    return values.some(x => x.id !== 'ailyre') ? 'match' : 'incomplete';
  }
  function locationVerdict(baseline, rows) {
    const values = rows.filter(x => x.ip === baseline && x.country && ['geo', 'exit'].includes(x.category));
    if (new Set(values.map(x => x.country)).size > 1) return 'review';
    // Multiple Cloudflare trace sites share one location database.
    return new Set(values.map(x => x.category === 'exit' ? 'Cloudflare' : x.label)).size >= 2 ? 'match' : 'incomplete';
  }
  function ipv6Verdict(rows, candidates, ipv4Only) {
    const http = [...new Set(rows.filter(x => x.category === 'ipv6' && x.state === 'observed' && x.ip?.includes(':')).map(x => x.ip))];
    const rtc = [...new Set(candidates.filter(x => x.kind === 'public' && x.address.includes(':')).map(x => x.address))];
    if (!http.length && !rtc.length) return 'notObserved';
    if (ipv4Only) return 'risk';
    if (http.length && rtc.some(x => !http.includes(x))) return 'risk';
    return http.length && rtc.length ? 'match' : 'review';
  }
  function aiVerdict(baseline, row) {
    if (row.ip && row.state === 'observed') return row.ip === baseline ? 'match' : 'review';
    return 'incomplete';
  }
  function dohVerdict(baseline, rows) {
    const probes=rows.filter(x=>x.category==='doh');
    const echoes=rows.filter(x=>x.category==='dohEcho'&&x.state==='observed'&&x.ip);
    const baseProxy=rows.find(x=>x.id==='ailyre')?.proxy;
    if(echoes.some(x=>x.ip!==baseline) || (baseProxy===true && probes.some(x=>x.state==='verified'&&x.proxy===false))) return 'review';
    return 'incomplete'; // Other endpoints' DNS replies alone never prove their client egress.
  }
  function overall(states) {
    const risk=Object.keys(states).filter(k=>states[k]==='risk');
    const review=Object.keys(states).filter(k=>states[k]==='review');
    const unknown=Object.keys(states).filter(k=>['incomplete','notObserved'].includes(states[k]));
    return {risk,review,unknown};
  }
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { exitsVerdict, locationVerdict, ipv6Verdict, aiVerdict, dohVerdict, overall }; return;
  }
  const zh = (new URL(location.href).searchParams.get('lang') || navigator.language).startsWith('zh');
  const T = (en, cn) => zh ? cn : en;
  const $ = id => document.getElementById(id);
  const labels = {
    dohTitle:T('DoH path check','DoH 路径检查'),
    dohHint:T('Verified HTTPS DNS queries; readable configuration is a snapshot, not runtime proof.','验证真实 DoH 查询；配置快照不等于当前实际启用状态。'),
    consistencyTitle: T('Exit & location consistency', '出口与落地一致性'),
    consistencyHint: T('Compare observed exits and country data for the same IP.', '核对多个出口，以及同一 IP 的多来源国家/地区信息'),
    ipv6Title: T('IPv6 exposure', 'IPv6 泄漏检查'),
    ipv6Hint: T('IPv6-only HTTPS probe, compared with WebRTC.', '通过 IPv6 专用站点探测，并与 WebRTC 地址对照'),
    aiTitle: T('AI domain routing', 'AI 域名分流自检'),
    aiHint: T('Only a returned client IP establishes an observed exit.', '仅在目标确实返回客户端 IP 时判断出口；HTTP 响应不等于分流成功'),
    ipv4OnlyLabel: T('Expect IPv4-only access', '预期只通过 IPv4 访问'),
    policyHint: T('Enable only if IPv6 should be blocked by your policy.', '仅在你的策略要求阻止 IPv6 时勾选；IPv6 可达本身不等于泄漏。'),
    diagnosticScope: T('App checks use the Mac system proxy/VPN. Browser extensions and account access are outside this check.', '应用内检测使用 Mac 系统代理/VPN；不代表浏览器扩展规则，也不检查账号或模型使用权限。')
  };
  for (const [id, text] of Object.entries(labels)) if ($(id)) $(id).textContent = text;
  const status = {
    idle: T('Not checked', '尚未检测'), running: T('Checking', '检测中'),
    match: T('Observed match', '观测一致'), review: T('Review', '需要核对'),
    incomplete: T('Insufficient evidence', '证据不足'), risk: T('Unexpected IPv6', '发现预期外 IPv6'),
    notObserved: T('No IPv6 observed', '未观测到 IPv6')
  };
  let previous = null;
  function badge(id, state, text) { $(id).textContent = text || status[state]; $(id).dataset.state = state; }
  function line(box, title, value, hint) {
    const row = document.createElement('div'); row.className = 'diagnostic-row';
    const name = document.createElement('span'); name.className = 'diagnostic-name'; name.textContent = title;
    const details = document.createElement('div');
    const code = document.createElement('code'); code.textContent = value;
    const tag = document.createElement('small'); tag.textContent = hint || '';
    details.append(code, tag); row.append(name, details); box.append(row);
  }
  function render(data, baseline, candidates) {
    previous = { data, baseline, candidates };
    const rows = Array.isArray(data?.rows) ? data.rows.slice(0, 32) : [];
    const consistency = $('consistencyAddresses'); consistency.replaceChildren();
    const exits = rows.filter(x => x.category === 'exit');
    for (const row of exits) line(consistency, row.label, row.ip || '—', row.country || (row.state === 'unavailable' ? T('Unavailable', '未获取') : ''));
    const geo = rows.filter(x => x.category === 'geo' && x.ip === baseline);
    for (const row of geo) line(consistency, row.label, row.country || '—', [row.region, row.city].filter(Boolean).join(' / '));
    if (!rows.length) line(consistency, '—', T('No result', '没有可用结果'), '');
    const exitState = exitsVerdict(baseline, rows), locState = locationVerdict(baseline, rows);
    const state = [exitState, locState].includes('review') ? 'review' : exitState === 'match' && locState === 'match' ? 'match' : 'incomplete';
    badge('consistencyBadge', state);
    $('consistencyDetail').textContent = T('Exit: ', '出口：') + status[exitState] + ' · ' + T('Country: ', '地区：') + status[locState];
    const v6 = $('ipv6Addresses'); v6.replaceChildren();
    const ipv6Rows = rows.filter(x => x.category === 'ipv6');
    for (const row of ipv6Rows) line(v6, 'HTTPS IPv6', row.ip || '—', row.ip ? '' : T('Not observed; may be blocked', '未观测到，可能不可达或受阻'));
    for (const candidate of candidates.filter(x => x.kind === 'public' && x.address.includes(':'))) line(v6, 'WebRTC IPv6', candidate.address, '');
    if (!ipv6Rows.length) line(v6, 'HTTPS IPv6', '—', T('No result', '未获取结果'));
    const v6State = ipv6Verdict(rows, candidates, $('ipv4Only').checked);
    badge('ipv6Badge', v6State);
    const ai = $('aiAddresses'); ai.replaceChildren();
    const aiRows = rows.filter(x => x.category === 'ai');
    for (const row of aiRows) {
      const verdict = aiVerdict(baseline, row);
      const hint = row.ip ? T('Observed exit', '观测出口') + (row.country ? ' · ' + row.country : '')
        : row.httpStatus ? 'HTTP ' + row.httpStatus + ' · ' + T('No exit evidence', '无出口证据') : T('Unavailable', '未获取');
      line(ai, row.label, row.ip || row.host, hint);
      ai.lastElementChild.dataset.state = verdict;
    }
    if (!aiRows.length) line(ai, T('App check', '应用内检测'), T('Open in TokenClock', '请在 TokenClock 内检测'), T('Browser cross-origin restrictions prevent reliable route checks.', '浏览器跨域限制下无法可靠核对这些域名的出口。'));
    const observedAI = aiRows.filter(x => x.state === 'observed' && x.ip);
    const aiState = observedAI.some(x => aiVerdict(baseline, x) === 'review') ? 'review'
      : aiRows.length && observedAI.length === aiRows.length ? 'match' : 'incomplete';
    badge('aiBadge', aiState, observedAI.length ? T('Observed ', '已观测 ') + observedAI.length + '/' + aiRows.length : null);
    const doh=$('dohAddresses');doh.replaceChildren();
    const dohs=rows.filter(x=>['doh','dohEcho','dohConfig'].includes(x.category));
    for(const row of dohs) {
      let hint=row.note||'';
      if(row.category==='dohEcho'&&row.ip) hint += ' · '+(row.ip===baseline?T('Same HTTPS exit','与网页出口一致'):T('Different exit; review routing','出口不同，需核对路由'));
      if(row.category==='doh'&&typeof row.proxy==='boolean') hint+=' · '+T('HTTP proxy: ','HTTP 代理：')+(row.proxy?T('yes','已使用'):T('not observed (VPN unknown)','未观测，VPN 未确认'));
      line(doh,row.label,row.ip||row.host||'—',hint);
    }
    if(!dohs.length) line(doh,'DoH',T('Use TokenClock','请使用 TokenClock 内检测'),T('This browser cannot expose its DoH transport or settings.','浏览器页面无法确认其 DoH 传输和配置。'));
    const verified=rows.filter(x=>x.category==='doh'&&x.state==='verified').length;
    badge('dohBadge',dohVerdict(baseline,rows),verified?T('DNS verified ','DNS 已验证 ')+verified+'/2':T('Unconfirmed','未确认'));
    summarize();
  }

  const pending = new Map();
  function nativeHandler() { return window.webkit?.messageHandlers?.networkDiagnostics; }
  function receive(data) {
    if (!data || typeof data.runID !== 'string') return;
    const callback = pending.get(data.runID);
    if (callback) callback(data);
  }
  async function browserRequest(url, signal) {
    const controller = new AbortController(); const abort = () => controller.abort();
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) controller.abort();
    const timer = setTimeout(abort, 4500);
    try {
      const response = await fetch(url, { credentials: 'omit', cache: 'no-store', signal: controller.signal });
      if (!response.ok || Number(response.headers.get('content-length')) > 16384) return null;
      const reader = response.body.getReader(); const parts = []; let size = 0;
      while (true) {
        const chunk = await reader.read(); if (chunk.done) break;
        size += chunk.value.length;
        if (size > 16384) { await reader.cancel(); return null; }
        parts.push(chunk.value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.length; }
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch (_) { return null; }
    finally { clearTimeout(timer); signal.removeEventListener('abort', abort); controller.abort(); }
  }
  async function browserCheck(runID, baseline, signal) {
    const [v4, v6] = await Promise.all([
      browserRequest('https://api.ipify.org?format=json', signal),
      browserRequest('https://api6.ipify.org?format=json', signal)
    ]);
    const clean = window.TokenClockLeak?.normalizeIP;
    const ipv4 = clean?.(v4?.ip), ipv6 = clean?.(v6?.ip);
    const rows = [
      {id:'ipify',category:'exit',label:'ipify IPv4',host:'api.ipify.org',state:ipv4 ? 'observed':'unavailable',ip:ipv4},
      {id:'ipv6',category:'ipv6',label:'ipify IPv6',host:'api6.ipify.org',state:ipv6?.includes(':') ? 'observed':'unavailable',ip:ipv6?.includes(':') ? ipv6:null}
    ];
    if (signal.aborted) return {runID,rows:[]};
    const encoded = encodeURIComponent(baseline);
    const [who, country] = await Promise.all([
      browserRequest('https://ipwho.is/' + encoded + '?fields=ip,success,country_code,region,city', signal),
      browserRequest('https://api.country.is/' + encoded, signal)
    ]);
    for (const [source, value] of [['IPWhois', who], ['Country.is', country]]) {
      if (value?.success !== false && clean?.(value?.ip) === baseline) {
        const code = value.country_code || value.country;
        if (/^[A-Z]{2}$/.test(code || '')) rows.push({id:source,category:'geo',label:source,state:'observed',ip:baseline,country:code,region:value.region,city:value.city});
      }
    }
    return {runID,rows};
  }
  function start(runID, baselineIP, signal, dnsToken) {
    const handler = nativeHandler();
    if (!handler) return browserCheck(runID, baselineIP, signal);
    return new Promise(resolve => {
      let timer;
      const finish = result => {
        clearTimeout(timer); pending.delete(runID); signal.removeEventListener('abort', abort); resolve(result);
      };
      const abort = () => { handler.postMessage({action:'cancel',runID}); finish({runID,rows:[]}); };
      pending.set(runID, finish);
      signal.addEventListener('abort', abort, {once:true});
      timer = setTimeout(abort, 18000);
      if (signal.aborted) { abort(); return; }
      handler.postMessage({action:'start',runID,baselineIP,dnsToken});
    });
  }
  function reset() {
    previous = null;
    for (const id of ['consistencyBadge','ipv6Badge','aiBadge','dohBadge']) badge(id,'running');
    for (const id of ['consistencyAddresses','ipv6Addresses','aiAddresses','dohAddresses']) $(id).textContent = '…';
    $('consistencyDetail').textContent = '';
  }
  function stopped() {
    if($('overallSummary')) $('overallSummary').textContent=T('Check stopped; partial results are inconclusive.','本次检测已停止，部分结果不能作为安全结论。');
    for (const id of ['consistencyBadge','ipv6Badge','aiBadge','dohBadge']) if ($(id).dataset.state === 'running') badge(id,'incomplete');
  }
  $('ipv4Only').onchange = () => { if (previous) render(previous.data, previous.baseline, previous.candidates); };
  for (const id of ['consistencyBadge','ipv6Badge','aiBadge']) badge(id,'idle');
  function summarize() {
    const names={dns:'DNS',rtc:'WebRTC',consistency:T('Exit/location','出口/地区'),ipv6:'IPv6',ai:T('AI routing','AI 分流'),doh:'DoH'};
    const states=Object.fromEntries(Object.keys(names).map(x=>[x,$(x+'Badge')?.dataset.state]));
    const result=overall(states),out=[];
    if(result.risk.length) out.push(T('Risk evidence: ','风险线索：')+result.risk.map(x=>names[x]).join('、'));
    if(result.review.length) out.push(T('Review: ','需核对：')+result.review.map(x=>names[x]).join('、'));
    if(!out.length) out.push(T('No differences in observed results','已观测结果未发现差异'));
    if(result.unknown.length) out.push(T('Unconfirmed: ','未确认：')+result.unknown.map(x=>names[x]).join('、'));
    if($('overallSummary')) $('overallSummary').textContent=out.join('；')+T('. Results cover this check only.','。仅代表本次检测。');
  }
  window.TokenClockDiagnostics = {start,receive,render,reset,stopped,summarize};
})();
