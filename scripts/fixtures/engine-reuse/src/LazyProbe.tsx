import '@lynx-js/react/experimental/lazy/import';
import { Suspense, lazy, root, useErrorBoundary, useState } from '@lynx-js/react';
import { ProbePage } from './ProbePage.js';

const LazyPanel = lazy(() => import(__ENGINE_REUSE_LAZY_URL__, { with: { type: 'component' } }));

function LazyProbe() {
  const [visible, setVisible] = useState(false);
  const [error] = useErrorBoundary();
  return (
    <ProbePage caseName="lazy">
      <text id="engine-reuse-lazy-state" className="probe-value">lazy：{visible ? 'requested' : 'not-requested'}</text>
      <view id="engine-reuse-load-lazy" accessibility-label="engine-reuse-load-lazy" className="probe-button" bindtap={() => setVisible(true)}>
        <text className="probe-button-text">首次加载独立 Lazy Bundle</text>
      </view>
      {error && <text id="engine-reuse-lazy-error">FAILED lazy: {String(error)}</text>}
      {!error && visible && <Suspense fallback={<text id="engine-reuse-lazy-loading">LOADING_LAZY_BUNDLE</text>}><LazyPanel /></Suspense>}
    </ProbePage>
  );
}

root.render(<LazyProbe />);
