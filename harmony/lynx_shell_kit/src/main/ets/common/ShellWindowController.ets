import window from '@ohos.window';
import deviceInfo from '@ohos.deviceInfo';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { LLog } from '@lynx/lynx';
import ShellConstants from './ShellConstants';
import LynxPageRequest from '../model/LynxPageRequest';

interface WindowPolicyBaseline {
  orientation: window.Orientation;
  keyboard: KeyboardAvoidMode;
  layoutFullscreen: boolean;
}

/** 页面窗口策略由实际栈顶申请；异步系统调用串行并只继续最新代次。 */
export default class ShellWindowController {
  private static sequence: number = 0;
  private static serial: Promise<void> = Promise.resolve();
  private static readonly baselines: WeakMap<window.Window, WindowPolicyBaseline> = new WeakMap();

  static apply(request: LynxPageRequest): void {
    ShellWindowController.applyAsync(request).catch((error: Object): void => {
      LLog.e(ShellConstants.TAG, 'apply window option failed: ' + String(error));
    });
  }
  static restore(): void {
    ShellWindowController.restoreAsync().catch((error: Object): void => {
      LLog.e(ShellConstants.TAG, 'restore window option failed: ' + String(error));
    });
  }
  static applyAsync(request: LynxPageRequest): Promise<void> { return ShellWindowController.schedule(request); }
  static restoreAsync(): Promise<void> { return ShellWindowController.schedule(null); }

  private static schedule(request: LynxPageRequest | null): Promise<void> {
    const generation = ++ShellWindowController.sequence;
    const stage = AppStorage.get<window.WindowStage>(ShellConstants.STORAGE_WINDOW_STAGE);
    if (stage === undefined) return Promise.reject(new Error('native_window_unavailable'));
    const operation = ShellWindowController.serial.then(async (): Promise<void> => {
      if (generation !== ShellWindowController.sequence) return;
      const currentWindow = await stage.getMainWindow();
      if (generation !== ShellWindowController.sequence || stage !== AppStorage.get<window.WindowStage>(ShellConstants.STORAGE_WINDOW_STAGE)) return;
      const ui = currentWindow.getUIContext();
      let baseline = ShellWindowController.baselines.get(currentWindow);
      if (baseline === undefined) {
        baseline = { orientation: currentWindow.getPreferredOrientation(), keyboard: ui.getKeyboardAvoidMode(),
          layoutFullscreen: currentWindow.getWindowProperties().isLayoutFullScreen };
        ShellWindowController.baselines.set(currentWindow, baseline);
      }
      const orientation = request === null ? baseline.orientation : request.orientation === 'portrait' ?
        window.Orientation.PORTRAIT : request.orientation === 'landscape' ? window.Orientation.LANDSCAPE :
          window.Orientation.AUTO_ROTATION_RESTRICTED;
      const keyboardMode = request === null ? baseline.keyboard : ShellWindowController.keyboardAvoidMode(request.keyboardBehavior);
      await currentWindow.setPreferredOrientation(orientation);
      if (generation !== ShellWindowController.sequence) return;
      // 未声明fullscreen不关闭宿主原有edge布局，自绘导航仍消费容器相对安全区。
      await currentWindow.setWindowLayoutFullScreen(baseline.layoutFullscreen || request?.fullscreen === true);
      if (generation !== ShellWindowController.sequence) return;
      ui.setKeyboardAvoidMode(keyboardMode);
      // Demo基线保留系统导航条；页面只控制状态栏，原生标题栏由Lynx自绘。
      await currentWindow.setWindowSystemBarEnable(request?.hideStatusBar === true ? ['navigation'] : ['status', 'navigation']);
    });
    // 一个真实失败不阻塞后续正确策略；该次失败仍通过原Promise交付调用方。
    ShellWindowController.serial = operation.catch((_error: Object): void => {});
    return operation;
  }

  private static keyboardAvoidMode(value: string): KeyboardAvoidMode {
    switch (value.trim().toLowerCase()) {
      case 'resize': return KeyboardAvoidMode.RESIZE;
      case 'nothing':
      case 'none':
        if (deviceInfo.sdkApiVersion < 14) throw new Error('keyboard_behavior_nothing_requires_api14');
        return KeyboardAvoidMode.NONE;
      case 'pan':
      case 'system':
      default: return KeyboardAvoidMode.OFFSET;
    }
  }
  private constructor() {}
}
