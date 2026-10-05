import ShellRoutePresentationSpec from './ShellRoutePresentationSpec';

export interface ShellPresetTransform { x: number; y: number; scale: number; alpha: number; }
export interface ShellPresetFrames { primary: ShellPresetTransform; secondary: ShellPresetTransform; }

/** p始终是页面已展示进度，push/pop与手势使用同一曲线和同一原生帧入口。 */
export default class ShellPresetFrame {
  static at(spec: ShellRoutePresentationSpec, p: number, width: number, height: number, primaryHeight: number, linked: boolean): ShellPresetFrames {
    const primary: ShellPresetTransform = { x: 0, y: 0, scale: 1, alpha: 1 };
    const secondary: ShellPresetTransform = { x: 0, y: 0, scale: 1, alpha: 1 };
    switch (spec.mode) {
      case 'bottomSheet': primary.y = primaryHeight * (1 - p); secondary.scale = 1 - p * 0.04; secondary.y = p * 8; break;
      case 'heroSheet': break;
      case 'cupertinoModal': primary.y = primaryHeight * (1 - p); primary.alpha = p; secondary.scale = 1 - p * 0.06; secondary.y = p * 12; break;
      case 'cupertinoModalInside': primary.x = width * (1 - p); primary.alpha = 0.86 + p * 0.14; secondary.x = -width * p * 0.24; break;
      case 'modalNavigation': primary.x = width * (1 - p); primary.scale = 0.98 + p * 0.02; primary.alpha = 0.92 + p * 0.08; secondary.x = -width * p * 0.18; break;
      case 'modal': primary.scale = 0.72 + p * 0.28; primary.alpha = p; secondary.scale = 1 - p * 0.03; break;
      case 'page':
        if (spec.routeType === 'wx://upwards') { primary.y = height * (1 - p); primary.alpha = 0.96 + p * 0.04; secondary.scale = 1 - p * 0.02; }
        else if (spec.routeType === 'wx://zoom') { primary.scale = 0.78 + p * 0.22; primary.alpha = p; secondary.alpha = 1 - p * 0.2; }
        break;
    }
    if (!linked) { secondary.x = 0; secondary.y = 0; secondary.scale = 1; secondary.alpha = 1; }
    return { primary: primary, secondary: secondary };
  }
}
