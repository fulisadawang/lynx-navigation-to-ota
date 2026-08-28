import {
  OtaBundleArtifact,
  OtaLatestBundleLists,
  OtaLocalManifest,
  OtaReleaseRef,
  OtaReleaseSnapshot,
  OtaReleaseState
} from './OtaModels';

/** 对服务端动态 JSON 做集中、失败即关闭的字段解析，避免错误快照进入磁盘事务。 */
export default class OtaJson {
  static parseLatestLists(raw: string): OtaLatestBundleLists {
    const root = OtaJson.objectValue(JSON.parse(raw), 'latest-bundle-list');
    const rawLists = root['bundleLists'];
    if (Array.isArray(rawLists)) {
      const lists: OtaReleaseSnapshot[] = [];
      rawLists.forEach((item: Object) => lists.push(OtaJson.parseSnapshotObject(item)));
      return {
        env: OtaJson.stringValue(root, 'env'),
        hostApp: OtaJson.hostApp(root),
        platform: OtaJson.optionalString(root, 'platform'),
        bundleLists: lists
      };
    }
    const single = OtaJson.parseSnapshotObject(root);
    return {
      env: single.env,
      hostApp: single.hostApp,
      platform: single.platform,
      bundleLists: [single]
    };
  }

  static parseLocalManifest(raw: string): OtaLocalManifest {
    const root = OtaJson.objectValue(JSON.parse(raw), '本地 Manifest');
    if (OtaJson.numberValue(root, 'schemaVersion') !== 1) {
      throw new Error('本地 Manifest schemaVersion 不支持');
    }
    const bundles = OtaJson.parseBundles(root['bundles'], 'bundles', false);
    return {
      schemaVersion: 1,
      env: OtaJson.stringValue(root, 'env'),
      hostApp: OtaJson.hostApp(root),
      lynxAppId: OtaJson.stringValue(root, 'lynxAppId'),
      releaseId: OtaJson.stringValue(root, 'releaseId'),
      platform: OtaJson.stringValue(root, 'platform'),
      status: OtaJson.optionalString(root, 'status') ?? 'ACTIVE',
      bundles: bundles,
      installedAt: OtaJson.numberValue(root, 'installedAt')
    };
  }

  static parseState(raw: string): OtaReleaseState {
    const root = OtaJson.objectValue(JSON.parse(raw), 'OTA state');
    if (OtaJson.numberValue(root, 'schemaVersion') !== 2) {
      throw new Error('OTA state schemaVersion 不支持');
    }
    const parsedCurrent = OtaJson.parseRef(root['current']);
    if (parsedCurrent === undefined) {
      throw new Error('OTA state current 不合法');
    }
    const current: OtaReleaseRef = parsedCurrent;
    const previous: OtaReleaseRef | undefined = OtaJson.parseRef(root['previous']);
    return {
      schemaVersion: 2,
      env: OtaJson.stringValue(root, 'env'),
      hostApp: OtaJson.hostApp(root),
      lynxAppId: OtaJson.stringValue(root, 'lynxAppId'),
      platform: OtaJson.stringValue(root, 'platform'),
      generation: OtaJson.numberValue(root, 'generation'),
      current,
      previous
    };
  }

  private static parseSnapshotObject(value: Object): OtaReleaseSnapshot {
    const root = OtaJson.objectValue(value, 'Release Snapshot');
    return {
      env: OtaJson.stringValue(root, 'env'),
      hostApp: OtaJson.hostApp(root),
      lynxAppId: OtaJson.stringValue(root, 'lynxAppId'),
      releaseId: OtaJson.stringValue(root, 'releaseId'),
      platform: OtaJson.stringValue(root, 'platform'),
      status: OtaJson.stringValue(root, 'status'),
      changedBundles: OtaJson.parseBundles(root['changedBundles'], 'changedBundles', true)
    };
  }

  private static parseBundles(value: Object | undefined, field: string, requiredSize: boolean): OtaBundleArtifact[] {
    if (!Array.isArray(value)) {
      throw new Error(`${field} 必须是数组`);
    }
    const bundles: OtaBundleArtifact[] = [];
    value.forEach((item: Object) => {
      const object = OtaJson.objectValue(item, 'Bundle');
      const size = requiredSize ? OtaJson.numberValue(object, 'size') : OtaJson.optionalNumber(object, 'size');
      bundles.push({
        pageId: OtaJson.numberValue(object, 'pageId'),
        bundlePath: OtaJson.stringValue(object, 'bundlePath'),
        bundleSha256: OtaJson.stringValue(object, 'bundleSha256'),
        bundleUrl: OtaJson.optionalString(object, 'remoteUrl') ??
          OtaJson.optionalString(object, 'bundleUrl') ??
          OtaJson.stringValue(object, 'bundleURL'),
        size
      });
    });
    return bundles;
  }

  private static parseRef(value: Object | undefined): OtaReleaseRef | undefined {
    if (value === undefined || value === null) {
      return undefined;
    }
    const object = OtaJson.objectValue(value, 'Release ref');
    const kind = OtaJson.stringValue(object, 'kind');
    if (kind !== 'embedded' && kind !== 'downloaded') {
      throw new Error(`未知 Release ref：${kind}`);
    }
    return { kind: kind as 'embedded' | 'downloaded', releaseId: OtaJson.stringValue(object, 'releaseId') };
  }

  private static objectValue(value: Object, field: string): Record<string, Object> {
    if (value === null || Array.isArray(value) || typeof value !== 'object') {
      throw new Error(`${field} 必须是 JSON Object`);
    }
    return value as Record<string, Object>;
  }

  private static hostApp(root: Record<string, Object>): string {
    return OtaJson.optionalString(root, 'hostApp') ?? OtaJson.stringValue(root, 'app');
  }

  private static stringValue(root: Record<string, Object>, key: string): string {
    const value = root[key];
    if (typeof value !== 'string' || value.trim().length === 0) {
      throw new Error(`${key} 必须是非空字符串`);
    }
    return value;
  }

  private static optionalString(root: Record<string, Object>, key: string): string | undefined {
    const value = root[key];
    return typeof value === 'string' && value.trim().length > 0 ? value : undefined;
  }

  private static numberValue(root: Record<string, Object>, key: string): number {
    const value = root[key];
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new Error(`${key} 必须是数字`);
    }
    return value;
  }

  private static optionalNumber(root: Record<string, Object>, key: string): number | undefined {
    const value = root[key];
    return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
  }

  private constructor() {
  }
}
