// Executes the actual injected script against fake DOM and fake same-origin network responses.
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../Sources/Adapters/SiliconFlowAdapter.swift'), 'utf8');
const match = source.match(/private static let script = #"""\n([\s\S]*?)\n    """#/);
if (!match) throw new Error('Unable to find production script');
const endpoint = 'https://cloud.siliconflow.cn/walletd-server/api/v1/subject/profile/peek';
const wallet = raw => `{"data":{"financialInfo":{"balance":"${raw}"}}}`;
async function sample({tab='余额 ¥1.2345… 剩余可透支额度 ¥0', raw='1234567890000', page='/me/expensebill?tab=balance', host='cloud.siliconflow.cn', responseStatus=200, redirected=false, responseURL=endpoint, visible=true, method='GET', subject='test-subject', body, transport='fetch', expireMismatch=false, expireNoRequest=false} = {}) {
  const emitted = [], stages = [], requests = [], timers = [];
  const loc = new URL(`https://${host}${page}`);
  const tabNode = {innerText:tab, getClientRects:() => visible ? [1] : []};
  const fetchImpl = async (url, init={}) => {
    requests.push({url, init});
    return {ok: responseStatus===200, redirected, url: responseURL, text:async()=>body ?? wallet(raw)};
  };
  class FakeXHR {
    open(method,url) {this.method=method; this.url=url;}
    setRequestHeader() {}
    addEventListener(name, fn) {if(name==='load') this.listener=fn;}
    send() {this.status=responseStatus; this.responseURL=responseURL; if(this.listener)this.listener();}
  }
  const document = {documentElement:{}, readyState:'complete', querySelectorAll:() => [tabNode], addEventListener() {}};
  const window = {fetch:fetchImpl, webkit:{messageHandlers:{siliconCash:{postMessage:o=>{const message=JSON.parse(JSON.stringify(o)); if ('amount' in message) emitted.push(message); else if ('stage' in message && Object.keys(message).length===1) stages.push(message.stage); else throw new Error('Unexpected data left WebKit');}}}}};
  const sandbox = {location:loc, document, window, URL, Headers, AbortController, XMLHttpRequest:FakeXHR,
    MutationObserver:class {observe() {}}, setTimeout:(fn,ms) => {if(ms===300) queueMicrotask(fn); else timers.push({fn,ms}); return 1;}, clearTimeout() {}};
  vm.runInNewContext(match[1], sandbox);
  if (transport === 'xhr') {
    const xhr = new sandbox.XMLHttpRequest(); xhr.open(method, endpoint); if(subject!==null) xhr.setRequestHeader('x-subject-id',subject); xhr.send();
  } else if (transport !== 'none') await window.fetch(endpoint,{method,headers:subject===null?{}:{'x-subject-id':subject}});
  await new Promise(resolve => setImmediate(resolve));
  await new Promise(resolve => setImmediate(resolve));
  if (expireMismatch) for (const timer of timers.filter(t=>t.ms===4000)) timer.fn();
  if (expireNoRequest) for (const timer of timers.filter(t=>t.ms===12000)) timer.fn();
  return {emitted, stages, requests};
}
(async () => {
  const checks = [];
  let r = await sample(); checks.push([JSON.stringify(r.emitted)==='[{"amount":"1.23456789"}]', 'valid prefix cross-check and exact 1e-12 decimal']);
  checks.push([r.stages.join(',')==='requestSeen,walletReceived', 'reports detected request and wallet stages']);
  checks.push([r.requests.length===2 && r.requests[1].url===endpoint && r.requests[1].init.redirect==='error' && r.requests[1].init.credentials==='same-origin', 'fixed same-origin redirect-rejecting replay']);
  checks.push([Object.keys(r.emitted[0]).join(',')==='amount', 'only amount leaves WebKit']);
  r = await sample({tab:'余额 ¥1.23456789 剩余可透支额度 ¥99'}); checks.push([r.emitted.length===1, 'exact visible amount preferred']);
  r = await sample({tab:'余额 ¥1.2345… （剩余可透支额度 ¥ 0）'}); checks.push([r.emitted.length===1, 'accepts full-width parenthesised overdraft']);
  r = await sample({tab:'余额 ¥1.2345… (剩余可透支额度 ¥ 0)'}); checks.push([r.emitted.length===1, 'accepts ASCII parenthesised overdraft']);
  r = await sample({tab:'余额 ¥1.2345… （剩余可透支额度 ¥ 0)'}); checks.push([r.emitted.length===0, 'rejects mismatched parentheses']);
  r = await sample({tab:'余额 ¥1.2345… （剩余可透支额度 ¥ 0） 充值金额 ¥9'}); checks.push([r.emitted.length===0, 'rejects extra amount after overdraft']);
  r = await sample({tab:'余额 ¥1.23… 剩余可透支额度 ¥0'}); checks.push([r.emitted.length===0, 'rejects short prefix']);
  r = await sample({tab:'余额 ¥1.2346… 剩余可透支额度 ¥0', expireMismatch:true}); checks.push([r.emitted.length===0 && r.stages.includes('layoutMismatch'), 'reports mismatching prefix']);
  r = await sample({raw:'0',tab:'余额 ¥0.0000… 剩余可透支额度 ¥0'}); checks.push([JSON.stringify(r.emitted)==='[{"amount":"0"}]', 'zero is invariant under scale']);
  r = await sample({raw:'0',tab:'余额 ¥0 （剩余可透支额度 ¥0）'}); checks.push([JSON.stringify(r.emitted)==='[{"amount":"0"}]', 'exact zero balance']);
  r = await sample({raw:'0',tab:'余额 ¥1.0000… （剩余可透支额度 ¥0）'}); checks.push([r.emitted.length===0, 'zero must still match visible balance']);
  r = await sample({subject:null}); checks.push([r.emitted.length===0 && r.stages.includes('noSubject'), 'reports missing subject without exposing it']);
  r = await sample({transport:'none',expireNoRequest:true}); checks.push([r.emitted.length===0 && r.stages.includes('noRequest'), 'reports no wallet request']);
  r = await sample({body:'{}'}); checks.push([r.emitted.length===0 && r.stages.includes('requestFailed'), 'reports invalid wallet payload']);
  r = await sample({page:'/me/expensebill?tab=other'}); checks.push([r.emitted.length===0 && r.requests.length===1, 'rejects wrong page']);
  r = await sample({host:'evil.example'}); checks.push([r.emitted.length===0 && r.requests.length===1, 'rejects non-official origin']);
  r = await sample({tab:'余额 ¥1.2345… 充值金额 ¥0'}); checks.push([r.emitted.length===0, 'rejects competing recharge card']);
  r = await sample({visible:false}); checks.push([r.emitted.length===0, 'rejects hidden balance tab']);
  r = await sample({redirected:true}); checks.push([r.emitted.length===0, 'rejects redirect']);
  r = await sample({responseURL:'https://evil.example/'}); checks.push([r.emitted.length===0, 'rejects wrong response origin']);
  r = await sample({body:'{"data":{"financialInfo":{"balance":"1","balance":"1234567890000"}}}'}); checks.push([r.emitted.length===0, 'rejects duplicate balance fields']);
  r = await sample({method:'POST'}); checks.push([r.emitted.length===0 && r.requests.length===1, 'rejects non-GET']);
  r = await sample({transport:'xhr'}); checks.push([r.emitted.length===1 && r.requests.length===1, 'XHR header captured only in WebKit and replayed']);
  let failures=0; for (const [ok,name] of checks) { console.log(`${ok?'PASS':'FAIL'}: SiliconFlow ${name}`); if (!ok) failures++; }
  if (failures) process.exit(1);
})();
