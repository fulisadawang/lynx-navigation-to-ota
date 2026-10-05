import LynxPageRequest from '../model/LynxPageRequest';

/** 只替换原生栈承载；公开Router、逻辑地址、结果和OTA快照不进入驱动内部。 */
export interface ShellNavigationDriver {
  push(request: LynxPageRequest, replace: boolean): Promise<void>;
  backTo(entryID: string, committed: () => void, failed?: (error: Error) => void, animated?: boolean): void;
  isBusy(): boolean;
  isStaged(entryID: string): boolean;
  contains(entryID: string): boolean;
  depth(): number;
  isCurrent(entryID: string): boolean;
  routeCommitted(viewID: string): void;
  updateBackGesture(viewID: string, enabled: boolean): void;
  markReady(transactionID: string): void;
  transitionState(): Object;
  destroy(): void;
}
