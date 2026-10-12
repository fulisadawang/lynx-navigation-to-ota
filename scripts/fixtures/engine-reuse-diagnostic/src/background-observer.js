import { getShellModule } from '@cclx/lynx-native-bridge/shell';

const runtimeId = `BTS-${Date.now()}`;
let sequence = 0;

function describeProperty(owner, name) {
  let current = owner;
  let depth = 0;
  while (current != null) {
    const descriptor = Object.getOwnPropertyDescriptor(current, name);
    if (descriptor) return { found: true, ownerDepth: depth, writable: descriptor.writable ?? null,
      hasGetter: typeof descriptor.get === 'function', hasSetter: typeof descriptor.set === 'function',
      configurable: descriptor.configurable, enumerable: descriptor.enumerable };
    current = Object.getPrototypeOf(current);
    depth += 1;
  }
  return { found: false };
}

function observeWritable(owner, name, summarize) {
  const original = owner[name];
  const descriptor = describeProperty(owner, name);
  if (typeof original !== 'function' || !(descriptor.writable === true || descriptor.hasSetter === true)) {
    logBackground('hook.unavailable', { name, descriptor });
    return;
  }
  owner[name] = function (...args) {
    logBackground(`${name}.enter`, summarize(args));
    try { return original.apply(this, args); }
    finally { logBackground(`${name}.leave`, summarize(args)); }
  };
  logBackground('hook.installed', { name, descriptor });
}

export function logBackground(event, detail) {
  'background only';
  const row = { thread: 'BTS', runtimeId, seq: ++sequence, timeMs: Date.now(), event, ...detail };
  console.log(`ENGINE_REUSE_DIAG_V1 ${JSON.stringify(row)}`);
}

export function installBackgroundObserver() {
  'background only';
  const tt = lynxCoreInject.tt;
  observeWritable(tt, 'OnLifecycleEvent', (args) => ({ kind: args[0]?.[0],
    isFirstScreen: args[0]?.[0] === 'rLynxFirstScreen' }));
  observeWritable(tt, 'onAppReload', (args) => ({ marker: args[0]?.marker }));
  const app = lynx.getNativeApp();
  // 真机已确认此Native属性无setter；只保存descriptor，不替换SDK方法。
  logBackground('hook.unavailable', { name: 'NativeApp.callLepusMethod',
    descriptor: describeProperty(app, 'callLepusMethod'), reason: 'native-method-readonly-observed' });
  logBackground('app.entry.evaluate', {});
}

export function readMainThreadTrace(pageId, marker) {
  'background only';
  logBackground('callLepusMethod.diagnostic.request', { name: 'engineReuseDiagnosticRead', pageId, marker });
  lynx.getNativeApp().callLepusMethod('engineReuseDiagnosticRead', {}, (raw) => {
    'background only';
    logBackground('mts.trace.reply', { pageId, marker, rawType: typeof raw });
    getShellModule().emitToNative('engine-reuse-diagnostic.mts-trace', {
      fixture: 'ENGINE_REUSE_DIAGNOSTIC_V1', pageId, marker, rawCallbackJson: JSON.stringify(raw),
    }, (reply) => {
      'background only';
      logBackground('mts.trace.native.reply', { code: reply.code, pageId });
    });
  });
}
