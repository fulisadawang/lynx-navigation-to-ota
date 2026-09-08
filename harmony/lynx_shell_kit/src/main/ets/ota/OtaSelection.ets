import { OtaReleaseSnapshot } from './OtaModels';
import { OtaUserContext } from './OtaUserContext';

/** Wire/State 选择类型；不引入 Harmony candidate/trial。 */
export interface OtaVersionRange { min?: string; max?: string; }
export interface OtaSelectionMetadata { kind: 'full' | 'gray'; ruleId?: string; policyRevision: string; reason: string; }
export interface OtaStoredSelection {
  kind: 'full' | 'gray';
  audienceKey?: string;
  ruleId?: string;
  policyRevision: string;
  releaseSequence: string;
  versionCodeRange?: OtaVersionRange;
  lynxSdkRange?: OtaVersionRange;
  minAppVersion?: string;
  maxAppVersion?: string;
  nativeProtocolVersionRange?: OtaVersionRange;
}
export interface OtaSelectionDirective {
  lynxAppId: string;
  action: 'use_embedded' | 'no_compatible_release';
  policyRevision: string;
  reason: string;
}
export interface OtaLastDecision {
  audienceKey: string;
  clientContextKey: string;
  policyRevision: string;
  action: 'use_release' | 'use_embedded' | 'no_compatible_release';
  targetReleaseId?: string;
  reason: string;
}
export interface OtaLatestSelection { release?: OtaReleaseSnapshot; directive?: OtaSelectionDirective; }
export interface OtaAppSyncFailure { lynxAppId: string; stage: 'decision' | 'update'; cause: Error; }
export interface OtaSelectionSyncResult { completedAppIds: string[]; }
export class OtaSelectionSyncError extends Error {
  readonly partialResult: OtaSelectionSyncResult;
  readonly failures: OtaAppSyncFailure[];
  constructor(partialResult: OtaSelectionSyncResult, failures: OtaAppSyncFailure[]) {
    super(`OTA partial_batch_failure: ${failures.length}`);
    this.partialResult = partialResult;
    this.failures = failures;
  }
}

/** 协议预检独立于实际兼容性：先提交合法决定，再逐 App 隔离更新失败。 */
export class OtaSelection {
  static fromRelease(release: OtaReleaseSnapshot, context: OtaUserContext): OtaStoredSelection {
    const selection = release.selection;
    const sequence = release.releaseSequence;
    if (release.selectionSchemaVersion !== 1 || selection === undefined || sequence === undefined) throw new Error('missing_selection_metadata');
    if (release.env !== context.env || release.hostApp !== context.hostApp || release.platform !== 'harmony' ||
      !/^[0-9]{8}$/.test(release.lynxAppId) || release.status !== 'ACTIVE') throw new Error('invalid_selection_scope');
    OtaUserContext.decimal(sequence);
    OtaUserContext.decimal(selection.policyRevision, true);
    if (!['latest_full', 'matched_gray', 'server_rollback'].includes(selection.reason) ||
      (selection.kind !== 'full' && selection.kind !== 'gray') ||
      (selection.kind === 'gray' && (context.userId === undefined || !selection.ruleId))) throw new Error('invalid_selection_metadata');
    OtaSelection.validateRange(release.versionCodeRange, true);
    OtaSelection.validateRange(release.lynxSdkRange, false);
    const appRange: OtaVersionRange = { min: release.minAppVersion, max: release.maxAppVersion };
    OtaSelection.validateRange(appRange, false);
    OtaSelection.validateRange(release.nativeProtocolVersionRange, false);
    return { kind: selection.kind, audienceKey: selection.kind === 'gray' ? context.audienceKey : undefined,
      ruleId: selection.ruleId, policyRevision: selection.policyRevision, releaseSequence: sequence,
      versionCodeRange: release.versionCodeRange, lynxSdkRange: release.lynxSdkRange,
      minAppVersion: release.minAppVersion, maxAppVersion: release.maxAppVersion,
      nativeProtocolVersionRange: release.nativeProtocolVersionRange };
  }

  static validateDirective(value: OtaSelectionDirective): void {
    if (!/^[0-9]{8}$/.test(value.lynxAppId) || !['use_embedded', 'no_compatible_release'].includes(value.action) ||
      value.reason.trim().length === 0) throw new Error('invalid_selection_metadata');
    OtaUserContext.decimal(value.policyRevision, true);
  }

  static decision(value: OtaLatestSelection, context: OtaUserContext): OtaLastDecision {
    if ((value.release === undefined) === (value.directive === undefined)) throw new Error('invalid_selection_metadata');
    if (value.release !== undefined) {
      OtaSelection.fromRelease(value.release, context);
      return { audienceKey: context.audienceKey, clientContextKey: context.clientContextKey,
        policyRevision: value.release.selection!.policyRevision, action: 'use_release',
        targetReleaseId: value.release.releaseId, reason: value.release.selection!.reason };
    }
    const directive = value.directive!;
    OtaSelection.validateDirective(directive);
    return { audienceKey: context.audienceKey, clientContextKey: context.clientContextKey,
      policyRevision: directive.policyRevision, action: directive.action, reason: directive.reason };
  }

  static sameDecision(left: OtaLastDecision | undefined, right: OtaLastDecision): boolean {
    return left !== undefined && left.audienceKey === right.audienceKey && left.clientContextKey === right.clientContextKey &&
      OtaUserContext.compareDecimal(left.policyRevision, right.policyRevision) === 0 && left.action === right.action &&
      left.targetReleaseId === right.targetReleaseId;
  }

  static compatible(selection: OtaStoredSelection | undefined, context: OtaUserContext): boolean {
    if (selection === undefined) return false;
    try {
      OtaUserContext.decimal(selection.releaseSequence);
      OtaUserContext.decimal(selection.policyRevision, true);
      const appRange: OtaVersionRange = { min: selection.minAppVersion, max: selection.maxAppVersion };
      return (selection.kind === 'full' || (selection.kind === 'gray' && context.userId !== undefined && selection.audienceKey === context.audienceKey)) &&
        OtaSelection.matches(context.versionCode, selection.versionCodeRange, true) &&
        OtaSelection.matches(context.lynxSdkVersion, selection.lynxSdkRange, false) &&
        OtaSelection.matches(context.appVersion, appRange, false) &&
        OtaSelection.matches(context.nativeProtocolVersion, selection.nativeProtocolVersionRange, false);
    } catch (error) { return false; }
  }

  static validateRange(range: OtaVersionRange | undefined, code: boolean): void {
    if (range === undefined) return;
    if (range.min !== undefined) { if (code) OtaUserContext.normalizeVersionCode(range.min); else OtaUserContext.normalizeLynxSdkVersion(range.min); }
    if (range.max !== undefined) { if (code) OtaUserContext.normalizeVersionCode(range.max); else OtaUserContext.normalizeLynxSdkVersion(range.max); }
    if (range.min !== undefined && range.max !== undefined && OtaSelection.compare(range.min, range.max, code) > 0) throw new Error('invalid_version_range');
  }

  private static matches(value: string | undefined, range: OtaVersionRange | undefined, code: boolean): boolean {
    OtaSelection.validateRange(range, code);
    if (range === undefined || (range.min === undefined && range.max === undefined)) return true;
    if (value === undefined) return false;
    return (range.min === undefined || OtaSelection.compare(value, range.min, code) >= 0) &&
      (range.max === undefined || OtaSelection.compare(value, range.max, code) <= 0);
  }

  private static compare(left: string, right: string, code: boolean): number {
    return code ? OtaUserContext.compareDecimal(OtaUserContext.normalizeVersionCode(left), OtaUserContext.normalizeVersionCode(right)) :
      OtaUserContext.compareVersion(left, right);
  }
}
