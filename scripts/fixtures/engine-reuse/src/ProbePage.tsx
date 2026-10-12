import { useEffect, useGlobalProps, useInitData, useState } from '@lynx-js/react';
import type { ReactNode } from '@lynx-js/react';
import { getShellModule } from '@cclx/lynx-native-bridge/shell';
import type { ShellNativeResult } from '@cclx/lynx-native-bridge/shell';
import './probe.css';

let moduleMountCount = 0;

export function ProbePage({ caseName, children }: { caseName: 'state' | 'lazy'; children?: ReactNode }) {
  const initData = useInitData();
  const globalProps = useGlobalProps();
  const [counter, setCounter] = useState(0);
  const [mountCount, setMountCount] = useState(0);
  const [status, setStatus] = useState('WAITING_NATIVE');
  const [readyLabel, setReadyLabel] = useState('');
  const hasOldOnly = Object.prototype.hasOwnProperty.call(initData, 'oldOnly');
  const globalHasOldOnly = Object.prototype.hasOwnProperty.call(globalProps, 'oldOnly');

  useEffect(() => {
    'background only';
    moduleMountCount += 1;
    setMountCount(moduleMountCount);
  }, []);

  useEffect(() => {
    'background only';
    if (mountCount === 0) return;
    setStatus('WAITING_NATIVE');
    const payload = {
      fixture: 'ENGINE_REUSE_FIXTURE_V1', caseName,
      phase: counter === 0 ? 'initial' : 'counter',
      pageId: globalProps.probePageId, marker: initData.marker, globalMarker: globalProps.marker,
      hasOldOnly, globalHasOldOnly, counter, moduleMountCount: mountCount,
      ...(caseName === 'lazy' ? { lazyStatus: 'not-requested' } : {}),
    };
    try {
      getShellModule().emitToNative('engine-reuse-probe.ready', payload, (reply: ShellNativeResult) => {
        'background only';
        if (reply.code !== 0) {
          setStatus(`FAILED Native code=${reply.code}: ${reply.message ?? reply.msg ?? '回执被拒绝'}`);
          return;
        }
        setReadyLabel(`engine-reuse:${caseName}:page=${payload.pageId}:marker=${payload.marker}:counter=${counter}:mount=${mountCount}:oldOnly=${hasOldOnly}:globalOldOnly=${globalHasOldOnly}`);
        setStatus('READY');
      });
    } catch (error) {
      setStatus(`FAILED: ${error instanceof Error ? error.message : String(error)}`);
    }
  }, [counter, mountCount, initData, globalProps]);

  return (
    <scroll-view className="probe-page" scroll-y>
      <view className="probe-card">
        <text className="probe-title">ENGINE_REUSE_FIXTURE_V1 · {caseName}</text>
        <text id="engine-reuse-status" className="probe-status">{status}</text>
        {status === 'READY' && <text id="engine-reuse-ready" accessibility-label={readyLabel} className="probe-value">{readyLabel}</text>}
        <text className="probe-value">pageId：{globalProps.probePageId}</text>
        <text className="probe-value">initData.marker：{initData.marker}</text>
        <text className="probe-value">globalProps.marker：{globalProps.marker}</text>
        <text className="probe-value">oldOnly hasOwn：{String(hasOldOnly)}</text>
        <text className="probe-value">global oldOnly hasOwn：{String(globalHasOldOnly)}</text>
        <text id="engine-reuse-counter" className="probe-value">counter：{counter}</text>
        <text className="probe-value">moduleMountCount：{mountCount}</text>
        <view id="engine-reuse-increment" accessibility-label="engine-reuse-increment" className="probe-button" bindtap={() => setCounter((value) => value + 1)}>
          <text className="probe-button-text">counter + 1</text>
        </view>
        {children}
      </view>
    </scroll-view>
  );
}
