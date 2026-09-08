/** epoch-owned 的进程内检查门控；旧任务不能修改新身份的时间戳或占位。 */
export default class OtaPageRefreshGate {
  private epoch: number;
  private lastSuccess: Map<string, number> = new Map();
  private reservations: Map<string, number> = new Map();

  constructor(epoch: number) { this.epoch = epoch; }

  reset(epoch: number): void { this.epoch = epoch; this.lastSuccess.clear(); this.reservations.clear(); }

  reserve(appId: string, epoch: number, now: number, interval: number): boolean {
    if (epoch !== this.epoch || this.reservations.has(appId)) return false;
    const last = this.lastSuccess.get(appId);
    if (last !== undefined && interval > 0 && now - last < interval) return false;
    this.reservations.set(appId, epoch);
    return true;
  }

  complete(appId: string, epoch: number): void {
    if (this.reservations.get(appId) === epoch) this.reservations.delete(appId);
  }

  markSuccess(appId: string, epoch: number, now: number): void {
    if (epoch === this.epoch) this.lastSuccess.set(appId, now);
  }

  clearApp(appId: string, epoch: number): void {
    if (epoch !== this.epoch) return;
    this.lastSuccess.delete(appId); this.reservations.delete(appId);
  }

  clearAll(epoch: number): void {
    if (epoch === this.epoch) { this.lastSuccess.clear(); this.reservations.clear(); }
  }
}
