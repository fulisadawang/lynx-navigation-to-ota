import { root } from '@lynx-js/react';
import { FixturePage } from './FixturePage.js';
import type { ReadyPayload } from './FixturePage.js';
import { executeModules, expectedChecksum, moduleCount } from '../generated/modules.js';

function runAsync(): ReadyPayload {
  'background only';
  const results = executeModules(17);
  const checksum = results.reduce((sum, value) => sum + value, 0);
  if (results.length !== moduleCount || checksum !== expectedChecksum) {
    throw new Error(`外部脚本校验失败 count=${results.length} checksum=${checksum}`);
  }
  return { caseName: 'async', moduleCount: results.length, payloadLength: 0, checksum };
}

root.render(<FixturePage caseName="async" run={runAsync} />);
