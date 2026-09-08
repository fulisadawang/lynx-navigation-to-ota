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
let afterFileSync;
function load(name) {
  if(cache.has(name)) return cache.get(name).exports;
  const file = path.join(root, name + '.ets');
  const mod = {exports:{}}; cache.set(name,mod);
  const js = ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const localRequire = id => id.startsWith('./') ? load(id.slice(2)) : platform(id);
  vm.runInThisContext(`(function(require,module,exports){${js}\n})`,{filename:file})(localRequire,mod,mod.exports);
  return mod.exports;
}
function platform(id) {
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
  if(id==='@ohos.security.cryptoFramework')return {default:{createMd:()=>{const h=crypto.createHash('sha256');return {updateSync:x=>h.update(x.data),digestSync:()=>({data:new Uint8Array(h.digest())})};},createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(crypto.randomBytes(n))})})}};
  if(id==='@ohos.net.http')return {default:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'string',ARRAY_BUFFER:'arraybuffer'},createHttp:()=>{const controller=new AbortController();return {request:async(url,options)=>{const r=await fetch(url,{headers:options.header,signal:controller.signal});return {responseCode:r.status,header:Object.fromEntries(r.headers),result:options.expectDataType==='arraybuffer'?await r.arrayBuffer():await r.text()};},destroy:()=>controller.abort()};}}};
  throw new Error('Unsupported test platform adapter: '+id);
}
const Json = load('OtaJson').default;
const Models = load('OtaModels');
const selected = {env:'TEST',hostApp:'capp',lynxAppId:'10000001',releaseId:'full5',platform:'harmony',status:'ACTIVE',changedBundles:[],selectionSchemaVersion:1,releaseSequence:'9007199254740993',selection:{kind:'full',policyRevision:'9007199254740994',reason:'latest_full'}};
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
  const Store=load('ContentAddressedOtaStore').default;const store=new Store(config,api,box);
  function release(id,kind='full',revision='1',body=id,app='10000001') {
    const bytes=Buffer.from(body);const url='https://example.invalid/'+id;data.set(url,bytes);
    return {...selected,lynxAppId:app,releaseId:id,releaseSequence:revision,selection:{kind,ruleId:kind==='gray'?'rule':undefined,policyRevision:revision,reason:kind==='gray'?'matched_gray':'latest_full'},changedBundles:[{pageId:1,bundlePath:'main.lynx.bundle',bundleSha256:'sha256:'+crypto.createHash('sha256').update(bytes).digest('hex'),bundleUrl:url,size:bytes.length}]};
  }
  return {config,box,api,data,store,release,signal:{throwIfCancelled(){}},directory};
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
