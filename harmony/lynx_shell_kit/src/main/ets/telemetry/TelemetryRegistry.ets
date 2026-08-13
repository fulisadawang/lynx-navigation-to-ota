import TelemetryCoordinator from './TelemetryCoordinator';

/**
 * Harmony UIAbility 前后台适配器的最小注册表。
 *
 * Ability/宿主负责调用 LynxRouter.onApplicationForeground/Background；Page 只注册自己的
 * Coordinator，避免把 App 生命周期和单个 ArkUI Page 的 aboutToAppear 混成一个状态。
 */
export default class TelemetryRegistry {
  private static coordinators: TelemetryCoordinator[] = [];

  static register(coordinator: TelemetryCoordinator): void {
    if (TelemetryRegistry.coordinators.indexOf(coordinator) < 0) {
      TelemetryRegistry.coordinators.push(coordinator);
    }
  }

  static unregister(coordinator: TelemetryCoordinator): void {
    TelemetryRegistry.coordinators = TelemetryRegistry.coordinators.filter(
      (item: TelemetryCoordinator) => item !== coordinator
    );
  }

  static onApplicationForeground(): void {
    TelemetryRegistry.coordinators.slice().forEach((item: TelemetryCoordinator) => {
      item.onApplicationForeground();
    });
  }

  static onApplicationBackground(): void {
    TelemetryRegistry.coordinators.slice().forEach((item: TelemetryCoordinator) => {
      item.onApplicationBackground();
    });
  }
}
