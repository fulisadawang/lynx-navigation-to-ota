export const fixtureSpec = Object.freeze({
  schemaVersion: 1,
  seed: 0x4c594e58,
  largePayloadLength: 3 * 1024 * 1024,
  sparseStride: 4093,
  asyncModuleCount: 10,
  asyncSeed: 17,
  marker: 'BUNDLE_LOADING_FIXTURE_V1',
  defaultOutput: '/tmp/codex-bundle-loading-opt-20261009/implementation/fixture-out',
  defaultDependencies: '/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/node_modules',
  defaultAssetPrefix: 'http://127.0.0.1:18781/',
});

export function makePayload(length, seed = fixtureSpec.seed) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let state = seed >>> 0;
  const bytes = Buffer.allocUnsafe(length);
  for (let index = 0; index < length; index += 1) {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    bytes[index] = alphabet.charCodeAt(state >>> 26);
  }
  return bytes.toString('ascii');
}

export function sparseChecksum(payload) {
  let checksum = 0;
  for (let index = 0; index < payload.length; index += fixtureSpec.sparseStride) {
    checksum = (checksum + payload.charCodeAt(index) * (index + 1)) >>> 0;
  }
  return (checksum + payload.charCodeAt(payload.length - 1)) >>> 0;
}

export function asyncChecksum() {
  let checksum = 0;
  for (let moduleNumber = 1; moduleNumber <= fixtureSpec.asyncModuleCount; moduleNumber += 1) {
    checksum += moduleNumber * 1009 + fixtureSpec.asyncSeed * moduleNumber;
  }
  return checksum;
}

export function readyLabel(payload) {
  return `bundle-bench:${payload.caseName}:payload=${payload.payloadLength}:checksum=${payload.checksum}:scripts=${payload.moduleCount}`;
}
