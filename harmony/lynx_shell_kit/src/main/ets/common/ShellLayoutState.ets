import display from '@ohos.display';
import window from '@ohos.window';

export type ShellCapabilityStatus = 'supported' | 'unsupported' | 'unavailable' | 'unknown';
export type ShellLayoutOrientation = 'portrait' | 'landscape' | 'unknown';
export type ShellWindowMode = 'fullscreen' | 'split' | 'floating' | 'unknown';
export type ShellFoldStatus = 'unknown' | 'expanded' | 'half_folded' | 'folded' | 'compound';
export type ShellFoldDisplayMode = 'unknown' | 'full' | 'main' | 'sub' | 'coordination';

export interface ShellLogicalRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface ShellInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

export interface ShellLayoutCapabilities {
  windowMetrics: ShellCapabilityStatus;
  viewportMetrics: ShellCapabilityStatus;
  safeArea: ShellCapabilityStatus;
  windowMode: ShellCapabilityStatus;
  foldStatus: ShellCapabilityStatus;
  foldDisplayMode: ShellCapabilityStatus;
  foldAngles: ShellCapabilityStatus;
  creaseGeometry: ShellCapabilityStatus;
  hingeGeometry: ShellCapabilityStatus;
  partitionGeometry: ShellCapabilityStatus;
}

export interface ShellLayoutFold {
  isFoldable: boolean;
  status: ShellFoldStatus;
  rawStatus?: number;
  displayMode: ShellFoldDisplayMode;
  rawDisplayMode?: number;
  foldAnglesDeg?: number[];
  creaseRects?: ShellLogicalRect[];
  creaseDisplayId?: number;
  creaseCoordinateSpace?: string;
}

/**
 * 页面可见的窗口环境快照。canonical 宽高统一使用 Lynx CSS logical px；
 * Harmony Window/Display 的 raw px 只在 ShellLayoutState 内部用于调用 Lynx API。
 */
export interface ShellLayoutSnapshot {
  schemaVersion: number;
  revision: number;
  timestampMillis: number;
  screenWidth: number;
  screenHeight: number;
  viewportWidth: number;
  viewportHeight: number;
  density: number;
  orientation: ShellLayoutOrientation;
  windowMode: ShellWindowMode;
  safeAreaInsets: ShellInsets;
  fold: ShellLayoutFold;
  capabilities: ShellLayoutCapabilities;
}

export interface ShellRawScreenSize {
  width: number;
  height: number;
}

/**
 * HarmonyOS Window/ArkUI 环境状态。
 *
 * Window 回调只更新轻量字段并合帧通知宿主；它们不读取 OTA、不写磁盘，
 * 也不负责重新创建 LynxContext。每个 LynxView 的 viewport 由外层组件 area 回调提供。
 */
export default class ShellLayoutState {
  private static initialized: boolean = false;
  private static density: number = 1;
  private static screenWidthPx: number = 1;
  private static screenHeightPx: number = 1;
  private static windowLeftPx: number = 0;
  private static windowTopPx: number = 0;
  private static currentWindow: window.Window | null = null;
  private static readonly pageViewports: Map<string, ShellRawScreenSize> = new Map();
  private static readonly avoidAreas: Map<number, window.AvoidArea> = new Map();
  private static safeAreaInsets: ShellInsets = {
    top: 0,
    right: 0,
    bottom: 0,
    left: 0
  };
  private static revision: number = 0;
  private static safeAreaCapability: ShellCapabilityStatus = 'unknown';
  private static windowModeCapability: ShellCapabilityStatus = 'unsupported';
  private static foldable: boolean = false;
  private static foldStatus: ShellFoldStatus = 'unknown';
  private static foldStatusRaw: number | undefined = undefined;
  private static foldStatusCapability: ShellCapabilityStatus = 'unknown';
  private static foldDisplayMode: ShellFoldDisplayMode = 'unknown';
  private static foldDisplayModeRaw: number | undefined = undefined;
  private static foldDisplayModeCapability: ShellCapabilityStatus = 'unknown';
  private static foldAnglesDeg: number[] | undefined = undefined;
  private static foldAnglesCapability: ShellCapabilityStatus = 'unknown';
  private static creaseRects: ShellLogicalRect[] | undefined = undefined;
  private static creaseDisplayId: number | undefined = undefined;
  private static creaseCapability: ShellCapabilityStatus = 'unknown';
  private static foldListenersRegistered: boolean = false;
  private static changeListener: ((reason: string) => void) | null = null;
  private static publishScheduled: boolean = false;
  private static pendingReason: string = '';

  static initialize(): void {
    if (ShellLayoutState.initialized) {
      return;
    }
    ShellLayoutState.initialized = true;
    try {
      const currentDisplay = display.getDefaultDisplaySync();
      ShellLayoutState.density = currentDisplay.densityPixels > 0 ? currentDisplay.densityPixels : 1;
      ShellLayoutState.screenWidthPx = currentDisplay.width > 0 ? currentDisplay.width : 1;
      ShellLayoutState.screenHeightPx = currentDisplay.height > 0 ? currentDisplay.height : 1;
    } catch (error) {
      // LynxContext 自身也有默认 DisplayInfo；这里保留正数占位并报告 unknown 能力。
      ShellLayoutState.density = 1;
      ShellLayoutState.screenWidthPx = 1;
      ShellLayoutState.screenHeightPx = 1;
      console.warn(`LynxHarmonyShell: default display unavailable: ${error}`);
    }
    ShellLayoutState.refreshFoldState();
  }

  static setChangeListener(listener: ((reason: string) => void) | null): void {
    ShellLayoutState.changeListener = listener;
  }

  static attachWindow(target: window.Window): void {
    ShellLayoutState.initialize();
    if (ShellLayoutState.currentWindow === target) {
      return;
    }
    ShellLayoutState.detachWindow();
    ShellLayoutState.currentWindow = target;
    ShellLayoutState.avoidAreas.clear();
    ShellLayoutState.safeAreaInsets = { top: 0, right: 0, bottom: 0, left: 0 };
    ShellLayoutState.safeAreaCapability = 'unknown';

    try {
      const properties = target.getWindowProperties();
      ShellLayoutState.updateWindowRect(properties.windowRect, 'window_attached');
    } catch (error) {
      ShellLayoutState.safeAreaCapability = 'unknown';
      console.warn(`LynxHarmonyShell: initial window metrics unavailable: ${error}`);
    }

    try {
      target.on('windowSizeChange', ShellLayoutState.windowSizeListener);
    } catch (error) {
      console.warn(`LynxHarmonyShell: windowSizeChange listener unavailable: ${error}`);
    }
    try {
      target.on('windowRectChange', ShellLayoutState.windowRectListener);
    } catch (error) {
      console.warn(`LynxHarmonyShell: windowRectChange listener unavailable: ${error}`);
    }
    try {
      target.on('avoidAreaChange', ShellLayoutState.avoidAreaListener);
    } catch (error) {
      ShellLayoutState.safeAreaCapability = 'unknown';
      console.warn(`LynxHarmonyShell: avoidAreaChange listener unavailable: ${error}`);
    }
    ShellLayoutState.registerFoldListeners();
    ShellLayoutState.bumpRevision('window_attached');
  }

  static detachWindow(): void {
    const target = ShellLayoutState.currentWindow;
    if (target !== null) {
      try { target.off('windowSizeChange', ShellLayoutState.windowSizeListener); } catch (error) {
        console.warn(`LynxHarmonyShell: windowSizeChange listener cleanup failed: ${error}`);
      }
      try { target.off('windowRectChange', ShellLayoutState.windowRectListener); } catch (error) {
        console.warn(`LynxHarmonyShell: windowRectChange listener cleanup failed: ${error}`);
      }
      try { target.off('avoidAreaChange', ShellLayoutState.avoidAreaListener); } catch (error) {
        console.warn(`LynxHarmonyShell: avoidAreaChange listener cleanup failed: ${error}`);
      }
    }
    ShellLayoutState.currentWindow = null;
    ShellLayoutState.unregisterFoldListeners();
    ShellLayoutState.pageViewports.clear();
  }

  static updateViewport(pageId: string, width: number, height: number): void {
    ShellLayoutState.initialize();
    const normalizedPageId = pageId.trim();
    if (normalizedPageId.length === 0 || width <= 0 || height <= 0 ||
      !Number.isFinite(width) || !Number.isFinite(height)) {
      return;
    }
    const current = ShellLayoutState.pageViewports.get(normalizedPageId);
    if (current !== undefined && current.width === width && current.height === height) {
      return;
    }
    ShellLayoutState.pageViewports.set(normalizedPageId, { width: width, height: height });
    ShellLayoutState.bumpRevision('viewport_changed');
  }

  static clearViewport(pageId: string): void {
    ShellLayoutState.pageViewports.delete(pageId);
  }

  static rawScreenSize(): ShellRawScreenSize {
    ShellLayoutState.initialize();
    return {
      width: ShellLayoutState.screenWidthPx,
      height: ShellLayoutState.screenHeightPx
    };
  }

  static snapshot(pageId: string = ''): ShellLayoutSnapshot {
    ShellLayoutState.initialize();
    const width = ShellLayoutState.logicalPx(ShellLayoutState.screenWidthPx);
    const height = ShellLayoutState.logicalPx(ShellLayoutState.screenHeightPx);
    const viewport = ShellLayoutState.pageViewports.get(pageId);
    const viewportWidth = viewport === undefined ? width : viewport.width;
    const viewportHeight = viewport === undefined ? height : viewport.height;
    const viewportCapability: ShellCapabilityStatus = viewport === undefined ? 'unknown' : 'supported';
    const orientation: ShellLayoutOrientation = width === height ? 'unknown' :
      width > height ? 'landscape' : 'portrait';

    const fold: ShellLayoutFold = {
      isFoldable: ShellLayoutState.foldable,
      status: ShellLayoutState.foldStatus,
      displayMode: ShellLayoutState.foldDisplayMode
    };
    if (ShellLayoutState.foldStatusRaw !== undefined) fold.rawStatus = ShellLayoutState.foldStatusRaw;
    if (ShellLayoutState.foldDisplayModeRaw !== undefined) fold.rawDisplayMode = ShellLayoutState.foldDisplayModeRaw;
    if (ShellLayoutState.foldAnglesDeg !== undefined) fold.foldAnglesDeg = ShellLayoutState.foldAnglesDeg.slice();
    if (ShellLayoutState.creaseRects !== undefined) fold.creaseRects = ShellLayoutState.creaseRects.slice();
    if (ShellLayoutState.creaseDisplayId !== undefined) fold.creaseDisplayId = ShellLayoutState.creaseDisplayId;
    if (ShellLayoutState.creaseRects !== undefined) fold.creaseCoordinateSpace = 'display';

    return {
      schemaVersion: 1,
      revision: ShellLayoutState.revision,
      timestampMillis: new Date().getTime(),
      screenWidth: width,
      screenHeight: height,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      density: ShellLayoutState.density,
      orientation: orientation,
      windowMode: 'unknown',
      safeAreaInsets: {
        top: ShellLayoutState.safeAreaInsets.top,
        right: ShellLayoutState.safeAreaInsets.right,
        bottom: ShellLayoutState.safeAreaInsets.bottom,
        left: ShellLayoutState.safeAreaInsets.left
      },
      fold: fold,
      capabilities: {
        windowMetrics: 'supported',
        viewportMetrics: viewportCapability,
        safeArea: ShellLayoutState.safeAreaCapability,
        windowMode: ShellLayoutState.windowModeCapability,
        foldStatus: ShellLayoutState.foldStatusCapability,
        foldDisplayMode: ShellLayoutState.foldDisplayModeCapability,
        foldAngles: ShellLayoutState.foldAnglesCapability,
        creaseGeometry: ShellLayoutState.creaseCapability,
        hingeGeometry: 'unsupported',
        partitionGeometry: 'unsupported'
      }
    };
  }

  private static readonly windowSizeListener = (size: window.Size): void => {
    if (size.width <= 0 || size.height <= 0) return;
    if (ShellLayoutState.screenWidthPx === size.width && ShellLayoutState.screenHeightPx === size.height) return;
    ShellLayoutState.screenWidthPx = size.width;
    ShellLayoutState.screenHeightPx = size.height;
    // 折叠/展开通常先触发窗口尺寸变化；此处刷新可选折痕快照，不推导业务分区。
    ShellLayoutState.refreshCreaseRegion();
    ShellLayoutState.bumpRevision('window_size_changed');
  };

  private static readonly windowRectListener = (options: window.RectChangeOptions): void => {
    ShellLayoutState.updateWindowRect(options.rect, 'window_rect_changed');
  };

  private static readonly avoidAreaListener = (options: window.AvoidAreaOptions): void => {
    ShellLayoutState.avoidAreas.set(Number(options.type), options.area);
    ShellLayoutState.recalculateSafeArea();
    ShellLayoutState.safeAreaCapability = 'supported';
    ShellLayoutState.bumpRevision('safe_area_changed');
  };

  private static readonly foldStatusListener = (status: display.FoldStatus): void => {
    const rawStatus = Number(status);
    const nextStatus = ShellLayoutState.normalizeFoldStatus(rawStatus);
    if (ShellLayoutState.foldStatusRaw === rawStatus && ShellLayoutState.foldStatus === nextStatus) return;
    ShellLayoutState.foldStatusRaw = rawStatus;
    ShellLayoutState.foldStatus = nextStatus;
    ShellLayoutState.bumpRevision('fold_status_changed');
  };

  private static readonly foldDisplayModeListener = (mode: display.FoldDisplayMode): void => {
    const rawMode = Number(mode);
    const nextMode = ShellLayoutState.normalizeFoldDisplayMode(rawMode);
    if (ShellLayoutState.foldDisplayModeRaw === rawMode && ShellLayoutState.foldDisplayMode === nextMode) return;
    ShellLayoutState.foldDisplayModeRaw = rawMode;
    ShellLayoutState.foldDisplayMode = nextMode;
    ShellLayoutState.bumpRevision('fold_display_mode_changed');
  };

  private static readonly foldAngleListener = (angles: Array<number>): void => {
    const nextAngles = angles.slice();
    if (ShellLayoutState.sameNumbers(ShellLayoutState.foldAnglesDeg, nextAngles)) return;
    ShellLayoutState.foldAnglesDeg = nextAngles;
    ShellLayoutState.foldAnglesCapability = 'supported';
    ShellLayoutState.bumpRevision('fold_angles_changed');
  };

  private static updateWindowRect(rect: window.Rect, reason: string): void {
    if (rect.width <= 0 || rect.height <= 0) return;
    const changed = ShellLayoutState.screenWidthPx !== rect.width ||
      ShellLayoutState.screenHeightPx !== rect.height ||
      ShellLayoutState.windowLeftPx !== rect.left ||
      ShellLayoutState.windowTopPx !== rect.top;
    if (!changed) return;
    ShellLayoutState.screenWidthPx = rect.width;
    ShellLayoutState.screenHeightPx = rect.height;
    ShellLayoutState.windowLeftPx = rect.left;
    ShellLayoutState.windowTopPx = rect.top;
    ShellLayoutState.bumpRevision(reason);
  }

  private static recalculateSafeArea(): void {
    let top = 0;
    let right = 0;
    let bottom = 0;
    let left = 0;
    ShellLayoutState.avoidAreas.forEach((area: window.AvoidArea) => {
      if (!area.visible) return;
      top = Math.max(top, area.topRect.height);
      right = Math.max(right, area.rightRect.width);
      bottom = Math.max(bottom, area.bottomRect.height);
      left = Math.max(left, area.leftRect.width);
    });
    ShellLayoutState.safeAreaInsets = {
      top: ShellLayoutState.logicalPx(top),
      right: ShellLayoutState.logicalPx(right),
      bottom: ShellLayoutState.logicalPx(bottom),
      left: ShellLayoutState.logicalPx(left)
    };
  }

  private static refreshFoldState(): void {
    try {
      ShellLayoutState.foldable = display.isFoldable();
    } catch (error) {
      ShellLayoutState.foldable = false;
      ShellLayoutState.foldStatusCapability = 'unknown';
      ShellLayoutState.foldDisplayModeCapability = 'unknown';
      ShellLayoutState.foldAnglesCapability = 'unknown';
      ShellLayoutState.creaseCapability = 'unknown';
      console.warn(`LynxHarmonyShell: fold capability unavailable: ${error}`);
      return;
    }
    if (!ShellLayoutState.foldable) {
      ShellLayoutState.foldStatus = 'unknown';
      ShellLayoutState.foldDisplayMode = 'unknown';
      ShellLayoutState.foldStatusRaw = undefined;
      ShellLayoutState.foldDisplayModeRaw = undefined;
      ShellLayoutState.foldAnglesDeg = undefined;
      ShellLayoutState.creaseRects = undefined;
      ShellLayoutState.creaseDisplayId = undefined;
      ShellLayoutState.foldStatusCapability = 'unavailable';
      ShellLayoutState.foldDisplayModeCapability = 'unavailable';
      ShellLayoutState.foldAnglesCapability = 'unavailable';
      ShellLayoutState.creaseCapability = 'unavailable';
      return;
    }

    try {
      const status = Number(display.getFoldStatus());
      ShellLayoutState.foldStatusRaw = status;
      ShellLayoutState.foldStatus = ShellLayoutState.normalizeFoldStatus(status);
      ShellLayoutState.foldStatusCapability = 'supported';
    } catch (error) {
      ShellLayoutState.foldStatusCapability = 'unknown';
    }
    try {
      const mode = Number(display.getFoldDisplayMode());
      ShellLayoutState.foldDisplayModeRaw = mode;
      ShellLayoutState.foldDisplayMode = ShellLayoutState.normalizeFoldDisplayMode(mode);
      ShellLayoutState.foldDisplayModeCapability = 'supported';
    } catch (error) {
      ShellLayoutState.foldDisplayModeCapability = 'unknown';
    }
    ShellLayoutState.refreshCreaseRegion();
  }

  private static refreshCreaseRegion(): void {
    if (!ShellLayoutState.foldable) return;
    try {
      const region = display.getCurrentFoldCreaseRegion();
      const rects: ShellLogicalRect[] = [];
      region.creaseRects.forEach((rect: display.Rect) => {
        rects.push({
          left: ShellLayoutState.logicalPx(rect.left),
          top: ShellLayoutState.logicalPx(rect.top),
          width: ShellLayoutState.logicalPx(rect.width),
          height: ShellLayoutState.logicalPx(rect.height)
        });
      });
      ShellLayoutState.creaseRects = rects.length > 0 ? rects : undefined;
      ShellLayoutState.creaseDisplayId = region.displayId;
      ShellLayoutState.creaseCapability = 'supported';
    } catch (error) {
      ShellLayoutState.creaseRects = undefined;
      ShellLayoutState.creaseDisplayId = undefined;
      ShellLayoutState.creaseCapability = 'unknown';
    }
  }

  private static registerFoldListeners(): void {
    if (!ShellLayoutState.foldable || ShellLayoutState.foldListenersRegistered) return;
    let registered = false;
    try { display.on('foldStatusChange', ShellLayoutState.foldStatusListener); registered = true; } catch (error) { ShellLayoutState.foldStatusCapability = 'unknown'; }
    try { display.on('foldDisplayModeChange', ShellLayoutState.foldDisplayModeListener); registered = true; } catch (error) { ShellLayoutState.foldDisplayModeCapability = 'unknown'; }
    try { display.on('foldAngleChange', ShellLayoutState.foldAngleListener); registered = true; } catch (error) { ShellLayoutState.foldAnglesCapability = 'unknown'; }
    ShellLayoutState.foldListenersRegistered = registered;
  }

  private static unregisterFoldListeners(): void {
    if (!ShellLayoutState.foldListenersRegistered) return;
    try { display.off('foldStatusChange', ShellLayoutState.foldStatusListener); } catch (error) {
      console.warn(`LynxHarmonyShell: foldStatusChange listener cleanup failed: ${error}`);
    }
    try { display.off('foldDisplayModeChange', ShellLayoutState.foldDisplayModeListener); } catch (error) {
      console.warn(`LynxHarmonyShell: foldDisplayModeChange listener cleanup failed: ${error}`);
    }
    try { display.off('foldAngleChange', ShellLayoutState.foldAngleListener); } catch (error) {
      console.warn(`LynxHarmonyShell: foldAngleChange listener cleanup failed: ${error}`);
    }
    ShellLayoutState.foldListenersRegistered = false;
  }

  private static normalizeFoldStatus(raw: number): ShellFoldStatus {
    if (raw === 1) return 'expanded';
    if (raw === 2) return 'folded';
    if (raw === 3) return 'half_folded';
    if (raw === 0) return 'unknown';
    return 'compound';
  }

  private static normalizeFoldDisplayMode(raw: number): ShellFoldDisplayMode {
    if (raw === 1) return 'full';
    if (raw === 2) return 'main';
    if (raw === 3) return 'sub';
    if (raw === 4) return 'coordination';
    return 'unknown';
  }

  private static sameNumbers(left: number[] | undefined, right: number[]): boolean {
    if (left === undefined || left.length !== right.length) return false;
    for (let index = 0; index < right.length; index += 1) {
      if (left[index] !== right[index]) return false;
    }
    return true;
  }

  private static logicalPx(value: number): number {
    return value / (ShellLayoutState.density > 0 ? ShellLayoutState.density : 1);
  }

  private static bumpRevision(reason: string): void {
    ShellLayoutState.revision += 1;
    ShellLayoutState.schedulePublish(reason);
  }

  private static schedulePublish(reason: string): void {
    if (ShellLayoutState.changeListener === null) return;
    ShellLayoutState.pendingReason = ShellLayoutState.pendingReason.length === 0 ?
      reason : `${ShellLayoutState.pendingReason},${reason}`;
    if (ShellLayoutState.publishScheduled) return;
    ShellLayoutState.publishScheduled = true;
    setTimeout(() => {
      ShellLayoutState.publishScheduled = false;
      const pendingReason = ShellLayoutState.pendingReason;
      ShellLayoutState.pendingReason = '';
      const listener = ShellLayoutState.changeListener;
      if (listener !== null) listener(pendingReason);
    }, 0);
  }

  private constructor() {
  }
}
