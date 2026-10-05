import { ShellBridgeResult } from '../common/ShellTypes';
import PageBundleRuntimeRegistry, { PageBundleRuntime, PreparedPageBundle } from '../ota/OtaModels';

interface OtaHealthyData { confirmed: boolean; reason: string; releaseId?: string; }

/** 一个实际 Context/load generation 的首屏与业务双信号，迟到回调不能提交另一代页面。 */
export default class LynxOtaHealthGate {
  private firstScreen: boolean = false;
  private businessHealthy: boolean = false;
  private confirming: boolean = false;
  private confirmed: boolean = false;
  private failed: boolean = false;
  private runtime: PageBundleRuntime | null = null;
  private prepared: PreparedPageBundle | null = null;
  private callback: ((result: ShellBridgeResult) => void) | null = null;
  private readonly currentGeneration: () => boolean;

  constructor(currentGeneration: () => boolean) { this.currentGeneration = currentGeneration; }

  configure(runtime: PageBundleRuntime, prepared: PreparedPageBundle): void {
    this.runtime = runtime; this.prepared = prepared;
  }

  markFirstScreen(): void {
    if (this.failed || !this.currentGeneration()) return;
    this.firstScreen = true;
    this.tryConfirm();
  }

  markBusinessHealthy(callback: (result: ShellBridgeResult) => void): void {
    if (this.failed || !this.currentGeneration()) { callback({ code: 1002, message: '来源页面或加载代次已失效' }); return; }
    const prepared = this.prepared;
    if (prepared === null || prepared.source !== 'candidate_trial') {
      const data: OtaHealthyData = { confirmed: false, reason: 'not_candidate' };
      callback({ code: 0, message: '当前页面不属于候选试运行', data: data }); return;
    }
    if (this.confirmed) {
      const data: OtaHealthyData = { confirmed: true, reason: 'already_confirmed', releaseId: prepared.releaseId };
      callback({ code: 0, message: '候选已确认', data: data }); return;
    }
    if (this.callback !== null || this.confirming) { callback({ code: 1006, message: '健康确认正在等待首屏或提交' }); return; }
    this.businessHealthy = true;
    this.callback = callback;
    this.tryConfirm();
  }

  isCandidateTrial(): boolean { return this.prepared?.source === 'candidate_trial' && !this.confirmed; }

  fail(message: string = '来源页面已销毁或加载失败'): void {
    this.failed = true; this.confirming = false;
    const callback = this.callback; this.callback = null;
    callback?.({ code: 1002, message: message });
  }

  private tryConfirm(): void {
    if (this.failed || this.confirmed || this.confirming || !this.firstScreen || !this.businessHealthy) return;
    const runtime = this.runtime;
    const prepared = this.prepared;
    if (runtime === null || prepared === null || runtime !== PageBundleRuntimeRegistry.current() ||
      runtime.userIdentityEpoch !== prepared.userIdentityEpoch || !this.currentGeneration()) { this.fail(); return; }
    this.confirming = true;
    runtime.confirmCandidateHealthy(prepared.lynxAppId, prepared.releaseId, prepared.userIdentityEpoch, () => !this.failed && this.currentGeneration(), prepared.manifestId).then((confirmed: boolean) => {
      if (this.failed || !this.currentGeneration() || runtime !== PageBundleRuntimeRegistry.current() || runtime.userIdentityEpoch !== prepared.userIdentityEpoch) { this.fail(); return; }
      this.confirming = false;
      const callback = this.callback; this.callback = null;
      if (!confirmed) { this.failed = true; callback?.({ code: 1003, message: '候选已变化或健康提交未完成' }); return; }
      this.confirmed = true;
      const data: OtaHealthyData = { confirmed: true, reason: 'confirmed', releaseId: prepared.releaseId };
      callback?.({ code: 0, message: '候选健康确认已提交', data: data });
    }).catch((error: Error) => {
      if (this.failed) return;
      if (!this.currentGeneration()) { this.fail(); return; }
      this.confirming = false;
      const callback = this.callback; this.callback = null;
      callback?.({ code: 1003, message: `候选健康提交失败：${error.message}` });
    });
  }
}
