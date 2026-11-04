/* No analytics, storage, media capture, or recurring tests. */
(function () {
  'use strict';
  function ip(value) {
    if (typeof value !== 'string') return null;
    if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) {
      const octets = value.split('.').map(Number);
      return octets.every(x => x >= 0 && x <= 255) ? octets.join('.') : null;
    }
    if (!value.includes(':') || !/^[0-9a-f:.]+$/i.test(value)) return null;
    try { return new URL('https://[' + value + ']/').hostname.replace(/[\[\]]/g, '').toLowerCase(); }
    catch (_) { return null; }
  }
  function family(value) { return value.includes(':') ? 6 : 4; }
  function isPublic(value) {
    value = ip(value);
    if (!value) return false;
    if (family(value) === 6) {
      // IPv4-mapped and non-global IPv6 are not evidence of a public IPv6 leak.
      return /^[23][0-9a-f]{0,3}:/.test(value) && !value.startsWith('2001:db8:');
    }
    const [a, b, c] = value.split('.').map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
      (a === 192 && b === 0 && (c === 0 || c === 2)) ||
      (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) ||
      (a === 203 && b === 0 && c === 113));
  }
  function candidate(raw) {
    const parts = String(raw.candidate || '').trim().split(/\s+/);
    const address = raw.address || parts[4] || '';
    if (address.endsWith('.local')) return { kind: 'mdns', address: 'mDNS' };
    const normalized = ip(address);
    if (!normalized) return null;
    const type = raw.type || parts[parts.indexOf('typ') + 1];
    // TURN addresses belong to a relay, not to the user's physical interface.
    if (type === 'relay') return { kind: 'relay', address: normalized };
    return { kind: isPublic(normalized) ? 'public' : 'local', address: normalized };
  }
  function rtcVerdict(httpIP, candidates, complete) {
    const baseline = ip(httpIP);
    const exposed = [...new Set(candidates.filter(x => x.kind === 'public').map(x => x.address))];
    if (!baseline || !exposed.length) return 'incomplete';
    if (exposed.some(x => family(x) === family(baseline) && x !== baseline)) return 'risk';
    if (!complete || exposed.some(x => family(x) !== family(baseline))) return 'review';
    return 'match';
  }
  function dnsVerdict(resolvers, expected) {
    if (!resolvers.length) return 'incomplete';
    const tokens = expected.split(/[\s,;，；]+/).filter(Boolean);
    if (!tokens.length) return 'review';
    const allowed = tokens.map(ip);
    if (allowed.some(x => !x)) return 'invalid';
    return resolvers.every(x => allowed.includes(ip(x))) ? 'match' : 'risk';
  }
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { ip, isPublic, candidate, rtcVerdict, dnsVerdict };
    return;
  }

  const zh = (new URL(location.href).searchParams.get('lang') || navigator.language).startsWith('zh');
  const T = (en, cn) => zh ? cn : en;
  const $ = id => document.getElementById(id);
  const root = '/tokenclock/network-check';
  const embedded = new URL(location.href).searchParams.get('embedded') === '1';
  const labels = {
    title: T('Network Check', '网络泄漏检测'),
    subtitle: T('A small check of the addresses this environment exposes.', '检查当前环境实际暴露的网络地址'),
    scope: embedded ? T('TokenClock · embedded WebKit', 'TokenClock · 内嵌 WebKit 环境') : T('This browser', '当前浏览器环境'),
    start: T('Start check', '开始检测'), stop: T('Stop', '停止'),
    browser: T('Check in browser ↗', '在浏览器中检测 ↗'),
    exitTitle: T('Web connection', '网页出口'),
    exitHint: T('The address seen by the HTTPS server.', 'HTTPS 服务端实际看到的公网地址'),
    dnsTitle: T('DNS resolvers', 'DNS 解析器'),
    dnsHint: T('Observed from fresh, unique domain queries.', '通过全新随机域名查询实际观测'),
    rtcTitle: T('WebRTC addresses', 'WebRTC 暴露地址'),
    rtcHint: T('ICE / STUN candidates; no audio or video.', 'ICE / STUN 候选地址，不传输音视频'),
    expectedTitle: T('Expected DNS resolvers · optional', '预期 DNS 解析器 · 可选'),
    expectedHint: T('IP addresses separated by commas. Used locally for comparison.', '填写允许使用的解析器 IP，以逗号分隔；仅在当前页面内比较。'),
    note: T('Different exits or IP databases can disagree without proving a leak. No IPv6 response does not prove it is disabled. Embedded results do not represent other browsers.', '不同出口或 IP 库可能存在差异，不能仅据此确认泄漏。IPv6 无响应也不能证明已禁用。内嵌结果不代表其他浏览器。'),
    privacy: T('Runs on click · no media permissions · observations expire within 135 seconds', '点击才检测 · 无需音视频权限 · 服务端观测记录至多保留 135 秒'),
    idle: T('Ready when you are', '等待开始检测'),
    idleHint: T('No probes are running.', '当前没有进行网络探测。')
  };
  for (const [key, value] of Object.entries(labels)) if ($(key)) $(key).textContent = value;
  document.documentElement.lang = zh ? 'zh-CN' : 'en';
  document.title = labels.title + ' · TokenClock';
  $('expected').placeholder = T('For example: 1.1.1.1, 1.0.0.1', '例如：1.1.1.1, 1.0.0.1');
  $('browser').hidden = !embedded;

  const words = {
    idle: T('Not checked', '尚未检测'), running: T('Checking', '检测中'),
    observed: T('Observed', '已观测'), match: T('Matches', '与预期一致'),
    review: T('Review', '需要核对'), risk: T('Unexpected address', '发现预期外地址'),
    incomplete: T('Inconclusive', '未能完成'), invalid: T('Invalid expected IP', '预期 IP 格式有误')
  };
  let active = null, last = null;
  function badge(id, value) {
    $(id).textContent = words[value];
    $(id).dataset.state = value;
  }
  function addresses(id, items, empty) {
    const box = $(id); box.replaceChildren();
    if (!items.length) { box.textContent = empty; box.className = 'addresses empty'; return; }
    box.className = 'addresses';
    for (const item of items) {
      const line = document.createElement('div'); line.className = 'address';
      const code = document.createElement('code'); code.textContent = item.address;
      const tag = document.createElement('span'); tag.textContent = item.tag || '';
      line.append(code, tag); box.append(line);
    }
  }
  function renderDNS() {
    if (!last) return;
    badge('dnsBadge', dnsVerdict(last.resolvers, $('expected').value));
    window.TokenClockDiagnostics?.summarize();
  }
  function stop() {
    const run = active;
    if (!run) return;
    active = null;
    clearTimeout(run.deadline);
    run.controller.abort();
    for (const cancel of [...run.cancellations]) cancel();
    if (run.pc) { run.pc.onicecandidate = null; run.pc.close(); }
    $('start').disabled = false; $('stop').hidden = true;
    window.TokenClockDiagnostics?.stopped();
    $('idle').textContent = T('Stopped', '已停止');
    $('idleHint').textContent = T('No probes are running. Partial results are not a safety verdict.', '探测已停止，部分结果不能作为安全结论。');
    for (const key of ['exitBadge', 'dnsBadge', 'rtcBadge']) if ($(key).dataset.state === 'running') badge(key, 'incomplete');
  }
  function wait(run, ms) {
    return new Promise(resolve => {
      let timer;
      const done = () => { clearTimeout(timer); run.cancellations.delete(done); resolve(); };
      run.cancellations.add(done); timer = setTimeout(done, ms);
    });
  }
  async function json(run, path, options = {}) {
    const response = await fetch(root + path, { ...options, credentials: 'omit', cache: 'no-store', signal: run.controller.signal });
    if (!response.ok) throw new Error('service');
    return response.json();
  }
  async function gather(run, server) {
    const found = [];
    let complete = false;
    if (typeof RTCPeerConnection !== 'function') return { found, complete };
    try {
      const pc = new RTCPeerConnection({ iceServers: [{ urls: server }], iceCandidatePoolSize: 0 });
      run.pc = pc;
      let finish;
      const done = new Promise(resolve => { finish = resolve; });
      pc.onicecandidate = event => {
        if (!event.candidate) { complete = true; finish(); return; }
        const item = candidate(event.candidate);
        if (item && !found.some(x => x.address === item.address && x.kind === item.kind)) found.push(item);
      };
      pc.createDataChannel('probe');
      await pc.setLocalDescription(await pc.createOffer());
      await Promise.race([done, wait(run, 6500)]);
      pc.onicecandidate = null; pc.close(); run.pc = null;
    } catch (_) { /* Report no candidates as inconclusive, never as leak-free. */ }
    return { found, complete };
  }
  async function dns(run, session) {
    // The authoritative service intentionally replies NXDOMAIN after observing
    // these names. No HTTPS connection, media, or large payload is needed.
    await Promise.all(session.hosts.map(async host => {
      const controller = new AbortController();
      const abort = () => controller.abort();
      run.controller.signal.addEventListener('abort', abort, { once: true });
      const timer = setTimeout(abort, 2200);
      try { await fetch('https://' + host + '/probe', { mode: 'no-cors', credentials: 'omit', cache: 'no-store', signal: controller.signal }); }
      catch (_) { /* NXDOMAIN is expected. The result comes from authority logs. */ }
      finally { clearTimeout(timer); run.controller.signal.removeEventListener('abort', abort); }
    }));
    let result = { resolvers: [], probesObserved: 0 };
    for (let i = 0; i < 7 && active === run; i++) {
      result = await json(run, '/result/' + session.token);
      if (result.probesObserved >= 3) break;
      await wait(run, 700);
    }
    return result;
  }
  async function start() {
    if (active) return;
    const run = { id: crypto.randomUUID(), controller: new AbortController(), pc: null, cancellations: new Set() };
    active = run; last = null;
    run.deadline = setTimeout(() => { if (active === run) stop(); }, 25000);
    if($('overallSummary')) $('overallSummary').textContent=T('Checking; waiting for evidence…','检测中，等待观测证据…');
    window.TokenClockDiagnostics?.reset();
    $('start').disabled = true; $('stop').hidden = false;
    $('idle').textContent = T('Checking this connection', '正在检查当前连接');
    $('idleHint').textContent = T('A few small DNS and STUN probes.', '正在发送少量 DNS 和 STUN 探测请求。');
    for (const key of ['exitBadge', 'dnsBadge', 'rtcBadge']) badge(key, 'running');
    for (const key of ['exitAddresses', 'dnsAddresses', 'rtcAddresses']) addresses(key, [], '…');
    try {
      const session = await json(run, '/session', { method: 'POST' });
      if (active !== run) return;
      if (!ip(session.ip) || !/^[a-f0-9]{32}$/.test(session.token) ||
          !Array.isArray(session.hosts) || session.hosts.length !== 3 ||
          !session.hosts.every((h, i) => h === 'p' + i + '.' + session.token + '.probe.tokenclock.ailyre.com') ||
          session.stun !== 'stun:ns.tokenclock.ailyre.com:3478') throw new Error('response');
      addresses('exitAddresses', [{ address: session.ip, tag: 'HTTPS / IPv' + family(session.ip) }], '');
      badge('exitBadge', 'observed');
      const [dnsResult, rtc, diagnostics] = await Promise.all([dns(run, session), gather(run, session.stun),
        window.TokenClockDiagnostics.start(run.id, session.ip, run.controller.signal, session.token)]);
      if (active !== run) return;
      last = { resolvers: dnsResult.resolvers.filter(x => ip(x)), rtc, ip: session.ip };
      addresses('dnsAddresses', last.resolvers.map(address => ({ address, tag: T('Resolver', '查询来源') })), T('No authoritative queries observed.', '未观测到权威 DNS 查询。'));
      renderDNS();
      const tags = { public: T('Public', '公网'), local: T('Local / special', '内网 / 特殊地址'), mdns: T('Local IP hidden', '内网 IP 已隐藏'), relay: T('Relay', '中继') };
      addresses('rtcAddresses', rtc.found.map(x => ({ address: x.address, tag: tags[x.kind] })), T('No address candidates available.', '没有获取到可用候选地址。'));
      badge('rtcBadge', rtcVerdict(session.ip, rtc.found, rtc.complete));
      window.TokenClockDiagnostics.render(diagnostics, session.ip, rtc.found);
      $('idle').textContent = T('Check finished', '本次检测完成');
      $('idleHint').textContent = T('No probes are running. Results apply to this check only.', '探测已停止，结果仅代表本次检测。');
    } catch (_) {
      if (active === run) {
        $('idle').textContent = T('Check could not finish', '检测未能完成');
        $('idleHint').textContent = T('The service or probes may be blocked. Retry when the connection is available.', '服务或探测请求可能被阻止，请在网络可用时重试。');
        window.TokenClockDiagnostics?.stopped();
        if($('overallSummary')) $('overallSummary').textContent=T('Check incomplete; no safety verdict.','本次检测未完成，不能据此判断安全。');
        for (const key of ['exitBadge', 'dnsBadge', 'rtcBadge']) if ($(key).dataset.state === 'running') badge(key, 'incomplete');
      }
    } finally {
      clearTimeout(run.deadline);
      for (const cancel of [...run.cancellations]) cancel();
      if (run.pc) { run.pc.onicecandidate = null; run.pc.close(); }
      run.controller.abort();
      if (active === run) { active = null; $('start').disabled = false; $('stop').hidden = true; }
    }
  }
  $('start').onclick = start; $('stop').onclick = stop;
  $('expected').oninput = renderDNS;
  $('browser').onclick = () => { location.href = 'tokenclock-network-browser://open'; };
  window.addEventListener('pagehide', stop);
  window.TokenClockLeak = { stop, normalizeIP: ip, receiveDiagnostics: data => window.TokenClockDiagnostics?.receive(data) };
  for (const key of ['exitBadge', 'dnsBadge', 'rtcBadge']) badge(key, 'idle');
  if (location.hash === '#run') { history.replaceState(null, '', location.pathname + location.search); start(); }
})();
