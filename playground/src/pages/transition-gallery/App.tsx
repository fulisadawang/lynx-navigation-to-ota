import { useState } from '@lynx-js/react'

import { DemoPage } from '../../components/DemoPage/index.js'
import { ShareElement } from '../../components/ShareElement/index.js'
import {
  cancelPreparedRoute,
  getTransitionState,
  navigateOpenContainer,
  navigateSharedElements,
  navigateWithPreset,
  open,
  prepareRoute,
  type TransitionPreset,
} from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'

import './App.css'

const TARGET_BUNDLE = 'transition-detail.lynx.bundle'

function TransitionGalleryContent() {
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'
  const [status, setStatus] = useState('等待选择转场')
  const [preparedToken, setPreparedToken] = useState('')
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  const commonParams = (title: string) => ({
    title,
    transition_kind: title,
    force_theme_style: resolved,
    container_bg_color: isDark ? '#09090b' : '#f4f4f5',
    nav_bar_color: isDark ? '#09090b' : '#ffffff',
    title_color: isDark ? '#ffffff' : '#111111',
  })

  const showResult = (name: string, response: { code: number; msg?: string; data?: unknown }) => {
    'background only'
    const transaction = (response.data as { transactionID?: string } | undefined)?.transactionID
    setStatus(
      response.code === 1
        ? `${name} 已接受${transaction ? ` · ${transaction}` : ''}`
        : `${name} 失败 · ${response.msg || 'unknown'}`,
    )
  }

  const runBasicPreset = (
    preset: Exclude<TransitionPreset, 'shared' | 'container'>,
    routeOptions?: { round?: boolean; height?: number; detents?: number[]; initialDetent?: number },
  ) => {
    'background only'
    setStatus(`正在提交 ${preset} 预设…`)
    navigateWithPreset(
      {
        bundle: TARGET_BUNDLE,
        preset,
        routeKey: `transition-${preset}`,
        params: commonParams(preset),
        routeOptions,
      },
      (result) => showResult(preset, result),
    )
  }

  const runShared = () => {
    'background only'
    setStatus('正在提交多元素 shared 预设…')
    navigateSharedElements(
      {
        bundle: TARGET_BUNDLE,
        elements: [
          {
            key: 'product-cover-10001',
            rectTweenType: 'materialRectArc',
            shuttleOnPush: 'from',
            shuttleOnPop: 'from',
            sourceStyle: {
              backgroundColor: '#17162D',
              cornerRadius: 22,
              elevation: 10,
            },
            targetStyle: {
              backgroundColor: '#17162D',
              cornerRadius: 30,
              elevation: 0,
            },
          },
          {
            key: 'product-title-10001',
            rectTweenType: 'linear',
            shuttleOnPush: 'from',
            shuttleOnPop: 'from',
          },
          {
            key: 'product-price-10001',
            rectTweenType: 'materialRectCenterArc',
            shuttleOnPush: 'from',
            shuttleOnPop: 'from',
            sourceStyle: {
              backgroundColor: '#F97360',
              cornerRadius: 14,
              elevation: 2,
            },
            targetStyle: {
              backgroundColor: '#F97360',
              cornerRadius: 18,
              elevation: 4,
            },
          },
        ],
        routeKey: 'transition-shared',
        params: commonParams('shared'),
      },
      (result) => showResult('shared', result),
    )
  }

  const runContainer = () => {
    'background only'
    setStatus('正在提交 container 预设…')
    navigateOpenContainer(
      {
        bundle: TARGET_BUNDLE,
        source: 'transition-card-source',
        // 演示页显式覆盖九项外观参数，便于真机同时验收颜色、圆角、影深和
        // fadeThrough；普通业务仍可只传 bundle + source 使用官方默认值。
        container: {
          closedColor: isDark ? '#18181B' : '#FFFFFF',
          middleColor: isDark ? '#312E81' : '#E0E7FF',
          openColor: isDark ? '#09090B' : '#F4F4F5',
          closedCornerRadius: 20,
          openCornerRadius: 0,
          closedElevation: 8,
          openElevation: 0,
          transitionType: 'fadeThrough',
          transitionDuration: 360,
        },
        routeKey: 'transition-container',
        params: commonParams('container'),
      },
      (result) => showResult('container', result),
    )
  }

  const prepareDetail = () => {
    'background only'
    const route = `hybrid://lynxview_page?bundle=${encodeURIComponent(TARGET_BUNDLE)}&title=${encodeURIComponent('预加载目标页')}&transition_kind=prepared`
    setStatus('正在预取 Bundle 字节…')
    prepareRoute(
      {
        scheme: route,
        options: {
          transition: { style: 'fade', readyTimeoutMs: 500 },
        },
      },
      (result) => {
        const token = result.data?.token || ''
        setPreparedToken(token)
        setStatus(
          result.code === 1 && token
            ? `预取完成 · ${token}`
            : `预取失败 · ${result.msg || 'unknown'}`,
        )
      },
    )
  }

  const openPrepared = () => {
    'background only'
    if (!preparedToken) {
      setStatus('请先点击“预取目标 Bundle”')
      return
    }
    const route = `hybrid://lynxview_page?bundle=${encodeURIComponent(TARGET_BUNDLE)}&title=${encodeURIComponent('预加载目标页')}&transition_kind=prepared`
    open(
      {
        scheme: route,
        options: {
          preparedRouteToken: preparedToken,
          transition: { style: 'fade', readyTimeoutMs: 500 },
        },
      },
      (result) => {
        setPreparedToken('')
        showResult('preparedRoute', result)
      },
    )
  }

  const cancelPrepared = () => {
    'background only'
    if (!preparedToken) {
      setStatus('当前没有待取消的 token')
      return
    }
    cancelPreparedRoute(preparedToken, (result) => {
      setStatus(result.code === 1 ? '预取 token 已取消' : `取消失败 · ${result.msg || 'unknown'}`)
      if (result.code === 1) setPreparedToken('')
    })
  }

  const readState = () => {
    'background only'
    getTransitionState((result) => {
      if (result.code !== 1 || !result.data) {
        setStatus(`状态读取失败 · ${result.msg || 'unknown'}`)
        return
      }
      setStatus(
        `${result.data.status} · ${result.data.requestedTransition}`
        + ` → ${result.data.effectiveTransition} · ${Math.round(result.data.progress * 100)}%`
        + `${result.data.reason ? ` · ${result.data.reason}` : ''}`,
      )
    })
  }

  return (
    <DemoPage title="原生容器转场">
      <view className={dk('transition-intro')}>
        <text className={dk('transition-title')}>Activity / UIViewController 原生转场</text>
        <text className={dk('transition-desc')}>
          Lynx 只声明 idSelector 和转场意图。首帧、快照、手势 progress、取消与栈提交全部由原生宿主管理。
        </text>
      </view>

      <view
        className="transition-share-lab"
        bindtap={runShared}
        accessibility-element
        accessibility-label="打开 Lynx Pulse One 商品详情并运行三个共享元素转场"
        accessibility-traits="button"
      >
        <view className="transition-share-lab-header">
          <view className="transition-share-lab-heading">
            <text className="transition-share-lab-eyebrow">SHARE-ELEMENT · LIVE DEMO</text>
            <text className="transition-share-lab-title">点击整张商品卡片</text>
          </view>
          <view className="transition-share-count">
            <text className="transition-share-count-value">3</text>
            <text className="transition-share-count-label">ELEMENTS</text>
          </view>
        </view>

        <view className="transition-product-card">
          <ShareElement
            shareKey="product-cover-10001"
            className="transition-product-cover-share"
          >
            {/* 内联资源避免 iOS Image Service 无法识别 asset:/// 自定义 scheme。 */}
            <image
              className="transition-product-cover"
              mode="aspectFill"
              src={require('../../assets/product-sneaker.jpg?inline')}
            />
            <view className="transition-product-cover-label">
              <text className="transition-product-cover-label-text">DROP 01</text>
            </view>
          </ShareElement>

          <view className="transition-product-copy">
            <text className="transition-product-kicker">MOTION LAB / RUNNING</text>
            <ShareElement
              shareKey="product-title-10001"
              className="transition-product-title-share"
            >
              <text className="transition-product-title">Lynx Pulse One</text>
            </ShareElement>
            <text className="transition-product-desc">
              封面扩展为大图，标题与价格分别飞向详情布局。
            </text>
            <view className="transition-product-footer">
              <ShareElement
                shareKey="product-price-10001"
                className="transition-product-price-share"
              >
                <view className="transition-product-price">
                  <text className="transition-product-price-symbol">¥</text>
                  <text className="transition-product-price-value">899</text>
                </view>
              </ShareElement>
              <view className="transition-product-open">
                <text className="transition-product-open-text">查看详情</text>
                <text className="transition-product-open-arrow">↗</text>
              </view>
            </view>
          </view>
        </view>

        <view className="transition-share-hint">
          <view className="transition-share-hint-line" />
          <text className="transition-share-hint-text">
            打开后点原生返回，三个元素会沿相同轨迹回到这里
          </text>
        </view>
      </view>

      <view
        id="transition-card-source"
        className={dk('transition-container-card')}
        bindtap={runContainer}
        accessibility-element
        accessibility-label="运行容器打开转场"
        accessibility-traits="button"
      >
        <view className="transition-container-icon">
          <text className="transition-container-icon-text">↗</text>
        </view>
        <view className="transition-container-copy">
          <text className={dk('transition-card-title')}>Open Container</text>
          <text className={dk('transition-card-desc')}>卡片矩形、圆角、颜色与内容淡入共用同一原生进度。</text>
        </view>
        <text className={dk('transition-chevron')}>›</text>
      </view>

      <view className={dk('transition-section')}>
        <text className={dk('transition-section-title')}>基础转场</text>
        <view className="transition-button-grid">
          {(['fade', 'slide', 'none'] as const).map((preset) => (
            <view
              key={preset}
              className={dk('transition-chip')}
              bindtap={() => runBasicPreset(preset)}
              accessibility-element
              accessibility-label={`运行 ${preset} 预设转场`}
              accessibility-traits="button"
            >
              <text className={dk('transition-chip-text')}>{preset}</text>
            </view>
          ))}
        </view>
      </view>

      <view className={dk('transition-section')}>
        <text className={dk('transition-section-title')}>Skyline routeType 映射</text>
        <text className={dk('transition-section-desc')}>
          七种 routeType 分别由原生 renderer 实现；显式预设不会叠加 Activity / UIKit 系统动画。
        </text>
        <view className="transition-preset-list">
          {([
            { label: 'wx://upwards', preset: 'upwards' },
            { label: 'wx://zoom', preset: 'zoom' },
            { label: 'wx://bottom-sheet', preset: 'bottomSheet' },
            {
              label: 'wx://hero-sheet · 28/56/100vh',
              preset: 'heroSheet',
              routeOptions: { detents: [28, 56, 100], initialDetent: 56 },
            },
            { label: 'wx://cupertino-modal', preset: 'cupertinoModal' },
            { label: 'wx://cupertino-modal-inside', preset: 'cupertinoModalInside' },
            { label: 'wx://modal-navigation', preset: 'modalNavigation' },
            { label: 'wx://modal', preset: 'modal' },
          ] as const).map((item) => (
            <view
              key={item.label}
              className={dk('transition-preset')}
              bindtap={() => runBasicPreset(
                item.preset,
                'routeOptions' in item
                  ? {
                      ...item.routeOptions,
                      detents: item.routeOptions.detents
                        ? Array.from(item.routeOptions.detents)
                        : undefined,
                    }
                  : undefined,
              )}
              accessibility-element
              accessibility-label={`运行 ${item.label} 预置转场`}
              accessibility-traits="button"
            >
              <text className={dk('transition-preset-text')}>{item.label}</text>
              <text className={dk('transition-chevron')}>›</text>
            </view>
          ))}
        </view>
      </view>

      <view className={dk('transition-section')}>
        <text className={dk('transition-section-title')}>Bundle 预取与状态</text>
        <text className={dk('transition-section-desc')}>
          prepareRoute 只缓存受限的 Bundle 字节，不提前持有 LynxView 或原生页面。
        </text>
        <view className="transition-action-row">
          <view
            className={dk('transition-small-button')}
            bindtap={prepareDetail}
            accessibility-element
            accessibility-label="预取目标 Bundle"
            accessibility-traits="button"
          >
            <text className={dk('transition-small-button-text')}>预取目标 Bundle</text>
          </view>
          <view
            className={dk('transition-small-button')}
            bindtap={openPrepared}
            accessibility-element
            accessibility-label="使用预取 token 打开"
            accessibility-traits="button"
          >
            <text className={dk('transition-small-button-text')}>使用 token 打开</text>
          </view>
        </view>
        <view className="transition-action-row">
          <view
            className={dk('transition-small-button')}
            bindtap={cancelPrepared}
            accessibility-element
            accessibility-label="取消 Bundle 预取"
            accessibility-traits="button"
          >
            <text className={dk('transition-small-button-text')}>取消预取</text>
          </view>
          <view
            className={dk('transition-small-button')}
            bindtap={readState}
            accessibility-element
            accessibility-label="读取原生转场状态"
            accessibility-traits="button"
          >
            <text className={dk('transition-small-button-text')}>读取原生状态</text>
          </view>
        </view>
        <text className={dk('transition-status')}>{status}</text>
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <TransitionGalleryContent />
    </ThemeProvider>
  )
}
