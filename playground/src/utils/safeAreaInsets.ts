// Copyright (c) 2025 TikTok Pte. Ltd.
// Licensed under the Apache License Version 2.0 that can be found in the
// LICENSE file in the root directory of this source tree.

/** 相对当前 Lynx 容器的四边安全距离，数值可直接用于 Lynx 的 px 样式。 */
export interface SafeAreaInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

function toNumber(value: unknown): number {
  if (typeof value === 'number' && !Number.isNaN(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const n = parseFloat(value);
    return Number.isNaN(n) ? 0 : n;
  }
  return 0;
}

/** 优先使用完整布局快照；旧宿主仅提供兼容字段时再读取别名。 */
export function getSafeAreaInsetsFromGlobalProps(
  globalProps?: Record<string, unknown> | null,
): SafeAreaInsets {
  if (!globalProps) {
    return { top: 0, right: 0, bottom: 0, left: 0 };
  }

  const layout = globalProps.__lynxShellLayout as
    | { safeAreaInsets: SafeAreaInsets }
    | undefined;
  const insets = layout?.safeAreaInsets ?? (globalProps.safeAreaInsets as SafeAreaInsets | undefined);
  if (insets) {
    return {
      top: toNumber(insets.top),
      right: toNumber(insets.right),
      bottom: toNumber(insets.bottom),
      left: toNumber(insets.left),
    };
  }

  const android = String(globalProps.os ?? '').toLowerCase() === 'android';
  return {
    top: toNumber(globalProps.safeAreaTop ?? (android
      ? globalProps.statusBarHeight ?? globalProps.topHeight
      : globalProps.topHeight ?? globalProps.statusBarHeight)),
    right: toNumber(globalProps.safeAreaRight),
    bottom: toNumber(globalProps.safeAreaBottom ?? (android
      ? globalProps.navigationBarHeight ?? globalProps.bottomHeight
      : globalProps.bottomHeight ?? globalProps.navigationBarHeight)),
    left: toNumber(globalProps.safeAreaLeft),
  };
}
