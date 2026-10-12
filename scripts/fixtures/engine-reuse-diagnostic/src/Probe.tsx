import { root, useEffect, useGlobalProps, useInitData, useState } from '@lynx-js/react';
import { getShellModule } from '@cclx/lynx-native-bridge/shell';
import { installBackgroundObserver, logBackground, readMainThreadTrace } from './background-observer.js';
import './probe.css';

declare const __BACKGROUND__: boolean;
if (__BACKGROUND__) installBackgroundObserver();
let moduleMountCount = 0;

function Probe() {
  const initial = useInitData() as { marker: string; oldOnly?: string };
  const global = useGlobalProps() as { marker: string; probePageId: string; oldOnly?: string };
  const [counter, setCounter] = useState(0);
  const [accepted, setAccepted] = useState(false);
  const [mountCount, setMountCount] = useState(0);
  const oldOnly = Object.prototype.hasOwnProperty.call(initial, 'oldOnly');
  const globalOldOnly = Object.prototype.hasOwnProperty.call(global, 'oldOnly');
  const label = `diag:${initial.marker}:page=${global.probePageId}:counter=${counter}:mount=${mountCount}:oldOnly=${oldOnly}:globalOldOnly=${globalOldOnly}`;
  useEffect(() => {
    'background only';
    moduleMountCount += 1;
    setMountCount(moduleMountCount);
    logBackground('app.onceEffect', { marker: initial.marker, pageId: global.probePageId, moduleMountCount });
  }, []);
  useEffect(() => {
    'background only';
    if (mountCount === 0) return;
    logBackground('app.effect', { marker: initial.marker, pageId: global.probePageId, counter });
    getShellModule().emitToNative('engine-reuse-diagnostic.state', {
      fixture: 'ENGINE_REUSE_DIAGNOSTIC_V1', marker: initial.marker, globalMarker: global.marker,
      pageId: global.probePageId, counter, moduleMountCount: mountCount, oldOnly, globalOldOnly,
    }, (reply) => {
      'background only';
      logBackground('app.native.reply', { code: reply.code, marker: initial.marker });
      setAccepted(reply.code === 0);
      setTimeout(() => readMainThreadTrace(global.probePageId, initial.marker), 150);
    });
  }, [counter, mountCount, initial, global]);
  return <view className="page">
    <text className="title">独立 same Engine 生命周期诊断</text>
    <text>marker：{initial.marker}</text><text>counter：{counter}</text>
    <text id="engine-diagnostic-status">{accepted ? 'NATIVE_ACCEPTED' : 'WAITING_NATIVE'}</text>
    {accepted && <text id="engine-diagnostic-ready" accessibility-label={label}>{label}</text>}
    <view id="engine-diagnostic-increment" className="button" bindtap={() => setCounter((value) => value + 1)}>
      <text>真实 counter + 1</text>
    </view>
  </view>;
}
root.render(<Probe />);
