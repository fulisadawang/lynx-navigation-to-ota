import window from '@ohos.window';
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
      currentWindow.setWindowSystemBarEnable(['status', 'navigation']);
    }).catch((error: Error) => {
      LLog.e(ShellConstants.TAG, `restore window option failed: ${error.message}`);
    });
  }

  private constructor() {
  }
}
