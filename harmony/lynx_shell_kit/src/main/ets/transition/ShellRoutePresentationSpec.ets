import ShellTransitionColor from './ShellTransitionColor';

/** 只归一化路由承载合同，动画与容器行为由宿主按字段实际实施。 */
export default class ShellRoutePresentationSpec {
  routeType?: string;
  mode: 'page' | 'bottomSheet' | 'heroSheet' | 'cupertinoModal' | 'cupertinoModalInside' | 'modalNavigation' | 'modal' = 'page';
  heightVh: number = 92;
  detentsVh: number[] = [92];
  initialDetentIndex: number = 0;
  round: boolean = true;
  opaque: boolean = true;
  maintainState: boolean = true;
  barrierColor: string = '#00000066';
  barrierDismissible: boolean = false;
  barrierLabel?: string;
  canTransitionTo: boolean = true;
  canTransitionFrom: boolean = true;
  allowEnterRouteSnapshotting: boolean = true;
  allowExitRouteSnapshotting: boolean = true;
  fullscreenDrag: boolean = false;
  popGestureDirection: 'horizontal' | 'vertical' | 'multi' = 'horizontal';
  transitionDuration?: number;
  reverseTransitionDuration?: number;

  static parse(routeType?: string, routeOptions?: Object, routeConfig?: Object, transparent?: boolean): ShellRoutePresentationSpec {
    const spec = new ShellRoutePresentationSpec();
    if (transparent !== undefined && typeof transparent !== 'boolean') throw new Error('transparent 必须为布尔值');
    if (routeType !== undefined) {
      if (typeof routeType !== 'string') throw new Error('routeType 必须是字符串');
      spec.routeType = routeType;
      switch (routeType) {
        case 'wx://upwards':
        case 'wx://zoom': break;
        case 'wx://bottom-sheet': spec.mode = 'bottomSheet'; break;
        case 'wx://hero-sheet': spec.mode = 'heroSheet'; break;
        case 'wx://cupertino-modal': spec.mode = 'cupertinoModal'; break;
        case 'wx://cupertino-modal-inside': spec.mode = 'cupertinoModalInside'; break;
        case 'wx://modal-navigation': spec.mode = 'modalNavigation'; break;
        case 'wx://modal': spec.mode = 'modal'; break;
        default: throw new Error('routeType 不受支持');
      }
    }
    const partial = spec.mode !== 'page';
    const sheet = spec.mode === 'bottomSheet' || spec.mode === 'heroSheet';
    spec.opaque = !partial && transparent !== true;
    spec.barrierDismissible = partial || transparent === true;
    spec.fullscreenDrag = sheet;
    spec.popGestureDirection = sheet ? 'vertical' : 'horizontal';
    if (spec.mode === 'heroSheet') {
      spec.heightVh = 56;
      spec.detentsVh = [28, 56, 100];
      spec.initialDetentIndex = 1;
    }

    const options = ShellRoutePresentationSpec.object(routeOptions, 'routeOptions');
    const explicitHeight = ShellRoutePresentationSpec.number(options, 'height', 'routeOptions', 1, 100);
    const explicitInitial = ShellRoutePresentationSpec.number(options, 'initialDetent', 'routeOptions', 1, 100);
    spec.round = ShellRoutePresentationSpec.boolean(options, 'round', 'routeOptions', true);
    const rawDetents = options['detents'];
    if (rawDetents !== undefined) {
      if (!Array.isArray(rawDetents)) throw new Error('routeOptions.detents 必须为数组');
      const values = rawDetents as Object[];
      if (values.length < 1 || values.length > 4) throw new Error('routeOptions.detents 数量必须在 1..4');
      spec.detentsVh = [];
      for (let i = 0; i < values.length; i += 1) {
        const value = values[i];
        if (typeof value !== 'number' || !Number.isFinite(value) || value < 1 || value > 100) throw new Error(`routeOptions.detents[${i}] 必须是 1..100 的有限数字`);
        const detent = value as number;
        if (i > 0 && detent <= spec.detentsVh[i - 1]) throw new Error('routeOptions.detents 必须严格递增');
        spec.detentsVh.push(detent);
      }
    } else if (explicitHeight !== undefined) {
      spec.detentsVh = [explicitHeight];
    }
    if (spec.mode === 'heroSheet' && (spec.detentsVh.length < 2 || Math.abs(spec.detentsVh[spec.detentsVh.length - 1] - 100) >= 0.0001)) {
      throw new Error('heroSheet 至少需要两个 detent，最后一个必须为 100vh');
    }
    const usesHeroDefaults = spec.mode === 'heroSheet' && rawDetents === undefined && explicitHeight === undefined;
    const initial = explicitInitial ?? explicitHeight ?? (usesHeroDefaults ? 56 : spec.detentsVh[spec.detentsVh.length - 1]);
    const initialIndex = spec.detentsVh.findIndex((detent: number) => Math.abs(detent - initial) < 0.0001);
    if (initialIndex < 0) throw new Error('routeOptions.initialDetent 必须是 detents 中的一个值');
    spec.heightVh = initial;
    spec.initialDetentIndex = initialIndex;

    const config = ShellRoutePresentationSpec.object(routeConfig, 'routeConfig');
    const requestedOpaque = ShellRoutePresentationSpec.boolean(config, 'opaque', 'routeConfig', spec.opaque);
    // transparent 与 hero 承载强制透明；显式 opaque 仍先校验，禁止掩盖错误类型。
    spec.opaque = transparent === true || spec.mode === 'heroSheet' ? false : requestedOpaque;
    spec.maintainState = ShellRoutePresentationSpec.boolean(config, 'maintainState', 'routeConfig', true);
    spec.barrierDismissible = ShellRoutePresentationSpec.boolean(config, 'barrierDismissible', 'routeConfig', spec.barrierDismissible);
    spec.canTransitionTo = ShellRoutePresentationSpec.boolean(config, 'canTransitionTo', 'routeConfig', true);
    spec.canTransitionFrom = ShellRoutePresentationSpec.boolean(config, 'canTransitionFrom', 'routeConfig', true);
    spec.allowEnterRouteSnapshotting = ShellRoutePresentationSpec.boolean(config, 'allowEnterRouteSnapshotting', 'routeConfig', true);
    spec.allowExitRouteSnapshotting = ShellRoutePresentationSpec.boolean(config, 'allowExitRouteSnapshotting', 'routeConfig', true);
    spec.fullscreenDrag = ShellRoutePresentationSpec.boolean(config, 'fullscreenDrag', 'routeConfig', spec.fullscreenDrag);
    const direction = ShellRoutePresentationSpec.text(config, 'popGestureDirection', 'routeConfig');
    if (direction !== undefined) {
      if (direction !== 'horizontal' && direction !== 'vertical' && direction !== 'multi') throw new Error('routeConfig.popGestureDirection 只支持 horizontal、vertical、multi');
      spec.popGestureDirection = direction;
    }
    const color = ShellRoutePresentationSpec.text(config, 'barrierColor', 'routeConfig');
    if (color !== undefined) {
      ShellTransitionColor.parse(color);
      spec.barrierColor = color;
    }
    const label = ShellRoutePresentationSpec.text(config, 'barrierLabel', 'routeConfig');
    if (label !== undefined && label.length > 128) throw new Error('routeConfig.barrierLabel 不能超过 128 个字符');
    spec.barrierLabel = label;
    spec.transitionDuration = ShellRoutePresentationSpec.number(config, 'transitionDuration', 'routeConfig', 0, 5000);
    spec.reverseTransitionDuration = ShellRoutePresentationSpec.number(config, 'reverseTransitionDuration', 'routeConfig', 0, 5000);
    if ((spec.transitionDuration !== undefined && !Number.isInteger(spec.transitionDuration)) ||
      (spec.reverseTransitionDuration !== undefined && !Number.isInteger(spec.reverseTransitionDuration))) throw new Error('routeConfig 转场时长必须为整数毫秒');
    return spec;
  }

  private static object(value: Object | undefined, field: string): Record<string, Object> {
    if (value === undefined) return {};
    if (value === null || Array.isArray(value) || typeof value !== 'object') throw new Error(`${field} 必须为对象`);
    return value as Record<string, Object>;
  }

  private static boolean(raw: Record<string, Object>, key: string, field: string, fallback: boolean): boolean {
    const value = raw[key];
    if (value === undefined) return fallback;
    if (typeof value !== 'boolean') throw new Error(`${field}.${key} 必须为布尔值`);
    return value as boolean;
  }

  private static number(raw: Record<string, Object>, key: string, field: string, minimum: number, maximum: number): number | undefined {
    const value = raw[key];
    if (value === undefined) return undefined;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) throw new Error(`${field}.${key} 必须是 ${minimum}..${maximum} 的有限数字`);
    return value as number;
  }

  private static text(raw: Record<string, Object>, key: string, field: string): string | undefined {
    const value = raw[key];
    if (value === undefined) return undefined;
    if (typeof value !== 'string') throw new Error(`${field}.${key} 必须为字符串`);
    return value as string;
  }
}
