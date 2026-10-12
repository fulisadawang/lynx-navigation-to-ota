import { root } from '@lynx-js/react';
import { FixturePage } from './FixturePage.js';
import type { ReadyPayload } from './FixturePage.js';

function runSmall(): ReadyPayload {
  'background only';
  return { caseName: 'small', moduleCount: 0, payloadLength: 0, checksum: 0 };
}

root.render(<FixturePage caseName="small" run={runSmall} />);
