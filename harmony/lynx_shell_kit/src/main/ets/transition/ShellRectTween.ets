export interface ShellRectTweenValue {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** 接收原始动画或手势进度；曲线在此处应用一次，避免宿主重复缓动。 */
export default class ShellRectTween {
  static mix(from: ShellRectTweenValue, to: ShellRectTweenValue, progress: number, tween: string): ShellRectTweenValue {
    ShellRectTween.validate(from);
    ShellRectTween.validate(to);
    if (!Number.isFinite(progress)) throw new Error('transition_progress_invalid');
    const raw = Math.max(0, Math.min(1, progress));
    const type = tween.trim().toLowerCase();
    const p = ShellRectTween.curveProgress(raw, type);
    const width = Math.max(0.1, ShellRectTween.interpolate(from.width, to.width, p));
    const height = Math.max(0.1, ShellRectTween.interpolate(from.height, to.height, p));
    const startX = from.left + from.width / 2;
    const startY = from.top + from.height / 2;
    const endX = to.left + to.width / 2;
    const endY = to.top + to.height / 2;
    let centerX = ShellRectTween.interpolate(startX, endX, p);
    let centerY = ShellRectTween.interpolate(startY, endY, p);
    if (type === 'materialrectarc') {
      const horizontal = Math.abs(endX - startX) > Math.abs(endY - startY);
      centerX = ShellRectTween.quadratic(startX, horizontal ? endX : startX, endX, p);
      centerY = ShellRectTween.quadratic(startY, horizontal ? startY : endY, endY, p);
    } else if (type === 'materialrectcenterarc') {
      const dx = endX - startX;
      const dy = endY - startY;
      centerX = ShellRectTween.quadratic(startX, startX + dx / 2 - dy * 0.18, endX, p);
      centerY = ShellRectTween.quadratic(startY, startY + dy / 2 + dx * 0.18, endY, p);
    }
    const rect: ShellRectTweenValue = { left: centerX - width / 2, top: centerY - height / 2, width: width, height: height };
    ShellRectTween.validate(rect);
    return rect;
  }

  private static validate(rect: ShellRectTweenValue): void {
    if (!Number.isFinite(rect.left) || !Number.isFinite(rect.top) || !Number.isFinite(rect.width) ||
      !Number.isFinite(rect.height) || rect.width <= 0 || rect.height <= 0) throw new Error('selector_geometry_unavailable');
  }

  private static curveProgress(p: number, tween: string): number {
    let value = p;
    switch (tween) {
      case 'linear': return p;
      case 'materialrectarc':
      case 'materialrectcenterarc': return ShellRectTween.cubicBezier(p, 0.4, 0, 0.2, 1);
      case 'elasticin': value = ShellRectTween.elasticIn(p); break;
      case 'elasticout': value = ShellRectTween.elasticOut(p); break;
      case 'elasticinout': value = p < 0.5 ? ShellRectTween.elasticIn(p * 2) / 2 : ShellRectTween.elasticOut(p * 2 - 1) / 2 + 0.5; break;
      case 'bouncein': value = 1 - ShellRectTween.bounceOut(1 - p); break;
      case 'bounceout': value = ShellRectTween.bounceOut(p); break;
      case 'bounceinout': value = p < 0.5 ? (1 - ShellRectTween.bounceOut(1 - p * 2)) / 2 : (1 + ShellRectTween.bounceOut(p * 2 - 1)) / 2; break;
      default:
        const match = /^cubic-bezier\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)$/.exec(tween);
        if (match === null) throw new Error('rectTweenType 不合法');
        const x1 = Number(match[1]);
        const y1 = Number(match[2]);
        const x2 = Number(match[3]);
        const y2 = Number(match[4]);
        if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(x2) || !Number.isFinite(y2) ||
          x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1 || y1 < -4 || y1 > 4 || y2 < -4 || y2 > 4) throw new Error('rectTweenType 不合法');
        value = ShellRectTween.cubicBezier(p, x1, y1, x2, y2);
    }
    // 与 Android 一致地限制弹性及自定义曲线的过冲，仍保留回弹轨迹。
    return Math.max(-0.35, Math.min(1.35, value));
  }

  private static elasticIn(p: number): number {
    if (p === 0 || p === 1) return p;
    return -Math.pow(2, 10 * p - 10) * Math.sin((p * 10 - 10.75) * (2 * Math.PI / 3));
  }

  private static elasticOut(p: number): number {
    if (p === 0 || p === 1) return p;
    return Math.pow(2, -10 * p) * Math.sin((p * 10 - 0.75) * (2 * Math.PI / 3)) + 1;
  }

  private static bounceOut(p: number): number {
    if (p < 1 / 2.75) return 7.5625 * p * p;
    if (p < 2 / 2.75) { const v = p - 1.5 / 2.75; return 7.5625 * v * v + 0.75; }
    if (p < 2.5 / 2.75) { const v = p - 2.25 / 2.75; return 7.5625 * v * v + 0.9375; }
    const v = p - 2.625 / 2.75;
    return 7.5625 * v * v + 0.984375;
  }

  private static cubicBezier(p: number, x1: number, y1: number, x2: number, y2: number): number {
    if (p === 0 || p === 1) return p;
    let low = 0;
    let high = 1;
    // 反解 x 后采样 y；二分避免平坦控制点令 Newton 导数接近零。
    for (let i = 0; i < 16; i += 1) {
      const t = (low + high) / 2;
      if (ShellRectTween.cubicCoordinate(t, x1, x2) < p) low = t;
      else high = t;
    }
    return ShellRectTween.cubicCoordinate((low + high) / 2, y1, y2);
  }

  private static cubicCoordinate(p: number, first: number, second: number): number {
    const inverse = 1 - p;
    return 3 * inverse * inverse * p * first + 3 * inverse * p * p * second + p * p * p;
  }

  private static quadratic(from: number, control: number, to: number, p: number): number {
    const inverse = 1 - p;
    return inverse * inverse * from + 2 * inverse * p * control + p * p * to;
  }

  private static interpolate(from: number, to: number, p: number): number {
    return from + (to - from) * p;
  }
}
