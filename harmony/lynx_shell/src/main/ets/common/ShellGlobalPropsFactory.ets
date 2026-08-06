import { display } from '@kit.ArkUI';
import ShellJson from './ShellJson';
import ShellConstants from './ShellConstants';

/** 构建传给 Lynx 的 globalProps，保留业务字段并补充稳定宿主信息。 */
export default class ShellGlobalPropsFactory {
  static build(businessJson: string): Object {
    const business = ShellJson.parseObject(businessJson) as Record<string, Object>;
    const currentDisplay = display.getDefaultDisplaySync();
    business['platform'] = 'harmony';
    business['lynxVersion'] = '4.0';
    business['hostAppVersion'] = ShellConstants.APP_VERSION;
    business['density'] = currentDisplay.densityPixels;
    business['screenWidthPx'] = currentDisplay.width;
    business['screenHeightPx'] = currentDisplay.height;
    return business;
  }

  private constructor() {
  }
}
