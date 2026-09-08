import OtaApiClient from './OtaApiClient';
import ContentAddressedOtaStore from './ContentAddressedOtaStore';
import { OtaLatestBundleLists, OtaPrepareSignal, OtaReleaseSnapshot } from './OtaModels';
import { OtaUserContext, OtaUserContextBox } from './OtaUserContext';
import { OtaAppSyncFailure, OtaLatestSelection, OtaSelection, OtaSelectionDirective, OtaSelectionSyncError, OtaSelectionSyncResult } from './OtaSelection';

/** 不持有网络长锁：整批协议预检 -> 每 App 决策落盘 -> 每 App 下载，明确部分失败。 */
export default class OtaSelectionSync {
  private readonly api: OtaApiClient;
  private readonly store: ContentAddressedOtaStore;
  private readonly identity: OtaUserContextBox;

  constructor(api: OtaApiClient, store: ContentAddressedOtaStore, identity: OtaUserContextBox) {
    this.api = api;
    this.store = store;
    this.identity = identity;
  }

  async syncAll(signal: OtaPrepareSignal, context: OtaUserContext): Promise<OtaSelectionSyncResult> {
    this.identity.validate(context);
    const response = await this.api.fetchLatestBundleLists(signal, context);
    return this.apply(response, signal, context);
  }

  async syncApp(lynxAppId: string, signal: OtaPrepareSignal, context: OtaUserContext): Promise<OtaSelectionSyncResult> {
    this.identity.validate(context);
    const value = await this.api.fetchLatestSelection(lynxAppId, signal, context);
    const response: OtaLatestBundleLists = { env: context.env, hostApp: context.hostApp, platform: context.platform,
      selectionSchemaVersion: 1, bundleLists: value.release === undefined ? [] : [value.release],
      directives: value.directive === undefined ? [] : [value.directive] };
    return this.apply(response, signal, context);
  }

  async apply(response: OtaLatestBundleLists, signal: OtaPrepareSignal, context: OtaUserContext): Promise<OtaSelectionSyncResult> {
    this.identity.validate(context);
    signal.throwIfCancelled();
    if (context.selectionEnabled && (response.selectionSchemaVersion !== 1 || response.env !== context.env ||
      response.hostApp !== context.hostApp || response.platform !== context.platform)) throw new Error('invalid_selection_scope');
    const seen = new Set<string>();
    response.bundleLists.forEach((release: OtaReleaseSnapshot) => {
      if (context.selectionEnabled) OtaSelection.fromRelease(release, context);
      if (seen.has(release.lynxAppId)) throw new Error('duplicate_selection');
      seen.add(release.lynxAppId);
    });
    const directives = response.directives ?? [];
    directives.forEach((directive: OtaSelectionDirective) => {
      OtaSelection.validateDirective(directive);
      if (seen.has(directive.lynxAppId)) throw new Error('duplicate_selection');
      seen.add(directive.lynxAppId);
    });

    const result: OtaSelectionSyncResult = { completedAppIds: [] };
    const failures: OtaAppSyncFailure[] = [];
    const ready: OtaReleaseSnapshot[] = [];
    for (let index = 0; index < directives.length; index += 1) {
      const directive = directives[index];
      try {
        const value: OtaLatestSelection = { directive: directive };
        this.store.recordDecision(directive.lynxAppId, value, context);
        result.completedAppIds.push(directive.lynxAppId);
      } catch (error) {
        this.identity.validate(context);
        signal.throwIfCancelled();
        failures.push({ lynxAppId: directive.lynxAppId, stage: 'decision', cause: error as Error });
      }
    }
    for (let index = 0; index < response.bundleLists.length; index += 1) {
      const release = response.bundleLists[index];
      try {
        const value: OtaLatestSelection = { release: release };
        if (context.selectionEnabled) this.store.recordDecision(release.lynxAppId, value, context);
        ready.push(release);
      } catch (error) {
        this.identity.validate(context);
        signal.throwIfCancelled();
        failures.push({ lynxAppId: release.lynxAppId, stage: 'decision', cause: error as Error });
      }
    }
    for (let index = 0; index < ready.length; index += 1) {
      const release = ready[index];
      try {
        await this.store.install(release, signal, context);
        this.identity.validate(context);
        signal.throwIfCancelled();
        result.completedAppIds.push(release.lynxAppId);
      } catch (error) {
        this.identity.validate(context);
        signal.throwIfCancelled();
        failures.push({ lynxAppId: release.lynxAppId, stage: 'update', cause: error as Error });
      }
    }
    this.identity.validate(context);
    if (failures.length > 0) throw new OtaSelectionSyncError(result, failures);
    return result;
  }
}
