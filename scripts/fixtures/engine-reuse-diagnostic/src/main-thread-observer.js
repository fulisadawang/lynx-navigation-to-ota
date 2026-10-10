// 诊断专用：保留原函数调用、返回和异常，不修改框架状态或元素树。
const trace = [];
const runtimeId = `MTS-${Date.now()}`;
const availability = {};
let sequence = 0;

function emit(event, detail) {
  const row = { runtimeId, thread: 'MTS', seq: ++sequence, timeMs: Date.now(), event,
    marker: lynx.__initData?.marker, oldOnly: Object.prototype.hasOwnProperty.call(lynx.__initData ?? {}, 'oldOnly'),
    globalMarker: lynx.__globalProps?.marker, ...detail };
  trace.push(row);
  console.log(`ENGINE_REUSE_DIAG_V1 ${JSON.stringify(row)}`);
}

function summarize(name, args) {
  if (name === '__OnLifecycleEvent') {
    const [kind, data] = args[0] ?? [];
    return { kind, rootBytes: typeof data?.root === 'string' ? data.root.length : 0,
      rootContainsA: data?.root?.includes('DIAG_PAGE_A') ?? false,
      rootContainsB: data?.root?.includes('DIAG_PAGE_B') ?? false };
  }
  if (name === 'rLynxChange') {
    const update = args[0];
    const parsed = JSON.parse(update.data);
    return { isHydration: update.patchOptions?.isHydration ?? false,
      reloadVersion: update.patchOptions?.reloadVersion,
      patchCount: parsed.patchList?.length ?? 0,
      snapshotPatchLengths: parsed.patchList?.map((patch) => patch.snapshotPatch?.length ?? 0) };
  }
  return { inputMarker: args[0]?.marker, inputOldOnly: Object.prototype.hasOwnProperty.call(args[0] ?? {}, 'oldOnly'),
    options: args[1] ?? null };
}

function observe(name) {
  const original = globalThis[name];
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
  if (typeof original !== 'function' || descriptor?.writable === false) {
    availability[name] = false;
    emit('hook.unavailable', { name });
    return;
  }
  availability[name] = true;
  globalThis[name] = function (...args) {
    emit(`${name}.enter`, summarize(name, args));
    try { return original.apply(this, args); }
    finally { emit(`${name}.leave`, {
      pageElementPresent: typeof __GetPageElement === 'function' && __GetPageElement() != null,
    }); }
  };
}

for (const name of ['renderPage', 'updatePage', 'updateGlobalProps', 'rLynxFirstScreenSyncReady', 'rLynxChange', '__OnLifecycleEvent']) {
  observe(name);
}
globalThis.engineReuseDiagnosticRead = function () {
  // 返回原始日志快照；BTS保留SDK实际callback形状，不预设成功字段。
  return JSON.stringify({ kind: 'engine-reuse-mts-trace', schemaVersion: 1, runtimeId, availability, events: trace });
};
emit('observer.installed', {});
