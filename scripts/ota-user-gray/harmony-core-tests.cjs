const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');
const crypto = require('node:crypto');
const repoRoot = path.resolve(__dirname, '../..');
const ts = require(path.join(repoRoot, 'playground/node_modules/typescript'));
const root = path.join(repoRoot, 'harmony/lynx_shell_kit/src/main/ets/ota');
const cache = new Map();
const openPaths = new Map();
let remoteRequestCount = 0;
let afterFileSync;
function load(name) {
  if(cache.has(name)) return cache.get(name).exports;
  const file = path.resolve(root, name + '.ets');
  const mod = {exports:{}}; cache.set(name,mod);
  const js = ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const localRequire = id => id.startsWith('.') ? load(path.relative(root,path.resolve(path.dirname(file),id))) : platform(id);
  vm.runInThisContext(`(function(require,module,exports){${js}\n})`,{filename:file})(localRequire,mod,mod.exports);
  return mod.exports;
}
function platform(id) {
  if(id==='@lynx/lynx')return {LynxTemplateResourceFetcher:class {}};
  if(id==='@ohos.url')return {default:{URL:{parseURL:raw=>new URL(raw)}}};
  if(id==='@ohos.resourceManager')return {default:{}};
  if(id==='@kit.AbilityKit')return {};
  if(id==='@kit.CoreFileKit')return {statfs:{getFreeSizeSync:()=>2**40}};
  if(id==='@ohos.file.fs')return {default:{
    OpenMode:{READ_ONLY:fs.constants.O_RDONLY,WRITE_ONLY:fs.constants.O_WRONLY,CREATE:fs.constants.O_CREAT,TRUNC:fs.constants.O_TRUNC,NOFOLLOW:fs.constants.O_NOFOLLOW,DIR:fs.constants.O_DIRECTORY},
    accessSync:fs.existsSync,mkdirSync:(p,r)=>fs.mkdirSync(p,{recursive:r}),readTextSync:p=>fs.readFileSync(p,'utf8'),
    openSync:(p,f)=>{const fd=fs.openSync(p,f);openPaths.set(fd,p);return {fd};},closeSync:f=>{const fd=typeof f==='number'?f:f.fd;openPaths.delete(fd);fs.closeSync(fd);},
    writeSync:(fd,data)=>fs.writeSync(fd,typeof data==='string'?data:Buffer.from(data)),fsyncSync:fd=>{fs.fsyncSync(fd);afterFileSync?.(openPaths.get(fd));},
    readSync:(fd,data)=>fs.readSync(fd,Buffer.from(data)),renameSync:fs.renameSync,moveFileSync:fs.renameSync,
    statSync:fs.statSync,lstatSync:fs.lstatSync,listFileSync:fs.readdirSync,unlinkSync:fs.unlinkSync,rmdirSync:fs.rmdirSync,
  }};
  if(id==='@ohos.util')return {default:{TextDecoder:TextDecoder}};
  if(id==='@kit.LocalizationKit')return {i18n:{System:{getSystemLocale:()=> 'zh-CN',getSystemLanguage:()=> 'zh'}}};
  if(id==='@kit.ArkData')return {preferences:{getPreferencesSync:()=>{const values=new Map();return {
    getSync:(key,fallback)=>values.get(key)??fallback,putSync:(key,value)=>values.set(key,value),
    deleteSync:key=>values.delete(key),flushSync:()=>{} };}}};
  if(id==='@ohos.security.cryptoFramework')return {default:{createMd:()=>{const h=crypto.createHash('sha256');return {updateSync:x=>h.update(x.data),digestSync:()=>({data:new Uint8Array(h.digest())})};},createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(crypto.randomBytes(n))})})}};
  if(id==='@ohos.net.http')return {default:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'string',ARRAY_BUFFER:'arraybuffer'},createHttp:()=>{remoteRequestCount++;const controller=new AbortController();return {request:async(url,options)=>{const r=await fetch(url,{headers:options.header,signal:controller.signal});return {responseCode:r.status,header:Object.fromEntries(r.headers),result:options.expectDataType==='arraybuffer'?await r.arrayBuffer():await r.text()};},destroy:()=>controller.abort()};}}};
  throw new Error('Unsupported test platform adapter: '+id);
}
const Json = load('OtaJson').default;
const Models = load('OtaModels');
const selected = {env:'TEST',hostApp:'capp',lynxAppId:'10000001',releaseId:'full5',platform:'harmony',status:'ACTIVE',changedBundles:[],selectionSchemaVersion:1,releaseSequence:'9007199254740993',selection:{kind:'full',policyRevision:'9007199254740994',reason:'latest_full'}};
test('OTA template fetcher blocks undeclared HTTPS async request without network',()=>{
  const Fetcher=load('../provider/ShellTemplateResourceFetcher').default;
  const rootUrl='https://example.invalid/main.lynx.bundle';
  const rootBytes=Uint8Array.from([1,2,3]).buffer;
  const resolver={isDeclared:key=>key==='/lazy-bundle/known.bundle',resolveBytes:()=>Uint8Array.from([4,5]).buffer};
  const fetcher=new Fetcher(false,rootUrl,'','',rootBytes,resolver);
  const before=remoteRequestCount;
  let root;
  fetcher.fetchTemplate({url:rootUrl},(error,result)=>{assert.equal(error,undefined);root=result.binary;});
  assert.deepEqual([...new Uint8Array(root)],[1,2,3]);
  let known;
  fetcher.fetchTemplate({url:'/lazy-bundle/known.bundle'},(error,result)=>{assert.equal(error,undefined);known=result.binary;});
  assert.deepEqual([...new Uint8Array(known)],[4,5]);
  let rejected;
  fetcher.fetchTemplate({url:'https://example.invalid/unknown.lynx.bundle'},(error,result)=>{rejected=error;assert.equal(result.binary.byteLength,0);});
  assert.equal(rejected.code,1107);
  assert.equal(remoteRequestCount,before);
});
test('主 Store 与附属资源事务遇到随机 token 冲突时不会复用目录',t=>{
  const f=fixture(t);
  const original=crypto.randomBytes;
  let issued=0;
  crypto.randomBytes=(size)=>size===16 && issued++<2?Buffer.alloc(16,0x5a):original(size);
  try {
    const first=f.store.createTransactionDirectory('10000001');
    const second=f.store.createTransactionDirectory('10000001');
    assert.notEqual(first,second);
    issued=0;
    const sidecar=f.store.sidecars;
    const a=sidecar.beginTransaction('10000001','async-bundles','sha256:'+'1'.repeat(64),[]);
    const b=sidecar.beginTransaction('10000001','async-bundles','sha256:'+'2'.repeat(64),[]);
    assert.notEqual(a,b);
    assert.notEqual(fs.readFileSync(path.join(a,'transaction.json'),'utf8'),fs.readFileSync(path.join(b,'transaction.json'),'utf8'));
  } finally {crypto.randomBytes=original;}
});
test('batch wire retains directive separately from selected release',()=>{
  const response=Json.parseLatestLists(JSON.stringify({selectionSchemaVersion:1,env:'TEST',hostApp:'capp',platform:'harmony',bundleLists:[selected],directives:[{lynxAppId:'10000002',action:'use_embedded',policyRevision:'99',reason:'forced'}]}));
  assert.equal(response.directives?.[0]?.action,'use_embedded');
  assert.equal(response.bundleLists[0].releaseSequence,'9007199254740993');
});
test('malformed directive container cannot silently become empty',()=>{
  assert.throws(()=>Json.parseLatestLists(JSON.stringify({selectionSchemaVersion:1,env:'TEST',hostApp:'capp',platform:'harmony',bundleLists:[selected],directives:{}})));
});
test('Harmony query platform never uses legacy Android compatibility override',()=>{
  const config=new Models.LynxOtaConfig('https://example.invalid'); config.serverPlatform='android';
  assert.equal(config.requestPlatform(),'harmony');
});

function fixture(t,userId='A',code='25') {
  const directory=fs.mkdtempSync('/tmp/lynx-harmony-selection-');
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  const config=new Models.LynxOtaConfig('https://example.invalid');
  Object.assign(config,{storageDirectory:directory,environment:'TEST',versionCode:code,lynxSdkVersion:code===undefined?undefined:'4.0.0',userId:code===undefined?undefined:userId});
  const Box=load('OtaUserContext').OtaUserContextBox; const box=new Box(config);
  const api={count:0,bindUserContext(){}, async downloadBundle(url){this.count++;return Buffer.from(url.split('/').at(-1)).buffer.slice(0,0);}};
  const data=new Map(); api.downloadBundle=async function(url){this.count++;if(!data.has(url))throw new Error('download_failed');const b=data.get(url);return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength);};
  const catalogs=new Map();api.fetchLatestI18nCatalog=async function(appId,version){const catalog=catalogs.get(version);if(!catalog||catalog.lynxAppId!==appId)throw new Error('catalog_missing');return structuredClone(catalog);};
  const Store=load('ContentAddressedOtaStore').default;const store=new Store(config,api,box);
  function release(id,kind='full',revision='1',body=id,app='10000001') {
    const bytes=Buffer.from(body);const url='https://example.invalid/'+id;data.set(url,bytes);
    return {...selected,lynxAppId:app,releaseId:id,releaseSequence:revision,selection:{kind,ruleId:kind==='gray'?'rule':undefined,policyRevision:revision,reason:kind==='gray'?'matched_gray':'latest_full'},changedBundles:[{pageId:1,bundlePath:'main.lynx.bundle',bundleSha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),bundleUrl:url,size:bytes.length}]};
  }
  return {config,box,api,data,catalogs,store,release,signal:{throwIfCancelled(){}},directory};
}
function state(f,app='10000001'){return JSON.parse(fs.readFileSync(path.join(f.directory,'apps',app,'state.json'),'utf8'));}
function current(f,context=f.box.capture(),app='10000001'){const p=f.store.acquireCurrentBundleLease(app,'main.lynx.bundle',context);p?.lease?.close();return p;}
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
test('A installed gray cannot be read by B before reconcile; full previous still usable',async t=>{
  const f=fixture(t);await f.store.install(f.release('full'),f.signal,f.box.capture());
  await f.store.install(f.release('gray','gray','2'),f.signal,f.box.capture());
  f.box.register('B');const read=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(read.releaseId,'full');read.lease.close();
});
test('registration after captured A refuses State commit even when release is full',async t=>{
  const f=fixture(t);const context=f.box.capture();f.box.register('B');
  await assert.rejects(f.store.install(f.release('old'),f.signal,context),/stale_identity/);
  assert.equal(fs.existsSync(path.join(f.directory,'apps/10000001/state.json')),false);
});
test('normalizers retain exact large decimals and reject raw controls before trim',()=>{
  const C=load('OtaUserContext').OtaUserContext;
  assert.equal(C.normalizeUserId('  A  '),'A');assert.equal(C.normalizeUserId('　'),undefined);
  assert.throws(()=>C.normalizeUserId('\nA'));assert.throws(()=>C.normalizeUserId('a'.repeat(257)));
  assert.equal(C.normalizeUserId('é'.repeat(128)).length,128);
  assert.equal(C.normalizeVersionCode(' 009223372036854775807 '),'9223372036854775807');
  for(const value of ['0','-1','1.2','9223372036854775808','９'])assert.throws(()=>C.normalizeVersionCode(value));
  assert.equal(C.compareDecimal('9007199254740993','9007199254740992'),1);
  assert.equal(C.compareDecimal('100','99'),1);assert.equal(C.compareDecimal('009','9'),0);
  assert.equal(C.normalizeLynxSdkVersion(' 04.00 '),'4.0.0');assert.throws(()=>C.normalizeLynxSdkVersion('4.0-beta'));
  assert.equal(C.compareVersion('4.9007199254740993.0','4.9007199254740992.0'),1);
});
test('same normalized registration is no-op and invalidation also advances anonymous epoch',t=>{
  const f=fixture(t);const a=f.box.capture();assert.equal(f.box.register(' A '),false);assert.equal(f.box.identityEpoch,0);
  assert.equal(f.box.register(undefined),true);const anon=f.box.capture();f.box.invalidate();assert.equal(f.box.identityEpoch,2);
  assert.throws(()=>f.box.validate(a),/stale_identity/);assert.throws(()=>f.box.validate(anon),/stale_identity/);
  assert.throws(()=>f.box.capture(1),/stale_identity/);assert.equal(f.box.capture().userId,undefined);
});
test('C05 gray only becomes null for offline B, no raw ID is persisted',async t=>{
  const f=fixture(t,'synthetic-private-user');await f.store.install(f.release('gray','gray'),f.signal,f.box.capture());
  f.box.register('B');assert.equal(current(f),null);f.store.reconcileUserContext(f.box.capture());assert.equal(current(f),null);
  assert.equal(JSON.stringify(state(f)).includes('synthetic-private-user'),false);
  assert.equal(fs.existsSync(path.join(f.directory,'users')),false);
});
test('C08 same release full promotion updates metadata without download and survives anonymous cold read',async t=>{
  const f=fixture(t);const gray=f.release('same','gray');await f.store.install(gray,f.signal,f.box.capture());
  await f.store.install({...gray,selection:{kind:'full',policyRevision:'2',reason:'latest_full'}},f.signal,f.box.capture());
  assert.equal(f.api.count,1);assert.equal(state(f).current.selection.kind,'full');
  f.config.userId=undefined;const box=new (load('OtaUserContext').OtaUserContextBox)(f.config);const store=new (load('ContentAddressedOtaStore').default)(f.config,f.api,box);
  const p=store.acquireCurrentBundleLease('10000001','main.lynx.bundle',box.capture());assert.equal(p.releaseId,'same');p.lease.close();
});
test('C11 anonymous cold gray and old unknown State do not become full implicitly',async t=>{
  const f=fixture(t);await f.store.install(f.release('gray','gray'),f.signal,f.box.capture());f.config.userId=undefined;
  const box=new (load('OtaUserContext').OtaUserContextBox)(f.config);const store=new (load('ContentAddressedOtaStore').default)(f.config,f.api,box);
  assert.equal(store.acquireCurrentBundleLease('10000001','main.lynx.bundle',box.capture()),null);
  const s=state(f);delete s.selectionSchemaVersion;delete s.current.selection;fs.writeFileSync(path.join(f.directory,'apps/10000001/state.json'),JSON.stringify(s));
  assert.equal(current(f),null);await f.store.install(f.release('gray','full','2','gray'),f.signal,f.box.capture());assert.equal(f.api.count,1);assert.equal(current(f).selectionKind,'full');
});
test('C21 code and SDK range compatibility is rechecked on cold read',async t=>{
  const f=fixture(t);await f.store.install({...f.release('range'),versionCodeRange:{min:'25',max:'25'},lynxSdkRange:{min:'4',max:'4.0.0'}},f.signal,f.box.capture());
  for(const patch of [{versionCode:'26'},{lynxSdkVersion:'4.1'}]){
    const config=Object.assign(new Models.LynxOtaConfig('https://example.invalid'),f.config,patch);const box=new (load('OtaUserContext').OtaUserContextBox)(config);const store=new (load('ContentAddressedOtaStore').default)(config,f.api,box);
    assert.equal(store.acquireCurrentBundleLease('10000001','main.lynx.bundle',box.capture()),null);
  }
});
test('C06 delayed A download cannot commit after B sync and current lease remains available during network wait',async t=>{
  const f=fixture(t);await f.store.install(f.release('base'),f.signal,f.box.capture());const gate=deferred(),started=deferred();const original=f.api.downloadBundle.bind(f.api);
  f.api.downloadBundle=async url=>{if(url.endsWith('/A')){started.resolve();await gate.promise;}return original(url);};
  const a=f.store.install(f.release('A','gray','2'),f.signal,f.box.capture());await started.promise;
  assert.equal(current(f).releaseId,'base');f.box.register('B');await f.store.install(f.release('B','full','3'),f.signal,f.box.capture());const before=JSON.stringify(state(f));
  gate.resolve();await assert.rejects(a,/stale_identity/);assert.equal(JSON.stringify(state(f)),before);assert.equal(current(f).releaseId,'B');
});
test('higher revision embedded decision rejects same-user in-flight release and persists on cold read',async t=>{
  const f=fixture(t);await f.store.install(f.release('base'),f.signal,f.box.capture());const gate=deferred(),started=deferred();const original=f.api.downloadBundle.bind(f.api);
  f.api.downloadBundle=async url=>{if(url.endsWith('/slow')){started.resolve();await gate.promise;}return original(url);};
  const pending=f.store.install(f.release('slow','full','2'),f.signal,f.box.capture());await started.promise;
  f.store.recordDecision('10000001',{directive:{lynxAppId:'10000001',action:'use_embedded',policyRevision:'9007199254740993',reason:'forced'}},f.box.capture());const before=JSON.stringify(state(f));
  gate.resolve();await assert.rejects(pending,/stale_decision/);assert.equal(JSON.stringify(state(f)),before);assert.equal(current(f),null);
  assert.equal(state(f).lastDecision.policyRevision,'9007199254740993');
});
test('C10 rollback never restores A gray previous and expected-current prevents deleting newer full',async t=>{
  const f=fixture(t);await f.store.install(f.release('gray','gray'),f.signal,f.box.capture());await f.store.install(f.release('full','full','2'),f.signal,f.box.capture());
  f.box.register('B');assert.throws(()=>f.store.rollback('10000001','wrong',f.box.capture()),/stale_decision/);assert.equal(current(f).releaseId,'full');
  assert.equal(f.store.rollback('10000001','full',f.box.capture()),false);assert.equal(current(f),null);assert.equal(state(f).current.kind,'embedded');
});
test('batch commits directive and all decisions before selected download failures, preserves structured partial success',async t=>{
  const f=fixture(t);const good=f.release('good','full','2','good','10000003');const bad=f.release('bad','full','2');f.data.delete(bad.changedBundles[0].bundleUrl);
  const original=f.api.downloadBundle.bind(f.api);f.api.downloadBundle=async url=>{assert.equal(state(f,'10000002').lastDecision.action,'use_embedded');assert.equal(state(f,'10000003').lastDecision.targetReleaseId,'good');return original(url);};
  const Sync=load('OtaSelectionSync').default;const sync=new Sync(f.api,f.store,f.box);
  await assert.rejects(sync.apply({env:'TEST',hostApp:'capp',platform:'harmony',selectionSchemaVersion:1,bundleLists:[bad,good],directives:[{lynxAppId:'10000002',action:'use_embedded',policyRevision:'2',reason:'forced'}]},f.signal,f.box.capture()),e=>{assert.equal(e.failures.length,1);assert.equal(e.failures[0].stage,'update');assert.deepEqual(e.partialResult.completedAppIds,['10000002','10000003']);return true;});
  assert.equal(current(f,f.box.capture(),'10000003').releaseId,'good');
});
test('malformed later batch metadata prevents every State decision and download',async t=>{
  const f=fixture(t);const bad=f.release('bad','full','2','bad','10000002');delete bad.selection;
  const sync=new (load('OtaSelectionSync').default)(f.api,f.store,f.box);
  await assert.rejects(sync.apply({env:'TEST',hostApp:'capp',platform:'harmony',selectionSchemaVersion:1,bundleLists:[f.release('good'),bad],directives:[]},f.signal,f.box.capture()),/missing_selection/);
  assert.deepEqual(fs.readdirSync(path.join(f.directory,'apps')),[]);assert.equal(f.api.count,0);
});
test('C09 live lease and snapshot lease remain readable through identity change and delete until close',async t=>{
  const f=fixture(t);await f.store.install(f.release('gray','gray'),f.signal,f.box.capture());const prepared=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  f.box.register('B');f.store.deleteBundles('10000001',f.box.capture());assert.equal(fs.readFileSync(prepared.filePath,'utf8'),'gray');
  prepared.lease.close();prepared.lease.close();f.store.pruneAllUnreferencedReleases();assert.equal(fs.existsSync(prepared.filePath),false);
});
test('transaction-published manifest remains protected if lease GC runs before final State commit',async t=>{
  const f=fixture(t);await f.store.install(f.release('base'),f.signal,f.box.capture());
  const gate=deferred(),started=deferred();f.store.pauseAtTestPoint=async point=>{if(point==='after_manifest_commit'){started.resolve();await gate.promise;}};
  const pending=f.store.install(f.release('next','full','2'),f.signal,f.box.capture());await started.promise;
  f.store.pruneAllUnreferencedReleases();gate.resolve();await pending;
  assert.equal(current(f)?.releaseId,'next');
});
test('same-context NavigationSnapshot full lease can still acquire after falling out of current and previous',async t=>{
  const f=fixture(t);await f.store.install(f.release('one'),f.signal,f.box.capture());const p=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  await f.store.install(f.release('two','full','2'),f.signal,f.box.capture());await f.store.install(f.release('three','full','3'),f.signal,f.box.capture());
  const pinned=f.store.acquireBundleLeaseForRelease('10000001','one','main.lynx.bundle',p.manifestId,f.box.capture());
  assert.equal(pinned?.releaseId,'one');pinned?.lease.close();p.lease.close();
});
test('final State temp fsync then registration rejects the final rename, not just pre-download epoch checks',async t=>{
  const f=fixture(t);await f.store.install(f.release('base'),f.signal,f.box.capture());
  afterFileSync=p=>{if(p?.includes('/state.json.tmp-')&&JSON.parse(fs.readFileSync(p,'utf8')).current.releaseId==='race'){afterFileSync=undefined;f.box.register('B');}};
  t.after(()=>afterFileSync=undefined);
  await assert.rejects(f.store.install(f.release('race','full','2'),f.signal,f.box.capture()),/stale_identity/);
  assert.equal(state(f).current.releaseId,'base');assert.equal(current(f).releaseId,'base');
});
test('C14 100 objects change one then B uses its own full selection without another copy or GET',async t=>{
  const f=fixture(t);function release(id,rev,changed){const r=f.release(id,'full',rev);r.changedBundles=[];for(let n=0;n<100;n++){const body=n===50?changed:'shared-'+n;const bytes=Buffer.from(body);const url='https://example.invalid/'+id+'/'+n;f.data.set(url,bytes);r.changedBundles.push({pageId:n+1,bundlePath:`bundle-${String(n).padStart(3,'0')}.lynx.bundle`,bundleSha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),bundleUrl:url,size:bytes.length});}return r;}
  const one=release('one','1','first');await f.store.install(one,f.signal,f.box.capture());assert.equal(f.api.count,100);
  const objectPath=hash=>path.join(f.directory,'apps/10000001/objects',hash.slice(7,9),hash.slice(7)+'.lynx.bundle');
  const inode=one.changedBundles.map(b=>fs.statSync(objectPath(b.bundleSha256)).ino);
  const two=release('two','2','second');await f.store.install(two,f.signal,f.box.capture());assert.equal(f.api.count,101);
  for(let n=0;n<100;n++)if(n!==50)assert.equal(fs.statSync(objectPath(two.changedBundles[n].bundleSha256)).ino,inode[n]);
  const objects=fs.readdirSync(path.join(f.directory,'apps/10000001/objects'),{recursive:true}).filter(x=>x.endsWith('.lynx.bundle'));assert.equal(objects.length,101);
  f.box.register('B');await f.store.install({...two,selection:{kind:'full',policyRevision:'3',reason:'latest_full'}},f.signal,f.box.capture());assert.equal(f.api.count,101);assert.equal(state(f).lastDecision.clientContextKey,f.box.capture().clientContextKey);
});
test('API real loopback query is harmony with exact code SDK optional user and per-context ETags',async t=>{
  const http=require('node:http');const requests=[];const server=http.createServer((req,res)=>{const url=new URL(req.url,'http://localhost');requests.push({query:Object.fromEntries(url.searchParams),etag:req.headers['if-none-match']});if(req.headers['if-none-match']==='"same"'){res.writeHead(304);res.end();return;}res.writeHead(200,{'content-type':'application/json','etag':'"same"'});res.end(JSON.stringify({...selected,versionCodeRange:{min:'20',max:'30'}}));});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();server.close();});
  const f=fixture(t);f.config.apiBaseUrl=`http://127.0.0.1:${server.address().port}`;f.config.allowLocalHTTPForTest=true;
  const api=new (load('OtaApiClient').default)(f.config,null,f.box);
  await api.fetchLatestSelection('10000001',f.signal,f.box.capture());await api.fetchLatestSelection('10000001',f.signal,f.box.capture());
  f.box.register(undefined);await api.fetchLatestSelection('10000001',f.signal,f.box.capture());
  assert.equal(requests[0].query.platform,'harmony');assert.equal(requests[0].query.versioncode,'25');assert.equal(requests[0].query.lynxSdkVersion,'4.0.0');assert.equal(requests[0].query.userId,'A');assert.equal(requests[1].etag,'"same"');assert.equal(requests[2].etag,undefined);assert.equal('userId'in requests[2].query,false);
});
test('direct single directive preserves schema and missing new metadata is rejected',async t=>{
  const f=fixture(t);const d=Json.parseLatestLists(JSON.stringify({selectionSchemaVersion:1,env:'TEST',hostApp:'capp',platform:'harmony',decision:{lynxAppId:'10000001',action:'no_compatible_release',policyRevision:'9',reason:'no_compatible_release'}}));assert.equal(d.directives[0].action,'no_compatible_release');
  const Selection=load('OtaSelection').OtaSelection;assert.throws(()=>Selection.fromRelease({...selected,selection:undefined},f.box.capture()),/missing_selection_metadata/);
  assert.throws(()=>Json.parseLatestLists(JSON.stringify({...selected,versionCodeRange:{min:null}})));
  assert.throws(()=>Json.parseLatestLists(JSON.stringify({...selected,platforms:['unknown']})));
});
test('completed later transaction releases abandoned recovery roots without touching live transactions',async t=>{
  const f=fixture(t);const failed=f.release('failed');const missing=f.release('missing');
  failed.changedBundles.push({...missing.changedBundles[0],pageId:2,bundlePath:'other.lynx.bundle'});f.data.delete(missing.changedBundles[0].bundleUrl);
  await assert.rejects(f.store.install(failed,f.signal,f.box.capture()),/download_failed/);
  const hash=failed.changedBundles[0].bundleSha256;const object=path.join(f.directory,'apps/10000001/objects',hash.slice(7,9),hash.slice(7)+'.lynx.bundle');assert.equal(fs.existsSync(object),true);
  await f.store.install(f.release('good','full','2'),f.signal,f.box.capture());
  assert.equal(fs.existsSync(object),false);assert.deepEqual(fs.readdirSync(path.join(f.directory,'apps/10000001/transactions')),[]);
});
test('higher policy revision accepts lower release sequence, older same-context response stays rejected',async t=>{
  const f=fixture(t);await f.store.install(f.release('ten','full','10'),f.signal,f.box.capture());const rollback=f.release('five','full','11');rollback.releaseSequence='5';rollback.selection.reason='server_rollback';
  await f.store.install(rollback,f.signal,f.box.capture());assert.equal(current(f).releaseId,'five');assert.equal(state(f).current.selection.releaseSequence,'5');
  await assert.rejects(f.store.install(f.release('ten','full','10'),f.signal,f.box.capture()),/stale_decision/);assert.equal(current(f).releaseId,'five');
});

test('Async 和两种语言先完整落本地，再激活主代码；lazy 请求不联网',async t=>{
  const f=fixture(t);
  const put=(name,value)=>{const bytes=Buffer.from(value);const url=`https://example.invalid/${name}`;f.data.set(url,bytes);return {url,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const lazy=put('probe.bundle','local-lazy-bytes');
  const asyncBody=JSON.stringify({schemaVersion:1,entries:[{ownerBundlePath:'main.lynx.bundle',requestKey:'/lazy-bundle/probe.bundle',path:'lazy-bundle/probe.bundle',...lazy,kind:'bundle'}]});
  const asyncRef=put('async-manifest.json',asyncBody);
  const zh=put('zh.json',JSON.stringify({title:'你好 {{name}}'}));
  const en=put('en.json',JSON.stringify({title:'Hello {{name}}'}));
  const requirement={contractVersion:1,namespaces:[{name:'home',requiredKeys:['title']}]};
  f.catalogs.set(1,{catalogId:'catalog-one',env:'TEST',hostApp:'capp',lynxAppId:'10000001',status:'published',manifest:{schemaVersion:1,revision:'r1',contractVersion:1,locales:[
    {locale:'zh-CN',revision:'zh1',namespaces:[{name:'home',path:'locales/zh-CN/home.json',...zh}]},
    {locale:'en-US',revision:'en1',namespaces:[{name:'home',path:'locales/en-US/home.json',...en}]}
  ]}});
  const release={...f.release('sidecars'),asyncBundleManifest:{schemaVersion:1,...asyncRef},i18nRequirement:requirement};
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(state(f).current.releaseId,'sidecars');
  const prepared=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(prepared.i18nPayload.messages.home.title,'你好 {{name}}');
  assert.equal(prepared.i18nResolver.select('en-US').messages.home.title,'Hello {{name}}');
  assert.equal(Buffer.from(prepared.asyncResolver.resolveBytes('/lazy-bundle/probe.bundle')).toString(),'local-lazy-bytes');
  assert.equal(prepared.asyncResolver.isDeclared('webpack:///static/image/not-declared.png'),false);
  const before=f.api.count;
  prepared.asyncResolver.resolveBytes('/lazy-bundle/probe.bundle');
  prepared.i18nResolver.select('en-US');
  assert.equal(f.api.count,before);
  prepared.catalogLease.close();prepared.lease.close();
});

test('同 Release Async 损坏会修复；缺 rooted Async 清单时 GC 不删除其对象',async t=>{
  const f=fixture(t);
  const put=(name,value)=>{const bytes=Buffer.from(value);const url=`https://example.invalid/${name}`;f.data.set(url,bytes);return {url,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const lazy=put('lazy.bundle','lazy-bytes');
  const ref=put('async.json',JSON.stringify({schemaVersion:1,entries:[{ownerBundlePath:'main.lynx.bundle',requestKey:'/lazy-bundle/lazy.bundle',path:'lazy-bundle/lazy.bundle',...lazy,kind:'bundle'}]}));
  const release={...f.release('repair'),asyncBundleManifest:{schemaVersion:1,...ref}};
  await f.store.install(release,f.signal,f.box.capture());
  const app=path.join(f.directory,'apps/10000001/async-bundles');
  const manifestFile=path.join(app,'manifests',ref.sha256.slice(7)+'.json');
  const objectFile=path.join(app,'objects',lazy.sha256.slice(7,9),lazy.sha256.slice(7)+'.bin');
  assert.equal(fs.existsSync(objectFile),true);
  fs.unlinkSync(manifestFile);
  f.store.pruneAllUnreferencedReleases();
  assert.equal(fs.existsSync(objectFile),true);
  const before=f.api.count;
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(fs.existsSync(manifestFile),true);
  fs.writeFileSync(objectFile,'tampered');
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(f.api.count>before,true);
  const current=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(Buffer.from(current.asyncResolver.resolveBytes('/lazy-bundle/lazy.bundle')).toString(),'lazy-bytes');
  current.lease.close();
});

test('强校验边界忽略元数据缓存并修复同长篡改的主包与 Async 对象',async t=>{
  const f=fixture(t);const bytes=Buffer.from('lazy-bytes');
  const url='https://example.invalid/lazy';f.data.set(url,bytes);
  const sha='sha256:'+crypto.createHash('sha256').update(bytes).digest('hex');
  const body=JSON.stringify({schemaVersion:1,entries:[{ownerBundlePath:'main.lynx.bundle',requestKey:'/lazy-bundle/lazy.bundle',path:'lazy-bundle/lazy.bundle',url,sha256:sha,size:bytes.length,kind:'bundle'}]});
  const refBytes=Buffer.from(body);const refUrl='https://example.invalid/async.json';f.data.set(refUrl,refBytes);
  const ref={schemaVersion:1,url:refUrl,sha256:'sha256:'+crypto.createHash('sha256').update(refBytes).digest('hex'),size:refBytes.length};
  const release={...f.release('main'),asyncBundleManifest:ref};
  await f.store.install(release,f.signal,f.box.capture());
  const app=path.join(f.directory,'apps/10000001');
  const lazyPath=path.join(app,'async-bundles/objects',sha.slice(7,9),sha.slice(7)+'.bin');
  const mainSha=release.changedBundles[0].bundleSha256;
  const mainPath=path.join(app,'objects',mainSha.slice(7,9),mainSha.slice(7)+'.lynx.bundle');
  fs.writeFileSync(lazyPath,'evil-bytes');fs.writeFileSync(mainPath,'evil');
  const lazyStat=fs.statSync(lazyPath);const mainStat=fs.statSync(mainPath);
  f.store.sidecars.validatedObjects.add(`${lazyPath}|${bytes.length}|${lazyStat.mtime}|${lazyStat.ctime}|${lazyStat.ino}`);
  f.store.validatedObjects.set(`10000001|${mainSha}|${mainStat.size}|${mainStat.mtime}|${mainStat.ctime}|${mainStat.ino}`,Date.now());
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(fs.readFileSync(lazyPath,'utf8'),'lazy-bytes');
  assert.equal(fs.readFileSync(mainPath,'utf8'),'main');
});

test('词典独立更新不改变旧页快照；代码回滚在当前词典不兼容时使用旧绑定',async t=>{
  const f=fixture(t,undefined,undefined);
  const put=(name,value)=>{const bytes=Buffer.from(value);const url=`https://example.invalid/${name}`;f.data.set(url,bytes);return {url,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const catalog=(id,key,text)=>{const zh=put(`${id}-zh.json`,JSON.stringify({[key]:text}));const en=put(`${id}-en.json`,JSON.stringify({[key]:text}));return {
    catalogId:id,env:'TEST',hostApp:'capp',lynxAppId:'10000001',status:'published',manifest:{schemaVersion:1,revision:id,contractVersion:1,locales:[
      {locale:'zh-CN',revision:`${id}-zh`,namespaces:[{name:'home',path:`locales/zh-CN/${id}.json`,...zh}]},
      {locale:'en-US',revision:`${id}-en`,namespaces:[{name:'home',path:`locales/en-US/${id}.json`,...en}]}
    ]}};};
  const oldRequirement={contractVersion:1,namespaces:[{name:'home',requiredKeys:['title']}]};
  const newRequirement={contractVersion:1,namespaces:[{name:'home',requiredKeys:['newKey']}]};
  const first={...f.release('first'),i18nRequirement:oldRequirement};
  f.catalogs.set(1,catalog('catalog-old','title','旧文案'));
  await f.store.install(first,f.signal,f.box.capture());
  const oldPage=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(oldPage.i18nResolver.select('zh-CN').messages.home.title,'旧文案');
  f.catalogs.set(1,catalog('catalog-new','newKey','新文案'));
  const second={...f.release('second','full','2'),i18nRequirement:newRequirement};
  await f.store.install(second,f.signal,f.box.capture());
  assert.equal(oldPage.i18nResolver.select('zh-CN').messages.home.title,'旧文案');
  const newer=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(newer.i18nResolver.select('zh-CN').messages.home.newKey,'新文案');
  newer.catalogLease.close();newer.lease.close();
  assert.equal(f.store.rollback('10000001',undefined,f.box.capture()),true);
  const rolled=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(rolled.releaseId,'first');
  assert.equal(rolled.i18nResolver.select('zh-CN').messages.home.title,'旧文案');
  rolled.catalogLease.close();rolled.lease.close();
  oldPage.catalogLease.close();oldPage.lease.close();
});

test('真实 loopback Catalog HTTP 与全资源 GET 完成前主 current 不可见',async t=>{
  const http=require('node:http');const f=fixture(t,undefined,undefined);const files=new Map();const requests=[];
  const put=(pathname,value)=>{const bytes=Buffer.from(value);files.set(pathname,bytes);return {url:pathname,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const main=put('/main.lynx.bundle','main-bytes');const lazy=put('/lazy.bundle','lazy-bytes');
  const zh=put('/zh.json',JSON.stringify({title:'你好'}));const en=put('/en.json',JSON.stringify({title:'Hello'}));
  let finishEn;const waitForEn=new Promise(resolve=>{finishEn=resolve;});
  let startedEn;const sawEn=new Promise(resolve=>{startedEn=resolve;});
  const server=http.createServer(async(req,res)=>{
    const url=new URL(req.url,'http://localhost');requests.push({path:url.pathname,token:req.headers['x-ota-client-token'],resourceSchema:req.headers['x-ota-resource-schema'],contract:url.searchParams.get('contractVersion')});
    if(url.pathname==='/api/ota/v1/i18n/catalogs/latest'){
      res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(server.catalog));return;
    }
    const bytes=files.get(url.pathname);if(!bytes){res.writeHead(404);res.end();return;}
    if(url.pathname==='/en.json'){startedEn();await waitForEn;}
    res.writeHead(200,{'content-type':'application/octet-stream'});res.end(bytes);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();server.close();});
  const origin=`http://127.0.0.1:${server.address().port}`;
  const absolute=(item)=>({...item,url:origin+item.url});
  const asyncRef=put('/async.json',JSON.stringify({schemaVersion:1,entries:[{ownerBundlePath:'main.lynx.bundle',requestKey:'/lazy-bundle/lazy.bundle',path:'lazy-bundle/lazy.bundle',...absolute(lazy),kind:'bundle'}]}));
  server.catalog={catalogId:'local-http',env:'TEST',hostApp:'template',lynxAppId:'10000001',status:'published',manifest:{schemaVersion:1,revision:'r1',contractVersion:1,locales:[
    {locale:'zh-CN',revision:'zh1',namespaces:[{name:'home',path:'locales/zh-CN/home.json',...absolute(zh)}]},
    {locale:'en-US',revision:'en1',namespaces:[{name:'home',path:'locales/en-US/home.json',...absolute(en)}]}
  ]}};
  f.config.apiBaseUrl=origin;f.config.hostApp='template';f.config.allowLocalHTTPForTest=true;f.config.clientToken='local-harmony-client-token';
  const Api=load('OtaApiClient').default;const Store=load('ContentAddressedOtaStore').default;
  const api=new Api(f.config,null,f.box);const store=new Store(f.config,api,f.box);
  const release={env:'TEST',hostApp:'template',lynxAppId:'10000001',releaseId:'http-sidecar',platform:'harmony',status:'ACTIVE',
    selectionSchemaVersion:1,releaseSequence:'1',selection:{kind:'full',policyRevision:'1',reason:'latest_full'},
    changedBundles:[{pageId:1,bundlePath:'main.lynx.bundle',bundleSha256:main.sha256,bundleUrl:origin+main.url,size:main.size}],
    asyncBundleManifest:{schemaVersion:1,...absolute(asyncRef)},
    i18nRequirement:{contractVersion:1,namespaces:[{name:'home',requiredKeys:['title']}]}};
  const pending=store.install(release,{throwIfCancelled(){}},f.box.capture());
  await sawEn;
  const statePath=path.join(f.directory,'apps/10000001/state.json');
  let beforeCommit;
  try { beforeCommit=JSON.parse(fs.readFileSync(statePath,'utf8')).current.releaseId; }
  finally { finishEn(); }
  assert.notEqual(beforeCommit,'http-sidecar');
  await pending;
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.directory,'apps/10000001/state.json'),'utf8')).current.releaseId,'http-sidecar');
  assert.equal(requests.find(entry=>entry.path==='/api/ota/v1/i18n/catalogs/latest').contract,'1');
  assert.equal(requests.find(entry=>entry.path==='/api/ota/v1/i18n/catalogs/latest').token,'local-harmony-client-token');
  assert.equal(requests.find(entry=>entry.path==='/api/ota/v1/i18n/catalogs/latest').resourceSchema,'1');
  const page=store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  const count=requests.length;
  assert.equal(Buffer.from(page.asyncResolver.resolveBytes('/lazy-bundle/lazy.bundle')).toString(),'lazy-bytes');
  assert.equal(page.i18nResolver.select('en-US').messages.home.title,'Hello');
  assert.equal(requests.length,count);
  page.catalogLease.close();page.lease.close();
});

test('新代码主包下载失败时，提前准备的新词典不会切换独立 current',async t=>{
  const f=fixture(t);
  const put=(name,text)=>{const bytes=Buffer.from(JSON.stringify({title:text}));const url=`https://example.invalid/${name}`;f.data.set(url,bytes);return {url,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const catalog=(id,text)=>({catalogId:id,env:'TEST',hostApp:'capp',lynxAppId:'10000001',status:'published',manifest:{schemaVersion:1,revision:id,contractVersion:1,locales:[
    {locale:'zh-CN',revision:id+'zh',namespaces:[{name:'home',path:`locales/zh-CN/${id}.json`,...put(id+'zh',text)}]},
    {locale:'en-US',revision:id+'en',namespaces:[{name:'home',path:`locales/en-US/${id}.json`,...put(id+'en',text)}]}
  ]}});
  const requirement={contractVersion:1,namespaces:[{name:'home',requiredKeys:['title']}]};
  f.catalogs.set(1,catalog('old','old'));
  await f.store.install({...f.release('stable'),i18nRequirement:requirement},f.signal,f.box.capture());
  const catalogStatePath=path.join(f.directory,'apps/10000001/i18n/state.json');
  const before=JSON.parse(fs.readFileSync(catalogStatePath,'utf8')).current;
  f.catalogs.set(1,catalog('new','new'));
  const failing={...f.release('failed','full','2'),i18nRequirement:requirement};
  f.data.delete(failing.changedBundles[0].bundleUrl);
  await assert.rejects(f.store.install(failing,f.signal,f.box.capture()),/download_failed/);
  assert.equal(state(f).current.releaseId,'stable');
  assert.equal(JSON.parse(fs.readFileSync(catalogStatePath,'utf8')).current,before);
  const page=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(page.i18nPayload.messages.home.title,'old');
  page.catalogLease.close();page.lease.close();
});

test('主 State 已提交后词典 State 写入故障不假报主包失败，绑定仍可首帧使用并可重试',async t=>{
  const f=fixture(t);
  const put=(name,text)=>{const bytes=Buffer.from(JSON.stringify({title:text}));const url=`https://example.invalid/${name}`;f.data.set(url,bytes);return {url,sha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),size:bytes.length};};
  const requirement={contractVersion:1,namespaces:[{name:'home',requiredKeys:['title']}]};
  f.catalogs.set(1,{catalogId:'prepared',env:'TEST',hostApp:'capp',lynxAppId:'10000001',status:'published',manifest:{schemaVersion:1,revision:'prepared',contractVersion:1,locales:[
    {locale:'zh-CN',revision:'zh',namespaces:[{name:'home',path:'locales/zh-CN/home.json',...put('zh','可用')} ]},
    {locale:'en-US',revision:'en',namespaces:[{name:'home',path:'locales/en-US/home.json',...put('en','Ready')} ]}
  ]}});
  const release={...f.release('committed'),i18nRequirement:requirement};
  const activate=f.store.sidecars.activateCatalog.bind(f.store.sidecars);
  f.store.sidecars.activateCatalog=()=>{throw new Error('injected_catalog_state_write_failure');};
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(state(f).current.releaseId,'committed');
  assert.equal(fs.existsSync(path.join(f.directory,'apps/10000001/i18n/state.json')),false);
  const page=f.store.acquireCurrentBundleLease('10000001','main.lynx.bundle',f.box.capture());
  assert.equal(page.i18nPayload.messages.home.title,'可用');
  page.catalogLease.close();page.lease.close();
  f.store.sidecars.activateCatalog=activate;
  await f.store.install(release,f.signal,f.box.capture());
  assert.equal(fs.existsSync(path.join(f.directory,'apps/10000001/i18n/state.json')),true);
});
