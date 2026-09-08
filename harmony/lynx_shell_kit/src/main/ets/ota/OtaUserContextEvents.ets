/** 只传身份代际，不传业务 userId；普通后台同步不触发 Tab 重载事件。 */
export default class OtaUserContextEvents {
  private static listeners: Array<(epoch: number) => void> = [];

  static subscribe(listener: (epoch: number) => void): void {
    if (!OtaUserContextEvents.listeners.includes(listener)) OtaUserContextEvents.listeners.push(listener);
  }

  static unsubscribe(listener: (epoch: number) => void): void {
    OtaUserContextEvents.listeners = OtaUserContextEvents.listeners.filter((item) => item !== listener);
  }

  static emit(epoch: number): void {
    OtaUserContextEvents.listeners.slice().forEach((listener) => {
      try { listener(epoch); } catch (error) { console.warn('LynxShellOTA 用户状态监听失败'); }
    });
  }

  private constructor() {}
}
