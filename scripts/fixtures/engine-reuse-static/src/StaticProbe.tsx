import { root, useGlobalProps, useInitData } from '@lynx-js/react';
import './static.css';

type InitData = { marker: string };
type GlobalProps = { marker: string; probePageId: string };

function StaticProbe() {
  const init = useInitData() as InitData;
  const global = useGlobalProps() as GlobalProps;
  const label = `static-engine:marker=${init.marker}:global=${global.marker}:page=${global.probePageId}`;
  return <view className="static-page">
    <text className="static-title">STATIC_ENGINE_REUSE_FIXTURE_V1</text>
    <text id="engine-static-ready" accessibility-label={label} className="static-ready">{label}</text>
  </view>;
}

root.render(<StaticProbe />);
