import { useEffect, useState } from '@lynx-js/react';
import { getShellModule } from '@cclx/lynx-native-bridge/shell';
import type { ShellNativeResult } from '@cclx/lynx-native-bridge/shell';
import './fixture.css';

export type ReadyPayload = {
  caseName: 'small' | 'large' | 'async';
  moduleCount: number;
  payloadLength: number;
  checksum: number;
};

type Props = {
  caseName: ReadyPayload['caseName'];
  run: () => ReadyPayload;
};

export function FixturePage({ caseName, run }: Props) {
  const [status, setStatus] = useState('准备执行背景脚本');
  const [result, setResult] = useState<ReadyPayload | null>(null);
  const readyLabel = result
    ? `bundle-bench:${result.caseName}:payload=${result.payloadLength}:checksum=${result.checksum}:scripts=${result.moduleCount}`
    : '';

  function execute() {
    'background only';
    setStatus('RUNNING');
    try {
      const payload = run();
      setResult(payload);
      getShellModule().emitToNative('bundle-loading-bench.ready', payload, (reply: ShellNativeResult) => {
        'background only';
        if (reply.code !== 0) {
          setStatus(`FAILED Native code=${reply.code}: ${reply.message ?? reply.msg ?? '宿主未接受回执'}`);
          return;
        }
        setStatus('READY：全部脚本计算成功，Native 已接受回执');
      });
    } catch (error) {
      setStatus(`FAILED：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  useEffect(() => {
    'background only';
    execute();
  }, []);

  return (
    <scroll-view className="fixture-page" scroll-y>
      <view className="fixture-card">
        <text className="eyebrow">BUNDLE_LOADING_FIXTURE_V1</text>
        <text className="title">Bundle 加载测试 · {caseName}</text>
        <text id={status.startsWith('FAILED') ? 'bundle-bench-error' : 'bundle-bench-status'} className="status">{status}</text>
        {result && (
          <text id="bundle-bench-ready" accessibility-label={readyLabel} className="value">{readyLabel}</text>
        )}
        <text className="value">moduleCount：{result?.moduleCount ?? '等待计算'}</text>
        <text className="value">payloadLength：{result?.payloadLength ?? '等待计算'}</text>
        <text className="value">checksum：{result?.checksum ?? '等待计算'}</text>
        <text className="hint">首屏计时由原生 SDK 回调记录</text>
        <view className="button" bindtap={execute}>
          <text className="button-text">重新执行脚本</text>
        </view>
      </view>
    </scroll-view>
  );
}
