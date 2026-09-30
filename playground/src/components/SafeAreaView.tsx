// Copyright (c) 2025 TikTok Pte. Ltd.
// Licensed under the Apache License Version 2.0 that can be found in the
// LICENSE file in the root directory of this source tree.

import type { ReactNode } from 'react'

import {
  getSafeAreaInsetsFromGlobalProps,
  type SafeAreaInsets,
} from '../utils/safeAreaInsets.js'

export type SafeAreaEdge = 'top' | 'bottom' | 'left' | 'right'

export interface SafeAreaViewProps {
  children?: ReactNode
  /** 只为当前内容负责的边设置 padding，避免父子重复消费同一边距。 */
  edges?: SafeAreaEdge[]
  /** 显式传入时覆盖宿主快照。 */
  globalProps?: Record<string, unknown> | null
  className?: string
  style?: Record<string, string | number | undefined>
}

function snapshotGlobalProps(): Record<string, unknown> | undefined {
  if (typeof lynx === 'undefined') {
    return undefined
  }
  return lynx.__globalProps as unknown as Record<string, unknown> | undefined
}

function paddingFromInsets(
  insets: SafeAreaInsets,
  edges: SafeAreaEdge[],
): Record<string, string> {
  const pad: Record<string, string> = {}
  if (edges.includes('top')) {
    pad.paddingTop = `${insets.top}px`
  }
  if (edges.includes('bottom')) {
    pad.paddingBottom = `${insets.bottom}px`
  }
  if (edges.includes('left')) {
    pad.paddingLeft = `${insets.left}px`
  }
  if (edges.includes('right')) {
    pad.paddingRight = `${insets.right}px`
  }
  return pad
}

/** 当前 reactive GlobalProps 模式会触发重新渲染，无需再维护一份订阅状态。 */
export function SafeAreaView(props: SafeAreaViewProps) {
  const {
    children,
    edges = ['top', 'bottom', 'left', 'right'],
    globalProps: globalPropsProp,
    className,
    style,
  } = props

  const raw = globalPropsProp ?? snapshotGlobalProps()
  const insets = getSafeAreaInsetsFromGlobalProps(raw)
  const padding = paddingFromInsets(insets, edges)

  const mergedStyle: Record<string, string | number | undefined> = {
    boxSizing: 'border-box',
    width: '100%',
    ...padding,
    ...style,
  }

  return (
    <view className={className} style={mergedStyle}>
      {children}
    </view>
  )
}
