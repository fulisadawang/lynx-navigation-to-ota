import {
  OtaBundleArtifact,
  OtaLatestBundleLists,
  OtaLocalManifest,
  OtaReleaseRef,
  OtaReleaseSnapshot,
  OtaReleaseState
} from './OtaModels';
import { OtaLastDecision, OtaSelection, OtaSelectionDirective, OtaSelectionMetadata, OtaStoredSelection, OtaVersionRange } from './OtaSelection';

/** 对服务端动态 JSON 做集中、失败即关闭的字段解析，避免错误快照进入磁盘事务。 */
export default class OtaJson {
  static parseLatestLists(raw: string): OtaLatestBundleLists {
    const root = OtaJson.objectValue(JSON.parse(raw), 'latest-bundle-list');
    const rawLists = root['bundleLists'];
    const directives: OtaSelectionDirective[] = [];
    if (root['directives'] !== undefined) {
      const rawDirectives = root['directives'];
      if (!Array.isArray(rawDirectives)) throw new Error('invalid_directives');
      rawDirectives.forEach((item: Object) => directives.push(OtaJson.parseDirective(item)));
    }
    if (root['decision'] !== undefined) directives.push(OtaJson.parseDirective(root['decision']));
    const schema = OtaJson.optionalNumber(root, 'selectionSchemaVersion');
    if (root['bundleLists'] !== undefined && !Array.isArray(rawLists)) throw new Error('invalid_bundle_lists');
    if (Array.isArray(rawLists)) {
      const lists: OtaReleaseSnapshot[] = [];
      rawLists.forEach((item: Object) => lists.push(OtaJson.parseSnapshotObject(item)));
      return {
        env: OtaJson.stringValue(root, 'env'),
        hostApp: OtaJson.hostApp(root),
        platform: OtaJson.optionalString(root, 'platform'),
        bundleLists: lists,
        selectionSchemaVersion: schema,
        directives: directives
      };
    }
    if (root['decision'] !== undefined) {
      return { env: OtaJson.stringValue(root, 'env'), hostApp: OtaJson.hostApp(root),
        platform: OtaJson.platform(root, 'platform'), bundleLists: [], directives: directives, selectionSchemaVersion: schema };
    }
    const single = OtaJson.parseSnapshotObject(root);
    return {
      env: single.env,
      hostApp: single.hostApp,
      platform: single.platform,
      bundleLists: [single],
      selectionSchemaVersion: schema,
      directives: directives
    };
  }

  static parseLocalManifest(raw: string): OtaLocalManifest {
    const root = OtaJson.objectValue(JSON.parse(raw), '本地 Manifest');
    const schemaVersion = OtaJson.numberValue(root, 'schemaVersion');
    if (schemaVersion !== 1 && schemaVersion !== 3) {
      throw new Error('本地 Manifest schemaVersion 不支持');
    }
    const bundles = OtaJson.parseBundles(root['bundles'], 'bundles', false);
    return {
      schemaVersion: schemaVersion,
      manifestId: OtaJson.optionalString(root, 'manifestId'),
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
    const schemaVersion = OtaJson.numberValue(root, 'schemaVersion');
    if (schemaVersion !== 2 && schemaVersion !== 3) {
      throw new Error('OTA state schemaVersion 不支持');
    }
    const parsedCurrent = OtaJson.parseRef(root['current']);
    if (parsedCurrent === undefined) {
      throw new Error('OTA state current 不合法');
    }
    const current: OtaReleaseRef = parsedCurrent;
    const previous: OtaReleaseRef | undefined = OtaJson.parseRef(root['previous']);
    return {
      schemaVersion: schemaVersion,
      env: OtaJson.stringValue(root, 'env'),
      hostApp: OtaJson.hostApp(root),
      lynxAppId: OtaJson.stringValue(root, 'lynxAppId'),
      platform: OtaJson.stringValue(root, 'platform'),
      generation: OtaJson.numberValue(root, 'generation'),
      current,
      previous,
      selectionSchemaVersion: OtaJson.optionalNumber(root, 'selectionSchemaVersion'),
      lastDecision: root['lastDecision'] === undefined ? undefined : OtaJson.parseDecision(root['lastDecision'])
    };
  }

  private static parseSnapshotObject(value: Object): OtaReleaseSnapshot {
    const root = OtaJson.objectValue(value, 'Release Snapshot');
    return {
      env: OtaJson.stringValue(root, 'env'),
      hostApp: OtaJson.hostApp(root),
      lynxAppId: OtaJson.stringValue(root, 'lynxAppId'),
      releaseId: OtaJson.stringValue(root, 'releaseId'),
      platform: OtaJson.platform(root, 'platform'),
      status: OtaJson.stringValue(root, 'status'),
      changedBundles: OtaJson.parseBundles(root['changedBundles'], 'changedBundles', true),
      platforms: OtaJson.platforms(root['platforms']),
      selectionSchemaVersion: OtaJson.optionalNumber(root, 'selectionSchemaVersion'),
      selection: root['selection'] === undefined ? undefined : OtaJson.parseSelection(root['selection']),
      releaseSequence: OtaJson.strictOptionalString(root, 'releaseSequence'),
      versionCodeRange: OtaJson.range(root['versionCodeRange']),
      lynxSdkRange: OtaJson.range(root['lynxSdkRange']),
      minAppVersion: OtaJson.strictOptionalString(root, 'minAppVersion'),
      maxAppVersion: OtaJson.strictOptionalString(root, 'maxAppVersion'),
      nativeProtocolVersionRange: OtaJson.range(root['nativeProtocolVersionRange'])
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
        size,
        objectId: OtaJson.optionalString(object, 'objectId')
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
    return {
      kind: kind as 'embedded' | 'downloaded',
      releaseId: OtaJson.stringValue(object, 'releaseId'),
      manifestId: OtaJson.optionalString(object, 'manifestId'),
      selection: object['selection'] === undefined ? undefined : OtaJson.parseStored(object['selection'])
    };
  }

  private static parseSelection(value: Object): OtaSelectionMetadata {
    const object = OtaJson.objectValue(value, 'selection');
    const kind = OtaJson.stringValue(object, 'kind');
    if (kind !== 'full' && kind !== 'gray') throw new Error('invalid_selection_kind');
    return { kind: kind as 'full' | 'gray', ruleId: OtaJson.strictOptionalString(object, 'ruleId'),
      policyRevision: OtaJson.stringValue(object, 'policyRevision'), reason: OtaJson.stringValue(object, 'reason') };
  }

  private static parseStored(value: Object): OtaStoredSelection {
    const object = OtaJson.objectValue(value, 'stored_selection');
    const kind = OtaJson.stringValue(object, 'kind');
    if (kind !== 'full' && kind !== 'gray') throw new Error('invalid_selection_kind');
    return { kind: kind as 'full' | 'gray', audienceKey: OtaJson.strictOptionalString(object, 'audienceKey'),
      ruleId: OtaJson.strictOptionalString(object, 'ruleId'), policyRevision: OtaJson.stringValue(object, 'policyRevision'),
      releaseSequence: OtaJson.stringValue(object, 'releaseSequence'), versionCodeRange: OtaJson.range(object['versionCodeRange']),
      lynxSdkRange: OtaJson.range(object['lynxSdkRange']), minAppVersion: OtaJson.strictOptionalString(object, 'minAppVersion'),
      maxAppVersion: OtaJson.strictOptionalString(object, 'maxAppVersion'), nativeProtocolVersionRange: OtaJson.range(object['nativeProtocolVersionRange']) };
  }

  private static parseDirective(value: Object): OtaSelectionDirective {
    const object = OtaJson.objectValue(value, 'directive');
    const action = OtaJson.stringValue(object, 'action');
    if (action !== 'use_embedded' && action !== 'no_compatible_release') throw new Error('invalid_directive');
    const directive: OtaSelectionDirective = { lynxAppId: OtaJson.stringValue(object, 'lynxAppId'),
      action: action as 'use_embedded' | 'no_compatible_release', policyRevision: OtaJson.stringValue(object, 'policyRevision'),
      reason: OtaJson.stringValue(object, 'reason') };
    OtaSelection.validateDirective(directive);
    return directive;
  }

  private static parseDecision(value: Object): OtaLastDecision {
    const object = OtaJson.objectValue(value, 'last_decision');
    const action = OtaJson.stringValue(object, 'action');
    if (!['use_release', 'use_embedded', 'no_compatible_release'].includes(action)) throw new Error('invalid_decision');
    return { audienceKey: OtaJson.stringValue(object, 'audienceKey'), clientContextKey: OtaJson.stringValue(object, 'clientContextKey'),
      policyRevision: OtaJson.stringValue(object, 'policyRevision'), action: action as 'use_release' | 'use_embedded' | 'no_compatible_release',
      targetReleaseId: OtaJson.strictOptionalString(object, 'targetReleaseId'), reason: OtaJson.stringValue(object, 'reason') };
  }

  private static range(value: Object | undefined): OtaVersionRange | undefined {
    if (value === undefined) return undefined;
    const object = OtaJson.objectValue(value, 'version_range');
    if (Object.keys(object).some((key: string) => key !== 'min' && key !== 'max')) throw new Error('invalid_version_range');
    return { min: OtaJson.strictOptionalString(object, 'min'), max: OtaJson.strictOptionalString(object, 'max') };
  }

  private static platform(root: Record<string, Object>, key: string): string {
    const value = OtaJson.stringValue(root, key);
    if (!['android', 'ios', 'harmony'].includes(value)) throw new Error('invalid_platform');
    return value;
  }

  private static platforms(value: Object | undefined): string[] | undefined {
    if (value === undefined) return undefined;
    if (!Array.isArray(value)) throw new Error('invalid_platforms');
    const result: string[] = [];
    value.forEach((item: Object) => {
      if (typeof item !== 'string' || !['android', 'ios', 'harmony'].includes(item)) throw new Error('invalid_platform');
      result.push(item as string);
    });
    return result;
  }

  private static strictOptionalString(root: Record<string, Object>, key: string): string | undefined {
    return root[key] === undefined ? undefined : OtaJson.stringValue(root, key);
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
    if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value))) throw new Error('invalid_numeric_field');
    return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
  }

  private constructor() {
  }
}
