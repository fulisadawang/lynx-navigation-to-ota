import ShellRoutePresentationSpec from './ShellRoutePresentationSpec';
import ShellTransitionColor from './ShellTransitionColor';
export type ShellTransitionStyle = 'default' | 'none' | 'fade' | 'slide' | 'slideUp' | 'zoom' | 'sharedElement' | 'openContainer';
export interface ShellRectStyle { backgroundColor?: string; cornerRadius?: number; elevation?: number; }
export interface ShellSharedElement {
  key: string; sourceSelector: string; targetSelector: string; transitionOnGesture: boolean;
  shuttleOnPush: 'from' | 'to'; shuttleOnPop: 'from' | 'to'; rectTweenType: string; sourceStyle?: ShellRectStyle; targetStyle?: ShellRectStyle;
}
export interface ShellOpenContainer {
  sourceSelector: string; closedColor: string; middleColor?: string; openColor: string;
  closedCornerRadius: number; openCornerRadius: number; closedElevation: number; openElevation: number;
  transitionType: 'fade' | 'fadeThrough'; transitionDuration: number;
}
export interface ShellPopGesture {
  enabled: boolean; direction: 'horizontal' | 'vertical' | 'multi'; fullScreen: boolean; edgeWidth: number;
}

/** 与双端现有 wire 参数一致；动态 JSON 必须先核实再进入原生绘制/导航。 */
export default class ShellTransitionSpec {
  presentation: ShellRoutePresentationSpec = new ShellRoutePresentationSpec();
  style: ShellTransitionStyle = 'default'; duration: number = 300; reverseDuration: number = 300; readyTimeout: number = 1000;
  fallback: 'fade' | 'slide' | 'none' = 'fade'; sharedElements: ShellSharedElement[] = [];
  openContainer?: ShellOpenContainer;
  popGesture: ShellPopGesture = { enabled: true, direction: 'horizontal', fullScreen: false, edgeWidth: 28 };

  static parse(value: Object | undefined, routeConfig?: Object): ShellTransitionSpec {
    const spec = new ShellTransitionSpec();
    const empty: Record<string, Object> = {};
    const raw = value === undefined ? empty : ShellTransitionSpec.object(value);
    const style = ShellTransitionSpec.text(raw, 'style', 'default');
    if (!['default', 'none', 'fade', 'slide', 'slideUp', 'zoom', 'sharedElement', 'openContainer'].includes(style)) throw new Error('transition.style 不合法');
    spec.style = style as ShellTransitionStyle;
    spec.duration = ShellTransitionSpec.number(raw, 'durationMs', 300, 0, 5000);
    spec.readyTimeout = ShellTransitionSpec.number(raw, 'readyTimeoutMs', 1000, 80, 1500);
    const fallback = ShellTransitionSpec.text(raw, 'fallbackStyle', 'fade');
    if (!['fade', 'slide', 'none'].includes(fallback)) throw new Error('transition.fallback 只能是 fade/slide/none');
    spec.fallback = fallback as 'fade' | 'slide' | 'none';
    if ((raw['sharedElements'] === undefined || Array.isArray(raw['sharedElements']) && (raw['sharedElements'] as Object[]).length === 0) && raw['sharedElement'] !== undefined) raw['sharedElements'] = [raw['sharedElement']];
    if (raw['sharedElements'] !== undefined) {
      if (!Array.isArray(raw['sharedElements']) || (raw['sharedElements'] as Object[]).length > 8) throw new Error('sharedElements 最多8项');
      const keys = new Set<string>();
      (raw['sharedElements'] as Object[]).forEach((entry: Object) => {
        const item = ShellTransitionSpec.object(entry);
        const key = ShellTransitionSpec.required(item, 'key');
        if (keys.has(key)) throw new Error('sharedElements.key 必须唯一');
        keys.add(key);
        const push = ShellTransitionSpec.text(item, 'shuttleOnPush', 'to');
        const pop = ShellTransitionSpec.text(item, 'shuttleOnPop', 'to');
        if (!['from', 'to'].includes(push) || !['from', 'to'].includes(pop)) throw new Error('shuttle 只能是 from/to');
        const tween = ShellTransitionSpec.text(item, 'rectTweenType', 'materialRectArc');
        if (!['linear', 'materialRectArc', 'materialRectCenterArc', 'elasticIn', 'elasticOut', 'elasticInOut', 'bounceIn', 'bounceOut', 'bounceInOut'].includes(tween) &&
          !/^cubic-bezier\(\s*(?:-?\d+(?:\.\d+)?\s*,\s*){3}-?\d+(?:\.\d+)?\s*\)$/.test(tween)) throw new Error('rectTweenType 不合法');
        if (tween.startsWith('cubic-bezier')) {
          const parts = tween.substring(tween.indexOf('(') + 1, tween.length - 1).split(',').map((v) => Number(v.trim()));
          if (!parts.every((v) => Number.isFinite(v)) || parts[0] < 0 || parts[0] > 1 || parts[2] < 0 || parts[2] > 1 || Math.abs(parts[1]) > 4 || Math.abs(parts[3]) > 4) throw new Error('rectTweenType 控制点越界');
        }
        spec.sharedElements.push({ key: key, sourceSelector: ShellTransitionSpec.selector(ShellTransitionSpec.required(item, 'sourceSelector')),
          targetSelector: ShellTransitionSpec.selector(ShellTransitionSpec.required(item, 'targetSelector')),
          transitionOnGesture: ShellTransitionSpec.boolean(item, 'transitionOnGesture', false),
          shuttleOnPush: push as 'from' | 'to', shuttleOnPop: pop as 'from' | 'to', rectTweenType: tween, sourceStyle: ShellTransitionSpec.rectStyle(item['sourceStyle']), targetStyle: ShellTransitionSpec.rectStyle(item['targetStyle']) });
      });
    }
    if (spec.style === 'sharedElement' && spec.sharedElements.length === 0) throw new Error('sharedElement 缺少元素');
    if (raw['openContainer'] !== undefined) {
      const open = ShellTransitionSpec.object(raw['openContainer']);
      const type = ShellTransitionSpec.text(open, 'transitionType', ShellTransitionSpec.text(open, 'contentTransition', 'fade'));
      if (!['fade', 'fadeThrough'].includes(type)) throw new Error('openContainer.transitionType 不合法');
      spec.openContainer = { sourceSelector: ShellTransitionSpec.selector(ShellTransitionSpec.required(open, 'sourceSelector')),
        closedColor: ShellTransitionSpec.color(open, 'closedColor', 'white'), middleColor: open['middleColor'] === undefined ? undefined : ShellTransitionSpec.color(open, 'middleColor', 'white'),
        openColor: ShellTransitionSpec.color(open, 'openColor', 'white'),
        closedCornerRadius: ShellTransitionSpec.number(open, 'closedCornerRadius', 0, 0, 256), openCornerRadius: ShellTransitionSpec.number(open, 'openCornerRadius', 0, 0, 256),
        closedElevation: ShellTransitionSpec.number(open, 'closedElevation', 0, 0, 64), openElevation: ShellTransitionSpec.number(open, 'openElevation', 0, 0, 64),
        transitionType: type as 'fade' | 'fadeThrough', transitionDuration: ShellTransitionSpec.number(open, 'transitionDuration', 300, 0, 5000) };
      if (raw['durationMs'] === undefined) spec.duration = spec.openContainer.transitionDuration;
    }
    if (spec.style === 'openContainer' && spec.openContainer === undefined) throw new Error('openContainer 缺少声明');
    if (raw['popGesture'] !== undefined) {
      const gesture = ShellTransitionSpec.object(raw['popGesture']);
      const direction = ShellTransitionSpec.text(gesture, 'direction', 'horizontal');
      if (!['horizontal', 'vertical', 'multi'].includes(direction)) throw new Error('popGesture.direction 不合法');
      spec.popGesture = { enabled: ShellTransitionSpec.boolean(gesture, 'enabled', true), direction: direction as 'horizontal' | 'vertical' | 'multi',
        fullScreen: ShellTransitionSpec.boolean(gesture, 'fullScreen', false), edgeWidth: ShellTransitionSpec.number(gesture, 'edgeWidth', 28, 16, 72) };
    }
    const route = routeConfig === undefined ? undefined : ShellTransitionSpec.object(routeConfig);
    if (route !== undefined) {
      spec.duration = ShellTransitionSpec.number(route, 'transitionDuration', spec.duration, 0, 5000);
      spec.reverseDuration = ShellTransitionSpec.number(route, 'reverseTransitionDuration', spec.duration, 0, 5000);
    } else { spec.reverseDuration = spec.duration; }
    if (![spec.duration, spec.reverseDuration, spec.readyTimeout, spec.openContainer?.transitionDuration ?? 0].every((v) => Number.isInteger(v))) throw new Error('转场时长必须是整数毫秒');
    return spec;
  }

  private static rectStyle(value: Object | undefined): ShellRectStyle | undefined {
    if (value === undefined) return undefined;
    const raw = ShellTransitionSpec.object(value);
    return { backgroundColor: raw['backgroundColor'] === undefined ? undefined : ShellTransitionSpec.color(raw, 'backgroundColor', 'transparent'),
      cornerRadius: raw['cornerRadius'] === undefined ? undefined : ShellTransitionSpec.number(raw, 'cornerRadius', 0, 0, 256),
      elevation: raw['elevation'] === undefined ? undefined : ShellTransitionSpec.number(raw, 'elevation', 0, 0, 64) };
  }
  effectiveStyle(): ShellTransitionStyle {
    if (this.style !== 'default') return this.style;
    if (this.presentation.routeType === 'wx://upwards' || this.presentation.mode === 'bottomSheet' || this.presentation.mode === 'cupertinoModal') return 'slideUp';
    if (this.presentation.routeType === 'wx://zoom' || this.presentation.mode === 'modal') return 'zoom';
    if (this.presentation.mode === 'heroSheet') return 'none';
    return 'slide';
  }
  static selector(value: string): string {
    value = value.trim();
    const id = value.startsWith('#') ? value.substring(1) : value;
    if (id.length === 0 || id.length > 128 || /[\s,>+~\[\]]/.test(id)) throw new Error('仅支持非空ID selector');
    return id;
  }
  private static object(value: Object): Record<string, Object> {
    if (value === null || Array.isArray(value) || typeof value !== 'object') throw new Error('transition 参数必须为对象');
    return value as Record<string, Object>;
  }
  private static required(raw: Record<string, Object>, key: string): string {
    const value = ShellTransitionSpec.text(raw, key, '');
    if (value.trim().length === 0) throw new Error(`${key} 不能为空`);
    return value;
  }
  private static text(raw: Record<string, Object>, key: string, fallback: string): string {
    if (raw[key] === undefined) return fallback;
    if (typeof raw[key] !== 'string') throw new Error(`${key} 必须是字符串`);
    return raw[key] as string;
  }
  private static boolean(raw: Record<string, Object>, key: string, fallback: boolean): boolean {
    if (raw[key] === undefined) return fallback;
    if (typeof raw[key] !== 'boolean') throw new Error(`${key} 必须为布尔值`);
    return raw[key] as boolean;
  }
  private static number(raw: Record<string, Object>, key: string, fallback: number, minimum: number, maximum: number): number {
    if (raw[key] === undefined) return fallback;
    const value = raw[key];
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) throw new Error(`${key} 超出合法范围`);
    return value as number;
  }
  private static color(raw: Record<string, Object>, key: string, fallback: string): string {
    const value = ShellTransitionSpec.text(raw, key, fallback);
    ShellTransitionColor.parse(value);
    return value;
  }
}
