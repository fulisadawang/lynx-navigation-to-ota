import ReleaseTransaction from './ReleaseTransaction';
import { OtaStorageSnapshot } from './OtaModels';

/**
 * HarmonyOS OTA Store v2 的只读诊断入口。
 *
 * Inspector 只能绑定 Runtime 已经创建的 ReleaseTransaction，不接受外部路径；快照不会
 * 请求网络、计算 SHA、清理 orphan 或修改任何文件。
 */
export default class OtaStorageDiagnostics {
  private readonly transaction: ReleaseTransaction;

  constructor(transaction: ReleaseTransaction) {
    this.transaction = transaction;
  }

  snapshot(maxFilesPerTree: number = 2_000): OtaStorageSnapshot {
    return this.transaction.storageSnapshot(maxFilesPerTree);
  }
}
