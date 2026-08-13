import TelemetryCoordinator from './TelemetryCoordinator';
import {
  AttemptedBundleSnapshot,
  ResolvedBundleSnapshot,
  TelemetryBundleSource,
  TelemetryIdentity
} from './TelemetryModels';

/**
 * Phase 1 Alpha 纯逻辑 fixture；不依赖 Lynx ABI 或 HAP 测试 runner。
 * 宿主可在 build/test 环境调用 runTelemetryCoreFixture() 做最小回归。
 */
export function runTelemetryCoreFixture(): boolean {
  const coordinator = new TelemetryCoordinator();
  const identity: TelemetryIdentity = {
    navigationId: 'navigation-1',
    navigationSessionId: 'session-1',
    entryId: 'entry-1',
    pageViewId: 'page-1',
    renderAttemptId: 'attempt-1'
  };
  const attempted: AttemptedBundleSnapshot = {
    kind: 'attempted',
    bundleSource: TelemetryBundleSource.OTA,
    lynxAppId: '10000001',
    bundleName: 'home.lynx.bundle',
    telemetryRouteKey: '10000001/home.lynx.bundle',
    candidateReleaseId: 'release-1',
    expectedSha256: 'sha-1',
    prepareStartedAtUnixMs: Date.now(),
    attemptGeneration: 1
  };
  const page = coordinator.startPage(identity, attempted);
  if (page.pageViewId !== 'page-1') {
    return false;
  }
  const resolved: ResolvedBundleSnapshot = {
    kind: 'resolved',
    bundleSource: TelemetryBundleSource.OTA,
    lynxAppId: '10000001',
    bundleName: 'home.lynx.bundle',
    telemetryRouteKey: '10000001/home.lynx.bundle',
    releaseId: 'release-1',
    bundleSha256: 'sha-1',
    resolvedAtUnixMs: Date.now(),
    internalLocalPath: '/private/path/must-not-be-uploaded'
  };
  if (!coordinator.resolve('page-1', resolved, 'attempt-1', 1)) {
    return false;
  }
  coordinator.markPageVisible('page-1');
  coordinator.markFirstScreen('page-1', 'attempt-1', 1);
  coordinator.markFirstScreen('page-1', 'attempt-1', 1);
  coordinator.dropStaleCallback('page-1', 'old-attempt', 1);
  coordinator.onApplicationBackground();
  coordinator.markPageHidden('page-1');
  coordinator.markPageDestroyed('page-1');
  return true;
}
