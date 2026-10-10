import { useEffect, useGlobalProps, useInitData, useState } from '@lynx-js/react';
import { getShellModule } from '@cclx/lynx-native-bridge/shell';
import type { ShellNativeResult } from '@cclx/lynx-native-bridge/shell';
import './lazy-panel.css';

let moduleMountCount = 0;

export default function LazyPanel() {
  const initData = useInitData();
  const globalProps = useGlobalProps();
  const [status, setStatus] = useState('LAZY_WAITING_NATIVE');
  const [readyLabel, setReadyLabel] = useState('');
  useEffect(() => {
    'background only';
    moduleMountCount += 1;
    const payload = {
      fixture: 'ENGINE_REUSE_FIXTURE_V1', caseName: 'lazy', phase: 'lazy-mounted',
      component: 'EngineReuseLazyPanel', pageId: globalProps.probePageId,
      marker: initData.marker, globalMarker: globalProps.marker,
      hasOldOnly: Object.prototype.hasOwnProperty.call(initData, 'oldOnly'),
      globalHasOldOnly: Object.prototype.hasOwnProperty.call(globalProps, 'oldOnly'),
      counter: 0, moduleMountCount, lazyStatus: 'mounted',
    };
    try {
      getShellModule().emitToNative('engine-reuse-probe.lazy-ready', payload, (reply: ShellNativeResult) => {
        'background only';
        if (reply.code !== 0) {
          setStatus(`FAILED Native code=${reply.code}: ${reply.message ?? reply.msg ?? 'Lazy回执被拒绝'}`);
          return;
        }
        setReadyLabel(`engine-reuse:lazy-mounted:page=${payload.pageId}:marker=${payload.marker}:mount=${payload.moduleMountCount}`);
        setStatus('LAZY_READY');
      });
    } catch (error) {
      setStatus(`FAILED: ${error instanceof Error ? error.message : String(error)}`);
    }
  }, []);
  return (
    <view className="lazy-panel">
      <text className="lazy-title">真实独立 Lazy Bundle</text>
      <text id="engine-reuse-lazy-status">{status}</text>
      {status === 'LAZY_READY' && <text id="engine-reuse-lazy-ready" accessibility-label={readyLabel}>{readyLabel}</text>}
    </view>
  );
}
