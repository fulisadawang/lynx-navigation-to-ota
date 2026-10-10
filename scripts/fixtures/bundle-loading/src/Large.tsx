import { root } from '@lynx-js/react';
import { FixturePage } from './FixturePage.js';
import type { ReadyPayload } from './FixturePage.js';
import { payload, expectedChecksum, expectedLength, sparseStride } from '../generated/payload.js';

function runLarge(): ReadyPayload {
  'background only';
  let checksum = 0;
  for (let index = 0; index < payload.length; index += sparseStride) {
    checksum = (checksum + payload.charCodeAt(index) * (index + 1)) >>> 0;
  }
  checksum = (checksum + payload.charCodeAt(payload.length - 1)) >>> 0;
  if (payload.length !== expectedLength || checksum !== expectedChecksum) {
    throw new Error(`大数据校验失败 length=${payload.length} checksum=${checksum}`);
  }
  return { caseName: 'large', moduleCount: 0, payloadLength: payload.length, checksum };
}

root.render(<FixturePage caseName="large" run={runLarge} />);
