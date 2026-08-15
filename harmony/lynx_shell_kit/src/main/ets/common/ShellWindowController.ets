import window from '@ohos.window';
import deviceInfo from '@ohos.deviceInfo';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { LLog } from '@lynx/lynx';
import ShellConstants from './ShellConstants';
import LynxPageRequest from '../model/LynxPageRequest';

/**
 * 管理页面级窗口选项。壳页面退出时恢复默认值，避免方向和系统栏状态污染后续原生页面。
 */
export default class ShellWindowController {
  static apply(request: LynxPageRequest): void {
    const stage = AppStorage.get<window.WindowStage>(ShellConstants.STORAGE_WINDOW_STAGE);
    if (stage === undefined) {
      return;
    }
    stage.getMainWindow().then((currentWindow: window.Window) => {
      if (request.orientation === 'portrait') {
        currentWindow.setPreferredOrientation(window.Orientation.PORTRAIT);
      } else if (request.orientation === 'landscape') {
        currentWindow.setPreferredOrientation(window.Orientation.LANDSCAPE);
      } else {
        currentWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
      }

      currentWindow.getUIContext().setKeyboardAvoidMode(
        ShellWindowController.keyboardAvoidMode(request.keyboardBehavior)
      );

      if (request.hideStatusBar) {
        currentWindow.setWindowSystemBarEnable(['navigation']);
      } else {
        currentWindow.setWindowSystemBarEnable(['status', 'navigation']);
      }
    }).catch((error: Error) => {
      LLog.e(ShellConstants.TAG, `apply window option failed: ${error.message}`);
    });
  }

  static restore(): void {
    const stage = AppStorage.get<window.WindowStage>(ShellConstants.STORAGE_WINDOW_STAGE);
    if (stage === undefined) {
      return;
    }
    stage.getMainWindow().then((currentWindow: window.Window) => {
      currentWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
      // 不能让当前 Lynx Page 的键盘策略污染后续宿主页面；ArkUI 默认是 OFFSET。
      currentWindow.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      currentWindow.setWindowSystemBarEnable(['status', 'navigation']);
    }).catch((error: Error) => {
      LLog.e(ShellConstants.TAG, `restore window option failed: ${error.message}`);
    });
  }

  private static keyboardAvoidMode(value: string): KeyboardAvoidMode {
    switch (value.trim().toLowerCase()) {
      case 'resize':
        return KeyboardAvoidMode.RESIZE;
      case 'nothing':
      case 'none':
        // KeyboardAvoidMode.NONE 从 API 14 提供；API 13 设备降级到系统 OFFSET，避免
        // 在旧系统上请求不存在的避让模式。升级 compatibleSdkVersion 后即可获得真正的 NONE。
        return deviceInfo.sdkApiVersion >= 14 ? KeyboardAvoidMode.NONE : KeyboardAvoidMode.OFFSET;
      case 'pan':
      case 'system':
      default:
        return KeyboardAvoidMode.OFFSET;
    }
  }

  private constructor() {
  }
}
