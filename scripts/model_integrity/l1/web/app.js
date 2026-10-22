'use strict';
const $=id=>document.getElementById(id);
const terminal=new Set(['completed','failed','cancelled','interrupted','action_required']);
const statuses={queued:'等待开始',running:'正在检测',cancelling:'正在停止',cancelled:'已停止',completed:'报告已生成',failed:'未能完成',interrupted:'运行中断',action_required:'需要处理后再继续'};
const stages={importing:'读取内容',extracting:'提取记录',semantics:'理解会话',reporting:'整理发现',saving:'保存报告',completed:'完成'};
const packageDefaults={openai:['O07:A','C06:A','O05:A'],anthropic:['O06:B','C02:B','O05:A']};
const selectedReports=new Set(),sourceDrafts=new Map(),taskDrafts=new Map(),jobElements=new Map();
const selectedConnections={p:null,j:null,l:null};
const roleFields={p:{endpoint:'p-endpoint',key:'p-key',model:'p-model',format:'p-format',input:'p-input',output:'p-output'},j:{endpoint:'j-endpoint',key:'j-key',model:'j-model',format:'j-format',input:'j-input',output:'j-output'},l:{endpoint:'endpoint',key:'api-key',model:'judge-model',format:'l-format',input:'input-price',output:'output-price'}};
let probeCatalog=[],connectionProfiles=[],refreshing=false,revision=0,previewState=null,busy=false;
let source={path:'',name:'',file:null,uploadedPath:null},sourceKey='l1',resumeJob=null,autoReportJob=null,reportGeneration=0;
let currentFamily='openai';
const modelCatalogs={};
let activeJudgeSource='separate',judgeTargetFollows=true,lastJudgeWorkflow='l1';
const judgeSourceDrafts={};
const jobRecords=new Map(),consumedRecommendations=new Set();
const typedKeyBindings={};
let suggestion=null,shownReportId=null;
let screenState='setup',currentJobId=null,sessionChoices=[];
let automaticReferenceFamily=true;
const referenceModelFamilies={'gpt-5.5':'openai','gpt-5.6-sol':'openai','gpt-6-astra':'openai','claude-sonnet-5':'anthropic','claude-opus-5':'anthropic','claude-fable-5':'anthropic'};
function referenceMatch(){const model=$('p-model').value.trim(),tail=model.split('/').pop();return {model,known:!!referenceModelFamilies[tail],family:referenceModelFamilies[tail]||(model.startsWith('openai/')?'openai':model.startsWith('anthropic/')?'anthropic':null)};}
function referenceFamilyProblem(){const r=referenceMatch();return $('workflow-mode').value==='l2'&&$('probe-mode').value==='live'&&automaticReferenceFamily&&r.model&&!r.family?'型号别名无法匹配参考家族，请在高级设置中明确选择题包。':'';}
function syncReferenceFamily(){const r=referenceMatch();if(automaticReferenceFamily&&!suggestion&&!resumeJob&&r.family&&$('probe-family').value!==r.family){$('probe-family').value=r.family;setFamily({reset:true});}}
function setScreen(value){screenState=value;$('setup-screen').hidden=value!=='setup';$('progress-screen').hidden=value!=='progress';$('report-panel').hidden=value!=='result';document.body.dataset.screen=value;window.scrollTo({top:0,behavior:'auto'});}
function returnToSetup(){autoReportJob=null;currentJobId=null;reportGeneration++;shownReportId=null;clearSuggestion();resumeJob=null;$('resume-notice').hidden=true;$('advanced-settings').open=false;$('review-panel').hidden=true;$('action-error').textContent='';setScreen('setup');updateWorkflow({changed:false});invalidate();}
function requestsModel(config){return config.mode==='external'||config.transport_mode==='live'||config.external?.enabled===true||(config.assessment?.enabled===true&&config.assessment.transport_mode==='live');}
function simpleWantsAPI(){const w=$('workflow-mode').value;return w==='l1'?$('external-enabled').checked:['l2','l3'].includes(w)&&($('probe-mode').value==='live'||$('judge-enabled').checked);}
function updateSimpleForm(){
 const paid=simpleWantsAPI();$('prepare').textContent=paid?'查看费用并继续':'开始检测';$('prepare-note').textContent=paid?'先确认费用和发送范围，不会自动调用。':'仅在本机分析，无模型费用。';
 const pVisible=['l2','l3'].includes($('workflow-mode').value)&&$('probe-mode').value==='live';$('price-required').hidden=!pVisible||($('p-input').value!==''&&$('p-output').value!=='');
 const r=referenceMatch(),showReference=pVisible&&$('workflow-mode').value==='l2'&&!!r.model&&!r.known;$('reference-choice-note').hidden=!showReference;$('reference-choice-note').textContent=referenceFamilyProblem()||'该型号暂无直接画像；按所选题包记录观察，不把参考不足当作型号相符。';$('open-reference-settings').hidden=!referenceFamilyProblem();
 $('selected-source').hidden=!source.path&&!source.file&&!resumeJob;
}
async function api(path,body){
 const response=await fetch(path,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',credentials:'same-origin'});
 const data=await response.json();if(!response.ok)throw new Error(data.error||'操作未完成，请检查配置后重试。');return data;
}
function node(tag,cls,content){const n=document.createElement(tag);if(cls)n.className=cls;if(content!==undefined)n.textContent=String(content);return n;}
function button(label,action,key=label){const b=node('button','quiet',label);b.dataset.action=key;b.addEventListener('click',async()=>{b.disabled=true;try{await action();}catch(e){showError(e);}finally{b.disabled=false;}});return b;}
function showError(error){const text=error.message||String(error);$('action-error').textContent=text;if(screenState==='result'){$('result-action-error').hidden=false;$('result-action-error').textContent=text;}else if(screenState==='progress')$('current-progress-message').textContent=text;}
function number(id){const raw=$(id).value.trim();return raw===''?null:Number(raw);}
function money(value,missing='待内容确定'){return value===null||value===undefined||value===''?missing:Number.isFinite(Number(value))?'$'+Number(value).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:6}):'暂不可计算';}
function clearConsents(){for(const id of ['p-consent','j-consent','allow-external'])$(id).checked=false;}
function invalidate(){revision++;previewState=null;clearConsents();$('cost-preview').replaceChildren(node('p','empty','内容或配置已改变，请重新确认。'));$('consent-area').hidden=true;$('review-panel').hidden=true;updateStart();}
function updateStart(){
 const fresh=previewState&&previewState.revision===revision&&previewState.data.valid;
 let agreed=true;
 for(const [row,id] of [['p-consent-row','p-consent'],['j-consent-row','j-consent'],['l-consent-row','allow-external']])if(!$(row).hidden&&!$(id).checked)agreed=false;
 const missingKey=fresh&&(previewState.data.roles||[]).some(r=>{if(r.enabled===false)return false;const role=r.role==='target'||(r.role==='judge'&&sharedJudge())?'p':$('workflow-mode').value==='l1'?'l':'j';return !hasCredential(role);});
 const suggestionError=suggestionProblem()||referenceFamilyProblem();
 $('start').disabled=busy||!fresh||!agreed||missingKey||!!suggestionError;$('prepare').disabled=busy||!!suggestionError;
 $('start').textContent=resumeJob?'确认配置并重试':fresh?'开始本次检测':'预览后开始检测';
 $('start-note').textContent=suggestionError||(!fresh?'先确认输入、方法与费用预览。':missingKey?'预览不需要密钥。启动前请为当前接口填写密钥或选择可用连接；其他接口的已填密钥不会直接用于这里。':!agreed?'确认上方外发范围后才能开始。':previewState.data.local_only?'本次仅在本机处理，无模型请求费用。':'仅执行已预览并同意的请求，不自动充值或重试。');
 renderSuggestionNotice();
 updateSimpleForm();
}
function publicBinding(value){if(!value||typeof value!=='object')return null;const keys=['endpoint','api_format','model'];if(keys.some(k=>typeof value[k]!=='string'||!value[k].trim()))return null;return Object.fromEntries(keys.map(k=>[k,value[k].trim()]));}
function currentBinding(){return publicBinding({endpoint:$('p-endpoint').value,api_format:$('p-format').value,model:$('p-model').value});}
function bindingKey(value){return value?JSON.stringify([value.endpoint,value.api_format,value.model]):'';}
function budgetValue(value){if(value===null||value===undefined||value===''||typeof value==='boolean')return null;const n=Number(value);return Number.isFinite(n)&&n>=0?n:null;}
function suggestionProblem(){
 if(!suggestion)return '';
 if(consumedRecommendations.has(suggestion.origin))return '这份报告已经派生后续任务，请在后续结果中查看新的建议。';
 const binding=currentBinding();
 if(suggestion.binding&&bindingKey(binding)!==bindingKey(suggestion.binding))return '当前待测连接与建议对象不同。请手动选择对应连接；现有连接和密钥已保留。';
 if(!suggestion.binding&&(!binding||suggestion.confirmedBinding!==bindingKey(binding)))return '该报告没有可绑定的新调用接口。请明确选定当前接口为新检测对象。';
 if($('workflow-mode').value!==suggestion.workflow||$('probe-mode').value!=='live')return '检测方式已偏离本项建议，请重新选择建议或改为手动方案。';
 if(suggestion.workflow==='l2'&&JSON.stringify(selectedTasks().slice().sort())!==JSON.stringify(suggestion.tasks.slice().sort()))return '题目已改变，请重新选择建议或改为手动方案。';
 if(suggestion.workflow==='l3'&&$('heavy-task').value!==suggestion.task)return '任务已改变，请重新选择建议或改为手动方案。';
 const target=number('p-cost');if(target===null||!Number.isFinite(target)||target<=0)return '请明确填写本次待测预算；未知余额不会按旧满额回填。';
 if(suggestion.targetBudget!==null&&target>suggestion.targetBudget)return '建议可用待测余额为 '+money(suggestion.targetBudget)+'，不能按旧满额追加。';
 if($('judge-enabled').checked){const judge=number('j-cost');if(judge===null||!Number.isFinite(judge)||judge<=0)return '如需模型解析，请明确填写其独立预算。';if(suggestion.judgeBudget!==null&&judge>suggestion.judgeBudget)return '建议可用评审余额为 '+money(suggestion.judgeBudget)+'，不能按旧满额追加。';}
 return '';
}
function renderSuggestionNotice(){
 $('suggestion-notice').hidden=!suggestion;if(!suggestion)return;
 $('suggestion-title').textContent='已填入建议：'+suggestion.title;
 $('suggestion-reason').textContent=suggestion.reason;
 const expected=suggestion.binding;
 $('suggestion-binding').textContent=expected?'建议对象：'+expected.model+' · '+expected.endpoint+'（'+expected.api_format+'）'+(bindingKey(currentBinding())===bindingKey(expected)?'。当前连接匹配。':'。请选择匹配连接后再预览。'):suggestion.confirmedBinding===bindingKey(currentBinding())&&currentBinding()?'已明确选择当前接口作为新检测对象；这不追溯认证旧会话。':'未提供可靠的接口绑定。现有连接不会被替换，需明确选择本次要核查的接口。';
 $('suggestion-budget').textContent=expected?'报告所示剩余：待测 '+money(suggestion.targetBudget,'未知，需填写')+' · 评审 '+money(suggestion.judgeBudget,'未知，启用时需填写')+'。提交前还会核对来源任务的最新账本，只能派生一个后续任务。':'该报告不能绑定旧接口或承接其预算。本次属于独立的新检测，需明确填写预算后再预览。';
 $('confirm-suggestion-connection').hidden=!!expected;$('confirm-suggestion-connection').disabled=!currentBinding();
}
function clearSuggestion(){suggestion=null;$('suggestion-notice').hidden=true;}
function intent(){const w=$('workflow-mode').value,m=$('probe-mode').value;return w==='l1'?'session':['l2','l3'].includes(w)?m==='live'?'api':m==='artifact'?'file':'advanced':'advanced';}
function draftKey(){const w=$('workflow-mode').value,m=$('probe-mode').value;return ['l2','l3'].includes(w)?w+':'+m+(w==='l3'?':'+$('heavy-task').value:''):w;}
function needsSource(){return !['live','demo'].includes($('probe-mode').value)||!['l2','l3'].includes($('workflow-mode').value);}
function renderSource(){
 $('source-path').value=source.path;$('session-file').value='';$('choose-file').textContent=source.file||source.path?'更换文件':'选择文件';
 $('selected-source').textContent=resumeJob?'将使用原任务已保存的内容快照。':source.file?(source.uploadedPath?'已导入本机：':'待导入：')+source.file.name:source.path?'已选择：'+(source.name||source.path.split(/[\\/]/).pop()):$('workflow-mode').value==='l1'?'尚未选择会话':'尚未选择文件';
 $('recent-session-select').value=sessionChoices.some(s=>s.path===source.path)?source.path:'';updateSimpleForm();
}
function choose(path,name){if(resumeJob)leaveResume();source={path,name:name||path.split(/[\\/]/).pop(),file:null,uploadedPath:null};renderSource();invalidate();$('action-error').textContent='';}
function switchSourceDraft(){const next=draftKey();if(next===sourceKey)return;sourceDrafts.set(sourceKey,source);source=sourceDrafts.get(next)||{path:'',name:'',file:null,uploadedPath:null};sourceKey=next;renderSource();}
function supportsJudge(){const w=$('workflow-mode').value,m=$('probe-mode').value,t=$('heavy-task').value;return w==='l2'?m!=='demo':w==='l3'&&(t.startsWith('H04')||(t==='H03'&&['live','replay'].includes(m)));}
function canShareJudge(){return supportsJudge()&&$('probe-mode').value==='live';}
function sharedJudge(){return canShareJudge()&&$('j-source').value==='target';}
function batchJudge(){return $('workflow-mode').value==='l2'&&$('j-batch-once').checked;}
function targetIdentity(){return [$('p-endpoint').value.trim(),$('p-format').value].join('|');}
function judgeEndpoint(){return sharedJudge()?$('p-endpoint').value.trim():$('j-endpoint').value.trim();}
function clearJudgeCatalog(){delete modelCatalogs.j;if($('j-catalog-model'))$('j-catalog-model').hidden=true;if($('j-catalog-note'))$('j-catalog-note').textContent='';}
function useTargetModel(){judgeTargetFollows=true;$('j-model').value=$('p-model').value.trim();$('j-input').value=$('p-input').value;$('j-output').value=$('p-output').value;clearJudgeCatalog();}
function updateJudgeControls({restoring=false}={}){
 const w=$('workflow-mode').value,allowed=canShareJudge();$('j-source').querySelector('[value="target"]').disabled=!allowed;
 if(!allowed)$('j-source').value='separate';
 const selected=$('j-source').value;
 if(restoring){activeJudgeSource=selected;judgeTargetFollows=false;}
 else if(selected!==activeJudgeSource){
  judgeSourceDrafts[activeJudgeSource]={model:$('j-model').value,input:$('j-input').value,output:$('j-output').value,repeats:$('j-repeats').value,follows:judgeTargetFollows,identity:targetIdentity()};activeJudgeSource=selected;
  const saved=judgeSourceDrafts[selected];
  if(saved){$('j-model').value=saved.model;$('j-input').value=saved.input;$('j-output').value=saved.output;$('j-repeats').value=saved.repeats;judgeTargetFollows=saved.follows;if(selected==='target'){if(judgeTargetFollows)useTargetModel();else if(saved.identity!==targetIdentity()){$('j-input').value='';$('j-output').value='';}}}
  else if(selected==='target')useTargetModel();
  clearJudgeCatalog();if(selected==='target'&&w==='l3')$('j-repeats').value='1';
 }
 if(!restoring&&!resumeJob&&w==='l3'&&lastJudgeWorkflow!=='l3'&&selected==='target')$('j-repeats').value='1';lastJudgeWorkflow=w;
 $('j-source').disabled=!!resumeJob;$('j-batch-once').disabled=!!resumeJob;$('j-separate-connection').hidden=selected==='target';$('j-use-target').hidden=selected!=='target';
 $('l2-batch-settings').hidden=w!=='l2';$('j-repeats-field').hidden=batchJudge();$('j-repeats-field').parentElement.classList.toggle('single-budget',batchJudge());
 $('j-source-note').textContent=selected==='target'?'复用待测接口与密钥，解析／评审费用仍单独限额。默认使用待测型号；可以明确改用该接口的另一型号，改型后需重新填写报价。复用接口不构成独立来源证明。':allowed?'使用单独配置的解析／评审连接，费用与待测请求分开控制。':'已有文件或回放使用单独配置的评审连接，不从历史记录取得接口或密钥。';
 $('j-repeat-note').textContent=batchJudge()?'全部轻量回答收集完后，只发送一次汇总解析请求。':w==='l3'&&$('heavy-task').value.startsWith('H04')?'SVG／ASCII 评审包括对象、动作与表达关系的语义判断，并非只做格式或几何规则解析。重复两次仍是同一评审型号。':'按每份内容分别评审。重复两次使用同一评审型号，不等于两位独立评审者。';
}
function updateWorkflow({changed=true}={}){
 const w=$('workflow-mode').value,probe=['l2','l3'].includes(w),m=$('probe-mode');
 for(const o of m.options)o.disabled=o.value==='demo'&&w==='l3'&&$('heavy-task').value!=='H03';
 if(m.selectedOptions[0]?.disabled)m.value='artifact';
 const mode=m.value,kind=intent();
 if(changed){switchSourceDraft();invalidate();}
 for(const k of ['session','api','file']){$('intent-'+k).classList.toggle('active',kind===k);$('intent-'+k).setAttribute('aria-pressed',String(kind===k));}
 $('probe-settings').hidden=!probe;$('execution-mode').hidden=!probe;$('method-choice').hidden=kind!=='api';$('probe-depth').value=probe?w:'l2';
 $('l2-settings').hidden=w!=='l2';$('l3-settings').hidden=w!=='l3';$('semantic-settings').hidden=w!=='l1';
 $('recent-sessions').hidden=w!=='l1'||!!resumeJob;$('task-preview').hidden=w==='l1';$('probe-provider').hidden=!probe||mode!=='live';
 $('source-section').hidden=!needsSource()||!!resumeJob;$('external-fields').hidden=!$('external-enabled').checked;
 const canJudge=supportsJudge();$('assessment-settings').hidden=!canJudge;if(!canJudge)$('judge-enabled').checked=false;$('judge-fields').hidden=!$('judge-enabled').checked;
 updateJudgeControls();
 for(const id of ['workflow-mode','probe-mode','probe-depth','probe-family','heavy-task','comparison-model'])$(id).disabled=!!resumeJob||!!suggestion;
 for(const input of document.querySelectorAll('#task-options input'))input.disabled=!!resumeJob||!!suggestion;
 $('method-badge').textContent=({l1:'L1 · 本地会话',l2:'L2 · 轻量短题',l3:'L3 · 交付核验',diagnostics:'服务记录',combined:'综合观察'})[w];
 const notes={l1:'读取本地已有会话，不执行记录里的命令。',diagnostics:'读取请求/响应、用量或流式记录，观察可见字段与服务处理。',combined:'导入含 reports 数组的 tokenclock-combined-input/v1 JSON，仅合并内嵌报告。'};
 $('workflow-note').textContent=notes[w]||({live:'本次会产生新的模型请求，用于检查所选接口，不追溯判定旧会话的来源。',artifact:w==='l2'?'导入 tokenclock-l2-answer-set/v1 回答包。不再调用待测模型。':'核验现有作品，不补写原文件，也不虚构模型工作过程。',replay:'回放包需绑定原请求哈希；H03 还需绑定工作区状态。不会重新调用待测模型。',demo:'只验证产品流程，不调用待测模型或评审模型，也不代表真实型号表现。'})[mode];
 $('source-label').textContent=w==='l1'?'导入会话文件':mode==='replay'?'导入绑定的回放包':w==='l2'?'导入原题与回答包':'导入要检查的文件';
 $('file-hint').textContent=w==='l1'?'JSON / JSONL 会话日志，最多 64 MiB。':w==='l3'&&mode==='artifact'?'Python、HTML、SVG 或文本，最多 64 MiB；在高级设置中选择对应任务。':'JSON / JSONL，最多 64 MiB；回放包需要原请求绑定。';
 $('session-file').accept=w==='l3'&&mode==='artifact'?'.json,.jsonl,.py,.html,.svg,.txt':'.json,.jsonl,.txt';
 updateRecommendation();updatePromptPreview();updateStart();
}
function selectIntent(kind){
 autoReportJob=null;currentJobId=null;reportGeneration++;setScreen('setup');
 clearSuggestion();
 resumeJob=null;$('resume-notice').hidden=true;
 if(kind==='session')$('workflow-mode').value='l1';
 if(kind==='api'){$('workflow-mode').value='l2';$('probe-mode').value='live';}
 if(kind==='file'){$('workflow-mode').value='l3';$('probe-mode').value='artifact';}
 updateWorkflow();
}
function updateRecommendation(){
 const el=$('recommendation');el.replaceChildren();const w=$('workflow-mode').value,m=$('probe-mode').value,t=$('heavy-task').value;
 const title={l1:'先从已有记录寻找线索',l2:'用短题观察可重复的回答偏好',l3:'用实际作品检查交付与表达',diagnostics:'检查可见的服务处理',combined:'汇总同一对象的多项观察'}[w];
 el.append(node('h3','',title));
 const explanations={l1:'适合先看请求型号、可见字段、工具记录与交付过程。记录缺失会标为未知，不当作模型能力失败。',l2:'每题独立重复两次，对照已有参考。一次选择不同只是局部信号，不直接判定换型。',l3:'程序、交互与几何能检查的部分由本地核验；需要理解内容的部分单独标明判断来源。',diagnostics:'字段差异可能来自代理、缓存或协议转换，不直接等同于型号变化。',combined:'保留每份报告的对象与条件；共享依据不会当作多份独立证据。'};
 el.append(node('p','hint',explanations[w]));
 if(w==='l2')el.append(node('p','method-detail',selectedTasks().length+' 题 × 2 次'+(m==='live'?'新请求':'已有回答观察')));
 if(w==='l3')el.append(node('p','method-detail',$('heavy-task').selectedOptions[0].textContent));
 if(['demo','replay'].includes(m)&&['l2','l3'].includes(w))el.append(node('p','warning',m==='demo'?'受控演示：结果不代表真实模型。':'记录回放：不是新的采样结果。'));
 if(w==='l3'&&!supportsJudge())el.append(node('p','hint',t==='H03'?'只有最终文件时无法补出原工作轨迹；本次使用本地检查。':'此任务使用本地程序或交互核验，不发送模型评审请求。'));
 if(w==='l3'&&t.startsWith('H04')&&!$('judge-enabled').checked)el.append(node('p','hint','未启用视觉评审：未知作品的对象含义与表达关系可能保留为未核验。可在左侧选择是否补充评审。'));
}
function selectedTasks(){return [...document.querySelectorAll('#task-options input:checked')].map(n=>n.value);}
function setFamily({reset=false}={}){
 if(!reset&&$('task-options').childElementCount)taskDrafts.set(currentFamily,selectedTasks());
 currentFamily=$('probe-family').value;const selected=taskDrafts.get(currentFamily)||packageDefaults[currentFamily];$('task-options').replaceChildren();
 const eligible=probeCatalog.filter(t=>t.layer==='L2'&&(t.automatic_extraction==='supported'||$('judge-enabled').checked));
 for(const t of eligible){const label=node('label','check'),box=node('input');box.type='checkbox';box.value=t.id;box.checked=selected.includes(t.id);box.addEventListener('change',()=>{automaticReferenceFamily=false;taskDrafts.set(currentFamily,selectedTasks());invalidate();updatePromptPreview();updateRecommendation();});label.append(box,node('span','',t.id+' · '+(t.title||'')+(t.automatic_extraction==='supported'?'':' · 需模型评审')));$('task-options').append(label);}
 const all=probeCatalog.filter(t=>t.layer==='L2'),supported=all.filter(t=>t.automatic_extraction==='supported');
 $('task-coverage').textContent='规则可提取 '+supported.length+' / '+all.length+' 个变体。其余变体需要另行启用评审；模型判断与规则结果分别记录。';
 updatePromptPreview();updateRecommendation();
}
function updatePromptPreview(){
 const el=$('prompt-preview');el.replaceChildren();const w=$('workflow-mode').value;
 if(!['l2','l3'].includes(w)){el.append(node('p','hint',$('workflow-note').textContent));return;}
 if(w==='l3'&&$('probe-mode').value==='demo'){el.append(node('p','hint','分阶段账本演示验证读写和停止条件，不是增量构建任务的模型结果。'));return;}
 for(const id of w==='l2'?selectedTasks():[$('heavy-task').value]){const t=probeCatalog.find(t=>t.id===id);if(t)el.append(node('h3','',id+' · '+(t.title||'')),node('pre','',t.prompt),node('p','hint','单次生成上限 '+t.output_limit+' token · '+(w==='l2'?'每题使用全新上下文':'核验结论与型号声明分别记录')));}
}
function provider(role){const f=roleFields[role];return {endpoint:$(f.endpoint).value.trim(),api_key:$(f.key).value,model:$(f.model).value.trim(),connection_id:selectedConnections[role]||undefined,api_format:$(f.format).value,input_usd_per_million:number(f.input),output_usd_per_million:number(f.output)};}
function credentialBinding(role){const f=roleFields[role];return JSON.stringify([$(f.endpoint).value.trim(),$(f.format).value]);}
function hasCredential(role){const p=provider(role);if(p.api_key)return typedKeyBindings[role]===credentialBinding(role);const profile=connectionProfiles.find(x=>x.id===p.connection_id);return !!profile&&profile.credential_state!=='needs_key';}
function requireProvider(p,role){if(!p.endpoint||!p.model||(!p.api_key&&!p.connection_id))throw Error('请填写连接、精确型号 ID 与密钥，或选择已保存的连接。');if(role&&!hasCredential(role))throw Error('接口或协议已改变，请重新输入当前连接的密钥，或选择对应的已保存连接。');if(p.input_usd_per_million===null||p.output_usd_per_million===null)throw Error('请填写该渠道的输入与输出单价。');}
function productConfig({authorize=false}={}){
 const blocked=suggestionProblem()||referenceFamilyProblem();if(blocked)throw Error(blocked);
 const w=$('workflow-mode').value;
 if(w==='l1'){
  if(!$('external-enabled').checked)return {mode:'local'};
  const p=provider('l');if(authorize){requireProvider(p,'l');if(!$('allow-external').checked)throw Error('请确认本次会话评审的外发范围。');}
  return {mode:'external',external:{...p,enabled:true,max_output_tokens:number('max-output'),max_cost_usd:number('max-cost')}};
 }
 if(['diagnostics','combined'].includes(w))return {mode:'local',workflow_mode:w};
 const mode=$('probe-mode').value,c={mode:mode==='live'?'external':'local',workflow_mode:w,transport_mode:mode};
 if(w==='l2'){c.family=$('probe-family').value;c.task_ids=selectedTasks();if(c.task_ids.length<1||c.task_ids.length>5)throw Error('请选择 1–5 道题，每题分别运行 2 次。');}
 if(w==='l3'){c.task_id=$('heavy-task').value;c.evaluation={};if($('program-interface').value!=='auto')c.evaluation.interface={mode:$('program-interface').value,name:'settle',arguments:'people_expenses'};if($('node-path').value.trim())c.evaluation.node_path=$('node-path').value.trim();if($('node-modules-path').value.trim())c.evaluation.node_modules_path=$('node-modules-path').value.trim();}
 if(mode==='live'){const p=provider('p');if(authorize){requireProvider(p,'p');if(!$('p-consent').checked)throw Error('请确认本次待测请求的外发范围。');c.allow_live=true;}c.provider={...p,reasoning_effort:'high',stream:true,max_cost_usd:number('p-cost'),wall_seconds:number('p-wall'),idle_seconds:120,...(authorize?{allow_live:true}:{})};}
 if(supportsJudge()&&$('judge-enabled').checked){
  const shared=sharedJudge(),batch=batchJudge(),p=shared?{model:$('j-model').value.trim(),input_usd_per_million:number('j-input'),output_usd_per_million:number('j-output')}:provider('j');
  if(shared&&(!p.model||p.input_usd_per_million===null||p.output_usd_per_million===null))throw Error('请填写解析型号和对应报价，或选择“使用待测型号和当前报价”。');
  if(authorize){if(shared){if(!p.model||p.input_usd_per_million===null||p.output_usd_per_million===null)throw Error('请填写本次解析型号和对应报价。');}else requireProvider(p,'j');if(!$('j-consent').checked)throw Error('请确认本次解析／评审独立预算与外发范围。');}
  c.assessment={enabled:true,transport_mode:'live',connection_source:shared?'target':'separate',batch_once:batch,...(authorize?{allow_live:true}:{}),repeats:batch?1:number('j-repeats'),provider:{...p,reasoning_effort:'high',max_cost_usd:number('j-cost'),max_output_tokens:number('j-output-limit'),max_requests:batch?1:20,wall_seconds:900}};
  if($('j-detail').value)c.assessment.provider.image_detail=$('j-detail').value;if($('j-image-tokens').value!=='')c.assessment.provider.image_tokens_upper_per_image=number('j-image-tokens');
 }
 return c;
}
async function prepareSelectedSource(){
 if(resumeJob||!needsSource())return null;
 const chosen=source;
 if(chosen.file){if(chosen.file.size>64*1024*1024)throw Error('文件超过 64 MiB，请选择更明确的内容范围。');if(!chosen.uploadedPath){const uploaded=await api('api/upload',{name:chosen.file.name,content:await chosen.file.text()});chosen.uploadedPath=uploaded.path;}if(chosen===source)$('selected-source').textContent='已导入本机：'+chosen.file.name;return chosen.uploadedPath;}
 return chosen.path.trim()||null;
}
function requestBody(path,config){return {source_path:path,comparison_model:$('comparison-model').value.trim()||null,semantic_config:config,...(resumeJob?{resume_job_id:resumeJob.id}:needsSource()&&source.name?{input_name:source.name}:{}),...(!resumeJob&&suggestion?.binding?{recommendation_origin_job_id:suggestion.origin,recommendation_action_id:suggestion.id}:{})};}
async function prepare(){
 $('action-error').textContent='';busy=true;clearConsents();updateStart();const requestedRevision=revision;
 try{const config=productConfig();const path=await prepareSelectedSource();if(revision!==requestedRevision)throw Error('预览期间配置已改变，请重新预览。');const data=await api('api/preview',requestBody(path,config));if(revision!==requestedRevision)throw Error('预览期间配置已改变，请重新预览。');previewState={revision,data,path};if(data.valid&&data.local_only===true&&!requestsModel(config)){await start();return;}renderCostPreview(data);$('review-panel').hidden=false;$('review-panel').scrollIntoView({behavior:'smooth',block:'nearest'});}
 catch(error){showError(error);previewState=null;}
 finally{busy=false;updateStart();}
}
function renderCostPreview(data){
 const el=$('cost-preview');el.replaceChildren();
 for(const error of data.errors||[])el.append(node('p','error',typeof error==='string'?error:error.message||'配置不完整。'));
 if(data.local_only&&data.valid)el.append(node('p','cost-total','本机分析 · 无模型费用'));
 const details=node('details','cost-details');details.append(node('summary','','费用计算明细'));
 if(!data.local_only){const roles=data.roles||[],known=roles.length&&roles.every(r=>budgetValue(r.budget_usd)!==null),total=data.total_budget_usd??(known?roles.reduce((sum,r)=>sum+Number(r.budget_usd),0):null);el.append(node('p','cost-total','本次预算 '+money(total)));}
 for(const r of data.roles||[]){if(r.enabled===false)continue;const name=r.role==='target'?'待测请求':'解析／评审',p=r.role==='target'?provider('p'):$('workflow-mode').value==='l1'?provider('l'):{endpoint:judgeEndpoint(),model:$('j-model').value.trim()};
  const compact=node('div','confirm-role');compact.append(node('strong','',name+' · '+money(r.budget_usd)),node('p','hint',(r.sends||[]).map(x=>typeof x==='string'?x:x.description||'').filter(Boolean).join('；')));if(p.endpoint)compact.append(node('p','hint',p.model+' · '+p.endpoint));el.append(compact);
  const card=node('div','cost-role');card.append(node('h3','',name));const grid=node('dl','cost-grid');for(const [label,value]of [['最多请求',r.max_requests===null||r.max_requests===undefined?'待内容确定':String(r.max_requests)+' 次'],['首个请求完整预留',money(r.per_request_reserve_usd)],['全部计划请求上界',money(r.whole_run_upper_usd)],['本次可用预算',money(r.budget_usd)]])grid.append(node('dt','',label),node('dd','',value));card.append(grid);
  if(r.original_budget_usd!==undefined)card.append(node('p','hint','原任务预算 '+money(r.original_budget_usd)+'；已有费用不会清零。'));for(const note of r.notes||[])card.append(node('p','hint',note));details.append(card);
 }
 const warnings=(data.warnings||[]).map(x=>typeof x==='string'?x:x.message||'').filter(Boolean);if(warnings.length)el.append(node('p','warning',warnings[0]));for(const text of warnings.slice(1))details.append(node('p','hint',text));
 if((data.roles||[]).some(r=>r.whole_run_upper_usd===null))el.append(node('p','hint','部分内容生成后才能计算完整费用；每次发送前仍会预留并检查预算。'));
 if(details.childElementCount>1)el.append(details);
 const target=(data.roles||[]).some(r=>r.role==='target'&&r.enabled!==false),judge=(data.roles||[]).some(r=>r.role==='judge'&&r.enabled!==false),l1=$('workflow-mode').value==='l1';
 $('p-consent-row').hidden=!target;$('j-consent-row').hidden=!judge||l1;$('l-consent-row').hidden=!judge||!l1;$('consent-area').hidden=!data.valid||(!target&&!judge);
}
async function start(){
 if(!previewState||previewState.revision!==revision||!previewState.data.valid){showError(Error('请先完成本次配置预览。'));return;}
 busy=true;updateStart();$('action-error').textContent='';
 try{const config=productConfig({authorize:true});const body=requestBody(previewState.path,config);body.allow_external=$('allow-external').checked||$('p-consent').checked||$('j-consent').checked;const job=resumeJob?await api('api/jobs/'+resumeJob.id+'/resume',body):await api('api/jobs',body);if(suggestion){if(suggestion.binding){consumedRecommendations.add(suggestion.origin);disableConsumedRecommendations(suggestion.origin);}clearSuggestion();}autoReportJob=job.id||resumeJob?.id;currentJobId=autoReportJob;resumeJob=null;$('resume-notice').hidden=true;updateWorkflow({changed:false});renderSource();invalidate();setScreen('progress');renderCurrentProgress(job);await refreshJobs();}
 catch(error){showError(error);}finally{busy=false;updateStart();}
}
async function refreshSessions(){
 $('refresh-sessions').disabled=true;
 try{const data=await api('api/sessions'),list=$('sessions');list.replaceChildren();sessionChoices=[];const recent=$('recent-session-select');recent.replaceChildren();const placeholder=node('option','','选择最近会话');placeholder.value='';recent.append(placeholder);for(const s of data.sessions||[]){const path=s.path||s.source_path;if(!path)continue;const name=s.title||s.display_name||s.name||path.split(/[\\/]/).pop(),tool=s.tool||s.format||s.provider||'会话',rawDate=s.modified_at||s.modified,date=rawDate?new Date(rawDate):null,dateText=date&&!Number.isNaN(date.valueOf())?date.toLocaleString('zh-CN',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';const title=/^(rollout-|[a-f\d]{8}-)/i.test(name)?({codex:'Codex 会话','claude-code':'Claude Code 会话'}[tool]||tool)+' · '+(dateText||name):name;const item=node('div','item'),content=node('div','item-content'),heading=node('div','item-title',title);heading.title=name;sessionChoices.push({path,name,title});if(sessionChoices.length<=12){const suffix=name.replace(/\.[^.]+$/,'').slice(-6),option=node('option','',title+' · '+suffix);option.value=path;recent.append(option);}const model=s.raw_model?'记录型号 '+s.raw_model:s.display_model?'显示标签 '+s.display_model:'';content.append(heading,node('div','item-meta',[model,/^(rollout-|[a-f\d]{8}-)/i.test(name)?name.slice(-18):[tool,dateText].filter(Boolean).join(' · ')].filter(Boolean).join(' · ')));item.append(content,button('选择',()=>choose(path,name)));list.append(item);}if(!list.childElementCount)list.append(node('p','empty','没有找到可读取的会话。可在左侧导入文件。'));if(sessionChoices.length>12){const more=node('option','','更多会话…');more.value='__more__';recent.append(more);}recent.value=[...recent.options].some(x=>x.value===source.path)?source.path:'';if(!sessionChoices.length)recent.options[0].textContent='没有最近会话，请选择文件';$('scan-note').textContent=(data.limitations||[]).slice(0,2).map(v=>typeof v==='string'?v:v.message||'').join(' ');}
 catch(error){$('sessions').replaceChildren(node('p','empty','暂时无法读取目录，请直接导入文件。'));const option=node('option','','暂时无法读取，请选择文件');option.value='';$('recent-session-select').replaceChildren(option);}finally{$('refresh-sessions').disabled=false;}
}
function renderCurrentProgress(job){
 if(!job||job.id!==currentJobId||screenState!=='progress')return;
 const p=job.progress||{};$('current-progress-title').textContent=job.status==='cancelling'?'正在停止':job.status==='queued'?'等待检测':'正在检测';$('current-progress-message').textContent=stages[p.stage||job.stage]||boundedText(p.message||job.message,400)||'正在完成本次检测，请稍候。';
 if(typeof p.fraction==='number')$('current-progress-bar').value=p.fraction;else $('current-progress-bar').removeAttribute('value');
 const totals=job.probe_billing?.totals||job.semantic_billing?.totals;$('current-progress-cost').textContent=totals?billingLine(totals):'';$('cancel-current').disabled=job.status==='cancelling';
}
function renderBriefResult(brief,report,id){
 const job=jobRecords.get(id),config=job?.semantic_config||{},label=config.transport_mode==='live'?boundedText(config.provider?.model,70):boundedText(job?.input_name,70);$('result-object-label').textContent=label?'本次结果 · '+label:'本次结果';
 $('result-action-error').hidden=true;$('result-action-error').textContent='';$('report-title').textContent=boundedText(brief.title,160)||'结果已保存';$('brief-summary').textContent=boundedText(brief.summary,600);$('brief-reasons').replaceChildren();for(const reason of (Array.isArray(brief.reasons)?brief.reasons:[]).slice(0,3)){const text=boundedText(reason,450);if(text)$('brief-reasons').append(node('li','',text));}$('brief-reasons').hidden=!$('brief-reasons').childElementCount;
 $('brief-caveat').textContent=boundedText(brief.caveat,500)||'这是有限观察，不能单独认证真实后端型号。';$('brief-action').replaceChildren();
 const action=brief.next_action||{};
 if(action.kind==='recommendation'&&!consumedRecommendations.has(id)){const rec=report?.user_summary?.recommendation,item=rec?.actions?.find(x=>x.id===action.id);if(item&&['recommended','needs_configuration'].includes(rec.status)){const b=button(boundedText(action.label,70)||'准备下一项检测',()=>applyReportRecommendation(id,rec,item));b.className='primary';b.id='brief-primary-action';b.dataset.recommendationOrigin=id;$('brief-action').append(b);}}
 else if(action.kind==='configure'){const b=button(boundedText(action.label,70)||'调整检测配置',returnToSetup);b.className='primary';b.id='brief-primary-action';$('brief-action').append(b);}
}
function conservativeBrief(report){const s=report?.user_summary||{};return {title:boundedText(s.title,160)||'结果已保存',summary:'这份记录未包含新版简要结论，可以在详情中查看原有分析。',reasons:Array.isArray(s.findings)?s.findings.slice(0,3):[],caveat:'旧报告请以完整依据为准。',next_action:{kind:'none'}};}
function showStoppedResult(job){
 currentJobId=job.id;setScreen('result');$('result-details').open=false;$('report-evidence').open=false;$('report-evidence').hidden=true;$('report-frame').removeAttribute('src');$('report-links').replaceChildren();$('report-summary').replaceChildren(renderJob(job));
 const cancelled=job.status==='cancelled';renderBriefResult({title:cancelled?'检测已停止':'这次检测未完成',summary:cancelled?'已停止新增请求，现有记录会保留。':'目前还不能形成完整结果，请先处理本次未完成的原因。',reasons:[],caveat:'未完成或受限不等于模型异常；已发送请求的费用仍会保留。',next_action:{kind:'none'}},null,job.id);
 const b=button('检查配置后重试',()=>configureResume(job));b.className='primary';b.id='brief-primary-action';$('brief-action').append(b);
}
function renderSummary(summary,container,{compact=false}={}){
 if(!summary)return false;container.append(node(compact?'p':'h3',compact?'summary-title':'',summary.title||'本次主要发现'));
 if(!compact&&summary.synthesis?.schema==='tokenclock-evidence-synthesis/v1'){
  renderSynthesis(summary.synthesis,container);
  const details=node('details','summary-details');details.append(node('summary','','其他摘要与范围说明'));
  for(const [title,items] of [['已有发现',summary.findings],['范围说明',summary.limitations],['一般下一步',summary.next_steps]])appendTextList(details,title,items);
  if(details.childElementCount>1)container.append(details);return true;
 }
 const groups=compact?[['',summary.findings?.slice(0,2)]]:[['主要发现',summary.findings],['这份结果的范围',summary.limitations],['建议下一步',summary.next_steps]];
 for(const [title,items] of groups){if(!items?.length)continue;if(title)container.append(node('h4','',title));const list=node('ul','summary-list');for(const text of items)list.append(node('li','',text));container.append(list);}return true;
}
function boundedText(value,max=4000){return typeof value==='string'?value.length>max?value.slice(0,max)+'…':value:'';}
function appendTextList(parent,title,items,cls='summary-list'){
 if(!Array.isArray(items))return;const texts=items.slice(0,24).map(x=>boundedText(typeof x==='string'?x:x?.text)).filter(Boolean);if(!texts.length)return;
 if(title)parent.append(node('h4','',title));const list=node('ul',cls);for(const text of texts)list.append(node('li','',text));parent.append(list);
}
const evidenceScopes={current_call_declaration:'本次调用的可见声明',local_reference_comparison:'当前本地参考内的比较',contextual_reference_comparison:'条件有限的参考比较',recorded_service_observation:'记录中可见的服务处理',capture_limitation:'采集范围的限制',imported_report_claim:'导入报告的声明',assisted_observation:'模型辅助观察'};
const declarationScopes={not_observed:'尚未看到可核对的申报信息。',subject_model_declaration:'依据此对象记录中的型号声明。',controller_supplied_declaration:'依据本次控制器提交的型号声明。',visible_request_declaration:'依据可见请求字段中的型号声明。',subject_label_declaration:'依据记录为此对象标注的型号名称。'};
function evidenceSection(parent,title,items,cls){
 if(!Array.isArray(items)||!items.length)return;
 const section=node('section','evidence-category '+cls);section.append(node('h4','',title));
 for(const item of items.slice(0,24)){const text=boundedText(typeof item==='string'?item:item?.text);if(!text)continue;const row=node('div','evidence-observation');row.append(node('p','',text));
  if(item&&typeof item==='object'&&(item.scope||item.group||item.evidence_refs?.length)){const details=node('details','evidence-locator');details.append(node('summary','','范围与依据位置'));if(item.scope)details.append(node('p','hint',evidenceScopes[item.scope]||'适用范围：'+boundedText(item.scope,160)));if(item.group)details.append(node('p','hint','共享依据组：'+boundedText(item.group,180)+'；不据此增加独立票数。'));for(const ref of (Array.isArray(item.evidence_refs)?item.evidence_refs:[]).slice(0,16)){const pointer=boundedText(ref?.pointer,1024),record=boundedText(ref?.record_id,200);if(pointer||record)details.append(node('code','evidence-pointer',[pointer,record?'记录 '+record:''].filter(Boolean).join(' · ')));}row.append(details);}
  section.append(row);
 }
 parent.append(section);
}
function renderSynthesis(synthesis,parent){
 const section=node('section','synthesis');section.append(node('p','hint','以下按对象分别解释。支持与反对均针对“'+(boundedText(synthesis.hypothesis,300)||'相对申报型号存在偏离的弱线索')+'”，不代表模型好坏，也不合成型号概率。'));
 const labels=synthesis.category_labels||{};
 for(const subject of (Array.isArray(synthesis.subjects)?synthesis.subjects:[]).slice(0,32)){
  const card=node('article','subject-card'),conclusion=subject.conclusion||{};card.dataset.subjectId=boundedText(subject.subject_id,200);
  card.append(node('p','subject-label',boundedText(subject.label,500)||'当前检测对象'),node('h3','',boundedText(conclusion.title,500)||'当前观察范围'),node('p','subject-conclusion',boundedText(conclusion.text)));
  if(subject.declared_model)card.append(node('p','hint','申报型号：'+boundedText(subject.declared_model,300)));
  else card.append(node('p','hint','未明确申报型号；中性观察不自动变成支持或反对换型的判断。'));
  if(subject.claim_scope)card.append(node('p','hint',declarationScopes[subject.claim_scope]||'申报范围与绑定方式请以完整依据为准。'));
  if(conclusion.state==='demonstration')card.append(node('p','warning','演示或构造样本，不能用于认证真实送测模型。'));
  evidenceSection(card,'来源声明或绑定冲突',subject.source_conflicts,'source-conflicts');
  const columns=node('div','synthesis-columns');evidenceSection(columns,boundedText(labels.supporting,100)||'支持偏离的观察',subject.supporting,'supporting');evidenceSection(columns,boundedText(labels.counterevidence,100)||'反对偏离的观察',subject.counterevidence,'counterevidence');if(columns.childElementCount)card.append(columns);
  evidenceSection(card,boundedText(labels.observations,100)||'其他可用观察',subject.observations,'observations');
  const limits=node('div','synthesis-columns');evidenceSection(limits,boundedText(labels.alternatives,100)||'还可能有哪些解释',subject.alternatives,'alternatives');evidenceSection(limits,boundedText(labels.gaps,100)||'还缺哪些证据',subject.gaps,'gaps');if(limits.childElementCount)card.append(limits);
  section.append(card);
 }
 if(section.childElementCount===1)section.append(node('p','hint','当前没有可按对象整理的充分记录，请查看完整依据。'));
 parent.append(section);
}
function disableConsumedRecommendations(origin){for(const b of document.querySelectorAll('button[data-recommendation-origin]'))if(b.dataset.recommendationOrigin===origin){b.disabled=true;b.textContent='已派生后续任务';}}
function renderReportRecommendation(rec,parent,origin){
 if(!rec||rec.schema!=='tokenclock-next-detection/v1')return;
 const section=node('section','report-recommendation');section.append(node('h3','','下一步建议'),node('p','recommendation-lead',boundedText(rec.summary)));
 const state={recommended:'有可补充的检测',stop:'建议在当前范围停止',needs_configuration:'先明确对象与配置',review_first:'先复核已有依据'}[rec.status]||'建议尚不完整';section.append(node('span','small-badge',state));
 section.append(node('p','hint','报告所示剩余预算：待测 '+money(rec.remaining_budget_usd,'未知')+' · 评审 '+money(rec.remaining_judge_budget_usd,'未知')));
 appendTextList(section,'需要先处理',rec.stop_reasons);
 if(!['stop','review_first'].includes(rec.status))for(const action of (Array.isArray(rec.actions)?rec.actions:[]).slice(0,8)){
  const card=node('article','next-action');card.append(node('h4','',boundedText(action.title,400)||'补充检测'),node('p','',boundedText(action.reason)));
  const count=Number.isInteger(action.request_count)&&action.request_count>=0?String(action.request_count)+' 次待测请求':'请求次数待预览确认';card.append(node('p','hint',count+' · 此项完整预留 '+money(action.estimated_reserve_usd,'需配置后计算')));
  if(action.assessment_required)card.append(node('p','hint','部分内容需要模型解析，请另行选择解析连接与预算。不会自动开启解析。'));
  const apply=button('填入此方案',()=>applyReportRecommendation(origin,rec,action));apply.dataset.recommendationOrigin=origin;
  if(consumedRecommendations.has(origin)){apply.disabled=true;apply.textContent='已派生后续任务';}card.append(apply);section.append(card);
 }
 appendTextList(section,'推荐的范围',rec.notes);section.append(node('p','hint','这些方案是备选项。点击只回填方法和剩余预算；连接和密钥保持原样，预览并重新同意后才会发送。'));
 parent.append(section);
}
function applyReportRecommendation(origin,rec,action){
 if(!/^job-[a-f0-9]{32}$/.test(origin)||consumedRecommendations.has(origin))throw Error('该来源任务已派生后续任务或标识无效，请从后续结果继续。');
 if(!['recommended','needs_configuration'].includes(rec.status))throw Error('请先处理报告列出的停止或复核原因。');
 const patch=action.configuration_patch||{},workflow=patch.workflow_mode||action.workflow_mode,binding=publicBinding(rec.target_binding);
 if(rec.target_binding&&!binding)throw Error('报告的对象绑定不完整，请先核对完整依据。');
 if(!['l2','l3'].includes(workflow)||patch.transport_mode!=='live'||typeof action.id!=='string'||!action.id||action.id.length>200)throw Error('该建议不能直接回填，请手动选择检测方式。');
 const remaining=budgetValue(rec.remaining_budget_usd),judgeRemaining=budgetValue(rec.remaining_judge_budget_usd);
 for(const raw of [rec.remaining_budget_usd,rec.remaining_judge_budget_usd])if(raw!==null&&raw!==undefined&&budgetValue(raw)===null)throw Error('报告余额格式无效，请先核对费用记录。');
 if(remaining===0)throw Error('该报告的待测预算已用完，不追加付费任务。');
 const patchTarget=budgetValue(patch.provider?.max_cost_usd),patchJudge=budgetValue(patch.assessment?.provider?.max_cost_usd);
 const targetBudget=remaining===null?null:patchTarget===null?remaining:Math.min(remaining,patchTarget),judgeBudget=judgeRemaining===null?null:patchJudge===null?judgeRemaining:Math.min(judgeRemaining,patchJudge);
 let tasks=[],task=null,family=patch.family||action.family;
 if(workflow==='l2'){tasks=patch.task_ids||action.task_ids;if(!['openai','anthropic'].includes(family)||!Array.isArray(tasks)||tasks.length<1||tasks.length>5||new Set(tasks).size!==tasks.length||tasks.some(id=>!probeCatalog.some(t=>t.id===id&&t.layer==='L2'&&t.automatic_extraction==='supported')))throw Error('建议题目未被当前本地题库支持，请先查看完整依据。');}
 else{task=patch.task_id||action.task_id;if(!probeCatalog.some(t=>t.id===task&&t.layer==='L3'))throw Error('建议任务不在当前题库中。');}
 automaticReferenceFamily=false;autoReportJob=null;currentJobId=null;setScreen('setup');$('advanced-settings').open=false;resumeJob=null;$('resume-notice').hidden=true;clearConsents();
 $('workflow-mode').value=workflow;$('probe-mode').value='live';$('comparison-model').value='';$('judge-enabled').checked=false;$('external-enabled').checked=false;
 $('p-cost').value=targetBudget===null?'':String(targetBudget);$('j-cost').value=judgeBudget===null?'':String(judgeBudget);
 if(workflow==='l2'){$('probe-family').value=family;taskDrafts.set(family,tasks.slice());setFamily({reset:true});}else{$('heavy-task').value=task;$('program-interface').value='auto';}
 suggestion={origin,id:action.id,title:boundedText(action.title,400)||'补充检测',reason:boundedText(action.reason),binding,confirmedBinding:'',targetBudget,judgeBudget,workflow,tasks:tasks.slice(),task};
 updateWorkflow();renderSource();$('configuration').scrollIntoView({behavior:'smooth',block:'start'});
}
async function showReport(id,hasEvidence=false){
 if(shownReportId!==id){invalidate();shownReportId=id;}
 currentJobId=id;setScreen('result');const gen=++reportGeneration,base='reports/'+encodeURIComponent(id)+'/';$('result-details').open=false;$('report-evidence').hidden=false;renderBriefResult({title:'正在读取结果',summary:'请稍候。',reasons:[],caveat:'',next_action:{kind:'none'}},null,id);$('report-summary').replaceChildren(node('p','hint','正在读取详细依据…'));$('report-evidence').open=false;$('report-frame').src=base+'report.html';const links=$('report-links');links.replaceChildren();
 for(const [name,label] of [['report.html','保存 HTML 报告'],['report.json','保存结果 JSON'],['observation.json','保存原始观察']]){const a=node('a','',label);a.href=base+name+'?download=1';a.download=name;links.append(a);}
 if(hasEvidence){const a=node('a','','下载原始证据');a.href=base+'evidence.zip';a.download='evidence.zip';links.append(a);}
 const support=node('a','','保存问题摘要');support.href='support/'+encodeURIComponent(id);support.download='model-detect-support.json';links.append(support);
 const full=node('a','','独立打开完整报告');full.href=base+'report.html';full.target='_blank';full.rel='noopener';links.append(full);
 $('report-panel').scrollIntoView({behavior:'smooth',block:'start'});
 try{const report=await api(base+'report.json');if(gen!==reportGeneration)return;renderBriefResult(report.user_summary?.brief?.schema==='tokenclock-result-brief/v1'?report.user_summary.brief:conservativeBrief(report),report,id);$('report-summary').replaceChildren();if(!renderSummary(report.user_summary,$('report-summary')))$('report-summary').append(node('p','','此报告请以原始记录为准。'));renderReportRecommendation(report.user_summary?.recommendation,$('report-summary'),id);}
 catch(error){if(gen===reportGeneration){renderBriefResult({title:'暂时无法读取结果',summary:'检测记录仍在本机，可稍后重试或展开详情。',reasons:[],caveat:'读取失败不是模型表现结论。',next_action:{kind:'none'}},null,id);$('report-summary').replaceChildren(node('p','error','报告暂未读取成功，可在下方打开完整文件。'));}}
}
function jobTitle(j){const c=j.semantic_config||{},source=j.source_name||j.source_path||j.original_source||j.input_name||j.source?.name||j.id;const title={l2:'轻量短题 · '+(c.family==='anthropic'?'Claude':'OpenAI')+' 参考',l3:'交付核验 · '+(c.task_id||'完整任务'),diagnostics:'服务记录检查',combined:'综合观察报告'}[c.workflow_mode];return title?title+' · '+({live:'真实 API',artifact:'已有文件',replay:'回放',demo:'演示'}[c.transport_mode]||'本地'):String(source).split(/[\\/]/).pop();}
function billingLine(t){return '已报告 '+money(t.reported_actual_cost_usd,'未提供')+' · 估算 '+money(t.estimated_only_cost_usd,'未提供')+' · 未结预留 '+money(t.pending_reserved_cost_usd,'未提供');}
function renderJob(j){
 const item=node('article','item job-item'),content=node('div','item-content'),actions=node('div','item-actions');item.dataset.jobId=j.id;const title=jobTitle(j),p=j.progress||{},cfg=j.semantic_config||{};
 content.append(node('div','item-title',title),node('div','item-meta',[statuses[j.status]||j.status,stages[p.stage||j.stage]||p.message||j.message||'',j.comparison_model?'比较 '+j.comparison_model:''].filter(Boolean).join(' · ')));
 if(j.user_summary)renderSummary(j.user_summary,content,{compact:true});
 else if(j.status==='completed')content.append(node('p','hint',j.report_summary?.full_task_pass===false?'部分检查未通过或未核验。请查看具体发现。':'结果已经保存，请查看主要发现与证据范围。'));
 if(j.error)content.append(node('p','error',typeof j.error==='string'?j.error:j.error.message||'检测未完成。'));
 if(['failed','interrupted','action_required'].includes(j.status))content.append(node('p','hint','先检查配置与已有费用，再决定是否重试；重试不会把旧费用清零。'));
 if(j.status==='cancelled')content.append(node('p','hint','已停止新增请求。已发出的请求仍可能产生费用，完成记录与未结费用会保留。'));
 const by=j.probe_billing?.by_purpose;
 if(by){for(const role of ['target','judge'])if(by[role])content.append(node('p','billing-line',(role==='target'?'待测':'评审')+' · '+(by[role].requests??0)+' 次 · '+billingLine(by[role])));}
 else{const t=j.probe_billing?.totals||j.semantic_billing?.totals;if(t)content.append(node('p','billing-line',billingLine(t)));}
 if(!terminal.has(j.status)){const progress=node('progress');progress.max=1;if(typeof p.fraction==='number')progress.value=p.fraction;content.append(progress);actions.append(button('查看进度',()=>{currentJobId=j.id;autoReportJob=j.id;setScreen('progress');renderCurrentProgress(j);},'progress'),button('停止',async()=>{await api('api/jobs/'+j.id+'/cancel',{});await refreshJobs();},'cancel'));}
 if(j.partial_directory){content.append(node('p','warning','已有部分证据可用；此任务没有完整报告。'));const a=node('a','quiet-link','下载部分证据');a.href='partial-evidence/'+encodeURIComponent(j.id);a.download='partial-evidence.zip';actions.append(a);}
 if(j.status==='completed'){actions.append(button('查看发现',()=>showReport(j.id,!!cfg.workflow_mode&&cfg.workflow_mode!=='l1'),'report'));const label=node('label','check combine-check'),box=node('input');box.type='checkbox';box.checked=selectedReports.has(j.id);box.setAttribute('aria-label','加入合并 '+title);box.addEventListener('change',()=>box.checked?selectedReports.add(j.id):selectedReports.delete(j.id));label.append(box,node('span','','合并'));actions.append(label);}
 if(['failed','cancelled','interrupted','action_required'].includes(j.status))actions.append(button('检查配置后重试',()=>configureResume(j),'resume'));
 item.append(content,actions);return item;
}
async function refreshJobs(){
 if(refreshing)return;refreshing=true;
 try{const data=await api('api/jobs'),list=$('jobs'),seen=new Set();for(const j of data.jobs||[]){seen.add(j.id);jobRecords.set(j.id,j);for(const origin of [j.recommendation_origin_job_id,j.recommendation_child_job_id?j.id:null])if(origin){consumedRecommendations.add(origin);disableConsumedRecommendations(origin);}const signature=JSON.stringify(j),old=jobElements.get(j.id);let row=old?.element;if(!old||old.signature!==signature){const focused=old?.element.contains(document.activeElement)?document.activeElement.dataset.action:null;row=renderJob(j);if(old)old.element.replaceWith(row);jobElements.set(j.id,{signature,element:row});if(focused)row.querySelector('[data-action="'+focused+'"]')?.focus({preventScroll:true});}list.append(row);renderCurrentProgress(j);if(autoReportJob===j.id&&terminal.has(j.status)){autoReportJob=null;if(j.status==='completed')showReport(j.id,!!j.semantic_config?.workflow_mode&&j.semantic_config.workflow_mode!=='l1');else showStoppedResult(j);}}
  for(const [id,value]of jobElements)if(!seen.has(id)){value.element.remove();jobElements.delete(id);selectedReports.delete(id);}for(const empty of list.querySelectorAll('.empty'))empty.remove();if(!seen.size)list.append(node('p','empty','还没有检测任务。先选择一份内容，预览后开始。'));
 }catch(error){showError(error);}finally{refreshing=false;updateStart();}
}
function loadProvider(role,p={}){if(role==='p')$('p-identity').open=true;const f=roleFields[role];for(const [name,key]of [['endpoint','endpoint'],['model','model'],['format','api_format'],['input','input_usd_per_million'],['output','output_usd_per_million']])$(f[name]).value=p[key]??(name==='format'?'chat_completions':'');$(f.key).value='';$(f.key).placeholder='重试前请重新选择连接或输入密钥';selectedConnections[role]=null;if($(role+'-connection'))$(role+'-connection').value='';$(role+'-manual').open=true;}
function configureResume(j){
 automaticReferenceFamily=false;autoReportJob=null;currentJobId=null;reportGeneration++;setScreen('setup');$('advanced-settings').open=false;clearSuggestion();
 const c=j.semantic_config||{};resumeJob=j;$('resume-notice').hidden=false;$('resume-description').textContent='准备重试「'+jobTitle(j)+'」。沿用原内容快照，先检查配置与剩余预算。';
 $('workflow-mode').value=c.workflow_mode||'l1';$('probe-mode').value=c.transport_mode||'artifact';if(c.family)$('probe-family').value=c.family;if(c.task_id)$('heavy-task').value=c.task_id;$('comparison-model').value=j.comparison_model||'';
 $('external-enabled').checked=c.external?.enabled===true;$('judge-enabled').checked=c.assessment?.enabled===true;
 $('j-source').value=c.assessment?.connection_source||'separate';$('j-batch-once').checked=c.assessment?.batch_once===true;
 if(c.task_ids){taskDrafts.set(c.family||'openai',c.task_ids);setFamily({reset:true});}
 if(c.provider){loadProvider('p',c.provider);$('p-cost').value=c.provider.max_cost_usd??'';$('p-wall').value=c.provider.wall_seconds??900;}
 if(c.assessment?.provider){loadProvider('j',c.assessment.provider);$('j-cost').value=c.assessment.provider.max_cost_usd??'';$('j-repeats').value=c.assessment.repeats??2;$('j-output-limit').value=c.assessment.provider.max_output_tokens??24576;$('j-detail').value=c.assessment.provider.image_detail||'';$('j-image-tokens').value=c.assessment.provider.image_tokens_upper_per_image??'';}
 if(c.external){loadProvider('l',c.external);$('max-cost').value=c.external.max_cost_usd??'';$('max-output').value=c.external.max_output_tokens??4096;}
 const e=c.evaluation||{};$('program-interface').value=e.interface?.mode||'auto';$('node-path').value=e.node_path||'';$('node-modules-path').value=e.node_modules_path||'';
 updateJudgeControls({restoring:true});updateWorkflow();renderSource();$('configuration').scrollIntoView({behavior:'smooth',block:'start'});
}
function leaveResume(){resumeJob=null;$('resume-notice').hidden=true;renderSource();updateWorkflow();}
function protocolNote(role){const format=$(role+'-format').value;$(role+'-protocol-note').textContent=({responses:'通常以 /v1/responses 结尾；请以服务商文档为准。',messages:'通常以 /v1/messages 结尾；适用于 Anthropic Messages 协议。',chat_completions:'通常以 /v1/chat/completions 结尾；型号仍须填写该渠道的精确 ID。'})[format]||'';}
function addModelCatalog(role){
 const f=roleFields[role],group=node('div','catalog-panel'),select=node('select'),note=node('p','hint');select.id=role+'-catalog-model';note.id=role+'-catalog-note';select.hidden=true;select.setAttribute('aria-label','从目录选择型号');
 const read=button('读取型号与报价',async()=>{
  const endpoint=role==='j'?judgeEndpoint():$(f.endpoint).value.trim();if(!endpoint)throw Error('请先填写或选择完整接口地址。');
  const data=await api('api/model-catalog',{endpoint});if((role==='j'?judgeEndpoint():$(f.endpoint).value.trim())!==endpoint)throw Error('接口地址已改变，请重新读取目录。');modelCatalogs[role]={endpoint,data};select.replaceChildren();const blank=node('option','','选择目录中的型号，不会自动调用');blank.value='';select.append(blank);
  for(const m of data.models||[]){const option=node('option','',m.id+(m.pricing_available?'':' · 需手填单价'));option.value=m.id;select.append(option);}select.hidden=false;
  note.textContent='已读取公开目录'+(data.observed_at?' · '+data.observed_at:'')+'。尚未选择型号；目录报价用于费用预留，请核对服务计费。';
 });
 select.addEventListener('change',()=>{const catalog=modelCatalogs[role];if(!catalog||catalog.endpoint!==(role==='j'?judgeEndpoint():$(f.endpoint).value.trim()))return;const m=catalog.data.models?.find(m=>m.id===select.value);if(!m)return;$(f.model).value=m.id;$(f.model).dispatchEvent(new Event('input',{bubbles:true}));$(f.input).value=m.input_usd_per_million??'';$(f.output).value=m.output_usd_per_million??'';if(role==='p'&&sharedJudge()&&judgeTargetFollows)useTargetModel();note.textContent=(m.pricing_note||'目录报价用于费用预留，请核对服务计费。')+(catalog.data.observed_at?' · 读取时间 '+catalog.data.observed_at:'')+(m.pricing_available?'':' 缺少报价，已清空旧单价，请手动填写。');invalidate();});
 group.append(read,select,note);$(f.model).after(group);
 $(f.endpoint).addEventListener('input',()=>{delete modelCatalogs[role];select.hidden=true;note.textContent='';});
}
async function initializeConnections(){
 for(const role of ['p','j','l']){
  const f=roleFields[role],group=node('div','connection-panel'),label=node('label','field-label','已保存的连接');label.htmlFor=role+'-connection';const select=node('select');select.id=role+'-connection';
  $(f.key).addEventListener('input',()=>{typedKeyBindings[role]=credentialBinding(role);});
  select.addEventListener('change',()=>{const profile=connectionProfiles.find(p=>p.id===select.value);selectedConnections[role]=profile?.id||null;if(profile){for(const [field,key]of [['endpoint','endpoint'],['model','model'],['format','api_format'],['input','input_usd_per_million'],['output','output_usd_per_million']])$(f[field]).value=profile[key]??'';$(f.key).value='';$(f.key).placeholder=profile.credential_state==='needs_key'?'此连接需要重新输入密钥':'使用已保存密钥，不在页面回显';$(role+'-manual').open=profile.credential_state==='needs_key';}else{$(role+'-manual').open=true;$(f.key).placeholder='请填写本次密钥';}if(role==='p'&&sharedJudge()){if(judgeTargetFollows)useTargetModel();else{$('j-input').value='';$('j-output').value='';clearJudgeCatalog();}}if(role==='p'){$('p-identity').open=!profile||profile.credential_state==='needs_key';syncReferenceFamily();}if(role!=='l')protocolNote(role);invalidate();});
  const details=node('details');details.append(node('summary','','保存与管理连接'));const name=node('input');name.id=role+'-connection-name';name.placeholder='连接名称';name.maxLength=80;name.setAttribute('aria-label','连接名称');const storage=node('select');storage.id=role+'-connection-storage';storage.setAttribute('aria-label','密钥保存方式');const session=node('option','','密钥仅留在本次会话');session.value='session';storage.append(session);
  details.append(name,storage,button('保存为新连接',async()=>{const p=provider(role);if(p.input_usd_per_million===null||p.output_usd_per_million===null)throw Error('保存前请填写当前渠道单价。');const value={name:name.value,endpoint:p.endpoint,api_format:p.api_format,model:p.model,api_key:p.api_key,secret_storage:storage.value,input_usd_per_million:p.input_usd_per_million,output_usd_per_million:p.output_usd_per_million};const saved=await api('api/connections',value);await refreshConnections();select.value=saved.profile.id;select.dispatchEvent(new Event('change'));name.value='';}),button('删除所选连接',async()=>{if(!select.value)throw Error('请先选择一个已保存连接。');await api('api/connections/delete',{id:select.value});selectedConnections[role]=null;await refreshConnections();invalidate();}),node('p','hint','保存连接不发送模型请求，也不会同意后续任务的费用。接口与单价保存在本机；密钥可仅留内存。'));
  group.append(label,select);if(role==='p')$('connection-management').append(details);else group.append(details);$(role+'-connection-slot').append(group);
  for(const field of ['endpoint','model','format'])$(f[field]).addEventListener('input',()=>{if(selectedConnections[role]&&!(role==='j'&&sharedJudge())){selectedConnections[role]=null;select.value='';$(f.key).value='';$(f.key).placeholder='连接信息已改变，请重新输入密钥';}$(f.input).value='';$(f.output).value='';$(f.input).placeholder='接口或型号已改变，请重新核对';$(f.output).placeholder='接口或型号已改变，请重新核对';if(role==='p'&&sharedJudge()){if(judgeTargetFollows)useTargetModel();else{$('j-input').value='';$('j-output').value='';clearJudgeCatalog();}}if(role==='p')syncReferenceFamily();if(role!=='l')protocolNote(role);});
  if(role!=='l')addModelCatalog(role);
 }
 try{await refreshConnections();}catch(error){showError(error);}
}
async function refreshConnections(){
 const data=await api('api/connections');connectionProfiles=data.profiles||[];$('p-connection-slot').hidden=!connectionProfiles.length;
 for(const role of ['p','j','l']){const select=$(role+'-connection'),old=select.value;select.replaceChildren();const fresh=node('option','','手工填写本次连接');fresh.value='';select.append(fresh);for(const p of connectionProfiles.filter(p=>role!=='l'||p.api_format==='chat_completions')){const option=node('option','',p.name+' · '+p.model+(p.credential_state==='needs_key'?' · 需密钥':''));option.value=p.id;select.append(option);}select.value=[...select.options].some(o=>o.value===old)?old:'';if(!select.value)selectedConnections[role]=null;const storage=$(role+'-connection-storage');if(data.system_secret_storage&&!storage.querySelector('[value="keychain"]')){const option=node('option','','密钥保存到系统钥匙串');option.value='keychain';storage.append(option);}}
}
async function loadReadiness(){try{const data=await api('api/info'),c=data.capabilities||{},missing=[];if(!c.h01_h03_isolation_available)missing.push('程序隔离');if(!c.h02_browser_available)missing.push('交互网页');if(!c.h04_svg_renderer_available)missing.push('SVG 渲染');$('runtime-readiness').textContent=missing.length?'目前缺少：'+missing.join('、')+'。相关内容会保留为未核验，其他检测可以继续。':'本地会话、程序、交互与视觉核验环境已就绪。每份结果仍按实际完成情况记录。';}catch(error){$('runtime-readiness').textContent='暂时无法读取环境状态。启动前预览会检查本次所需条件。';}}
async function loadCatalog(){try{const data=await api('api/probes');probeCatalog=data.tasks||[];syncReferenceFamily();setFamily({reset:true});updateWorkflow({changed:false});}catch(error){showError(error);}}
for(const kind of ['session','api','file'])$('intent-'+kind).addEventListener('click',()=>selectIntent(kind));
$('workflow-mode').addEventListener('change',()=>{resumeJob=null;$('resume-notice').hidden=true;updateWorkflow();});$('probe-mode').addEventListener('change',()=>{resumeJob=null;$('resume-notice').hidden=true;updateWorkflow();});
$('probe-depth').addEventListener('change',()=>{$('workflow-mode').value=$('probe-depth').value;updateWorkflow();});$('heavy-task').addEventListener('change',()=>updateWorkflow());
$('probe-family').addEventListener('change',()=>{automaticReferenceFamily=false;setFamily();invalidate();});
$('judge-enabled').addEventListener('change',()=>{$('judge-fields').hidden=!$('judge-enabled').checked;updateJudgeControls();setFamily();invalidate();updateRecommendation();});
$('j-source').addEventListener('change',()=>{updateJudgeControls();invalidate();});
$('j-batch-once').addEventListener('change',()=>{updateJudgeControls();invalidate();});
$('j-use-target').addEventListener('click',()=>{if(sharedJudge()){useTargetModel();invalidate();}});
for(const id of ['j-model','j-input','j-output'])$(id).addEventListener('input',()=>{if(sharedJudge())judgeTargetFollows=false;});
for(const id of ['p-input','p-output'])$(id).addEventListener('input',()=>{if(sharedJudge()&&judgeTargetFollows)useTargetModel();});
$('external-enabled').addEventListener('change',()=>{$('external-fields').hidden=!$('external-enabled').checked;invalidate();});
$('choose-file').addEventListener('click',()=>$('session-file').click());
$('session-file').addEventListener('change',()=>{const file=$('session-file').files[0];if(!file)return;source={path:'',name:file.name,file,uploadedPath:null};$('source-path').value='';$('selected-source').textContent='待导入：'+file.name;$('choose-file').textContent='更换文件';invalidate();});
$('source-path').addEventListener('input',()=>{source={path:$('source-path').value.trim(),name:'',file:null,uploadedPath:null};$('session-file').value='';$('selected-source').textContent=source.path?'已填写本地路径':'尚未选择文件';});
$('configuration').addEventListener('input',event=>{if(!['session-file','source-path'].includes(event.target.id)&&!event.target.id?.includes('connection-name'))invalidate();else if(event.target.id==='source-path')invalidate();});
$('configuration').addEventListener('change',event=>{if(event.target.tagName==='SELECT'&&!['workflow-mode','probe-mode','probe-depth','probe-family','heavy-task'].includes(event.target.id))invalidate();});
for(const id of ['p-consent','j-consent','allow-external'])$(id).addEventListener('change',updateStart);
$('prepare').addEventListener('click',prepare);$('start').addEventListener('click',start);$('refresh-sessions').addEventListener('click',refreshSessions);$('refresh-jobs').addEventListener('click',refreshJobs);$('leave-resume').addEventListener('click',leaveResume);
$('recent-session-select').addEventListener('change',()=>{if($('recent-session-select').value==='__more__'){$('advanced-settings').open=true;$('source-path-details').open=true;$('recent-session-select').value='';return;}const picked=sessionChoices.find(x=>x.path===$('recent-session-select').value);if(picked)choose(picked.path,picked.name);});
$('cancel-current').addEventListener('click',async()=>{if(!currentJobId)return;$('cancel-current').disabled=true;try{await api('api/jobs/'+currentJobId+'/cancel',{});await refreshJobs();}catch(error){showError(error);$('cancel-current').disabled=false;}});
$('open-reference-settings').addEventListener('click',()=>{$('advanced-settings').open=true;$('l2-settings').scrollIntoView({behavior:'smooth',block:'center'});});
$('confirm-reference-family').addEventListener('click',()=>{automaticReferenceFamily=false;setFamily();invalidate();});
$('confirm-suggestion-connection').addEventListener('click',()=>{if(suggestion&&!suggestion.binding&&currentBinding()){suggestion.confirmedBinding=bindingKey(currentBinding());invalidate();}});
$('clear-suggestion').addEventListener('click',()=>{clearSuggestion();updateWorkflow({changed:false});invalidate();});
$('back-to-configuration').addEventListener('click',returnToSetup);
$('combine-jobs').addEventListener('click',async()=>{try{if(selectedReports.size<2)throw Error('请至少选择两份已完成报告。');const job=await api('api/combine',{job_ids:[...selectedReports]});selectedReports.clear();autoReportJob=job.id;currentJobId=job.id;setScreen('progress');renderCurrentProgress(job);await refreshJobs();}catch(error){showError(error);}});
window.addEventListener('tokenclock:model-detect-prefill',event=>{const detail=event.detail||{};if(typeof detail.source_path!=='string'||!detail.source_path.startsWith('/')||detail.source_path.length>8192)return;selectIntent('session');choose(detail.source_path);});
setScreen('setup');updateWorkflow({changed:false});protocolNote('p');protocolNote('j');initializeConnections();loadCatalog();refreshSessions();refreshJobs();loadReadiness();setInterval(()=>{if(!document.hidden)refreshJobs();},1500);
