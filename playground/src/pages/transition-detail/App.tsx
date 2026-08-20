import { runOnBackground, useEffect, useMainThreadRef, useState } from '@lynx-js/react'
import type { MainThread } from '@lynx-js/types'
import type { TransitionEvent } from '@lynx-js/types/events'
import type { ScrollEvent } from '@lynx-js/types/element'

import { DemoPage } from '../../components/DemoPage/index.js'
import { ShareElement } from '../../components/ShareElement/index.js'
import {
  close,
  getTransitionState,
  markTransitionReady,
  onRouteDone,
  onTransitionSettled,
  type TransitionState,
} from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'

import './App.css'

const HERO_DISMISS_THRESHOLD_PX = 96
const HERO_EXIT_DURATION_MS = 180

function closeHeroImmediately() {
  'background only'
  // Lynx 已经把 surface 移出屏幕；原生只负责无动画地移除透明承载层。
  close()
}

function scheduleHeroCloseAfterGesture() {
  'background only'
  setTimeout(closeHeroImmediately, HERO_EXIT_DURATION_MS)
}

function nativeTransitionFromGlobalProps(): Record<string, unknown> {
  const globalProps = (lynx.__globalProps || {}) as unknown as Record<string, unknown>
  const raw = globalProps.nativeTransition
  if (typeof raw === 'string') {
    try {
      return JSON.parse(raw) as Record<string, unknown>
    } catch {
      return {}
    }
  }
  return raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
}

function HeroSheetPreview() {
  const [scrollTop, setScrollTop] = useState(0)
  const [entered, setEntered] = useState(false)
  const [closing, setClosing] = useState(false)
  const surfaceRef = useMainThreadRef<MainThread.Element>(null)
  const dragStartYRef = useMainThreadRef(0)
  const dragOffsetRef = useMainThreadRef(0)
  const dragArmedRef = useMainThreadRef(false)
  const draggingRef = useMainThreadRef(false)
  const navProgress = Math.min(1, Math.max(0, scrollTop / 180))

  useEffect(() => {
    // 透明宿主已经无动画进入；这一帧之后由 Lynx 自己把 hero surface 从底部带入。
    setEntered(true)
  }, [])

  const handleScroll = (event: ScrollEvent) => {
    const nextScrollTop = Math.max(0, event.detail.scrollTop)
    if (Math.abs(nextScrollTop - scrollTop) >= 1) {
      setScrollTop(nextScrollTop)
    }
  }

  function handleTouchStartMainThread(event: MainThread.TouchEvent) {
    'main thread'
    const touch = event.touches[0]
    if (!touch) return
    dragStartYRef.current = touch.pageY
    dragOffsetRef.current = 0
    draggingRef.current = false
    // scrollTop 已由 Lynx 的 scroll 事件同步到 React 状态；这里只在手势开始时
    // 读取边界，真正的拖拽位移仍留在 main thread。
    dragArmedRef.current = scrollTop <= 1
    surfaceRef.current?.setStyleProperty('transition', 'none')
  }

  function handleTouchMoveMainThread(event: MainThread.TouchEvent) {
    'main thread'
    if (!dragArmedRef.current) return
    const touch = event.touches[0]
    if (!touch) return
    const distance = touch.pageY - dragStartYRef.current
    if (!draggingRef.current && distance <= 8) return
    draggingRef.current = true
    const offset = Math.max(0, distance) * 0.86
    dragOffsetRef.current = offset
    // bounces=false 已关闭 scroll-view 的回弹；当前 Lynx TouchEvent 不提供稳定的
    // preventDefault，不能在 main-thread handler 里调用它。
    surfaceRef.current?.setStyleProperty('transform', `translateY(${offset}px)`)
  }

  function handleTouchEndMainThread() {
    'main thread'
    if (!draggingRef.current) {
      dragArmedRef.current = false
      return
    }
    const distance = dragOffsetRef.current
    dragArmedRef.current = false
    draggingRef.current = false
    surfaceRef.current?.setStyleProperty(
      'transition',
      'transform 180ms cubic-bezier(0.22, 0.61, 0.36, 1)',
    )
    if (distance >= HERO_DISMISS_THRESHOLD_PX) {
      surfaceRef.current?.setStyleProperty('transform', 'translateY(100vh)')
      // Bridge/路由只能在 background 执行；动画帧仍只由 main thread 改 transform。
      // 只捕获模块级 background 函数，避免 worklet 初始化时捕获组件局部 TDZ 变量。
      runOnBackground(scheduleHeroCloseAfterGesture)()
    } else {
      surfaceRef.current?.setStyleProperty('transform', 'translateY(0px)')
    }
  }

  function handleTouchCancelMainThread() {
    'main thread'
    dragArmedRef.current = false
    draggingRef.current = false
    dragOffsetRef.current = 0
    surfaceRef.current?.setStyleProperty(
      'transition',
      'transform 220ms cubic-bezier(0.22, 0.61, 0.36, 1)',
    )
    surfaceRef.current?.setStyleProperty('transform', 'translateY(0px)')
  }

  const handleSurfaceTransitionEnd = (event: TransitionEvent) => {
    'background only'
    if (!closing || event.params.animation_type !== 'transition-transform') return
    // hero 的退出位移已经由 Lynx 完成，原生只做无动画的栈移除。
    closeHeroImmediately()
  }

  const handleClose = () => {
    'background only'
    if (!closing) setClosing(true)
  }

  return (
    <view className="hero-sheet-page">
      <view
        className={`hero-sheet-surface${entered ? ' hero-sheet-surface--entered' : ''}${closing ? ' hero-sheet-surface--closing' : ''}`}
        main-thread:ref={surfaceRef}
        bindtransitionend={handleSurfaceTransitionEnd}
      >
        <scroll-view
          className="hero-sheet-scroll"
          scroll-orientation="vertical"
          scroll-event-throttle={16}
          bounces={false}
          bindscroll={handleScroll}
          main-thread:bindtouchstart={handleTouchStartMainThread}
          main-thread:bindtouchmove={handleTouchMoveMainThread}
          main-thread:bindtouchend={handleTouchEndMainThread}
          main-thread:bindtouchcancel={handleTouchCancelMainThread}
          accessibility-element
          accessibility-label="hero 商品详情，可上下滚动并下拉关闭"
        >
          <view className="hero-sheet-scroll-content">
            <view className="hero-sheet-peek-spacer" />
            <view className="hero-sheet-preview">
              <view className="hero-sheet-hero">
                <image
                  className="hero-sheet-hero-image"
                  mode="aspectFill"
                  src={require('../../assets/product-sneaker.jpg?inline')}
                />
                <view className="hero-sheet-hero-scrim" />
                <view className="hero-sheet-hero-copy">
                  <text className="hero-sheet-hero-kicker">MOTION LAB / HERO SHEET</text>
                  <text className="hero-sheet-hero-title">上滑查看完整商品详情</text>
                  <text className="hero-sheet-hero-hint">顶部 hero 与信息卡共用一个连续视口</text>
                </view>
              </view>

              <view className="hero-sheet-panel">
                <view className="hero-sheet-thumbnails">
                  {[0, 1, 2, 3, 4].map((item) => (
                    <image
                      key={item}
                      className={`hero-sheet-thumbnail ${item === 0 ? 'hero-sheet-thumbnail--active' : ''}`}
                      mode="aspectFill"
                      src={require('../../assets/product-sneaker.jpg?inline')}
                    />
                  ))}
                  <text className="hero-sheet-more">共 8 款 ›</text>
                </view>
                <view className="hero-sheet-price-row">
                  <text className="hero-sheet-price">¥899</text>
                  <text className="hero-sheet-sales">已售 50 万+　|　直播间同价</text>
                </view>
                <text className="hero-sheet-product-title">Lynx Pulse One 轻量运动鞋</text>
                <view className="hero-sheet-tags">
                  <text className="hero-sheet-tag hero-sheet-tag--blue">运费险</text>
                  <text className="hero-sheet-tag">轻量缓震</text>
                  <text className="hero-sheet-tag">近 1 万人购买</text>
                  <text className="hero-sheet-tag">达人推荐</text>
                </view>
                <view className="hero-sheet-info-card">
                  <text className="hero-sheet-info-title">隔日达 · 预计今晚发货，后天送达</text>
                  <text className="hero-sheet-info-subtitle">预计广东汕头发货　|　免运费</text>
                </view>
                <view className="hero-sheet-info-card hero-sheet-info-card--plain">
                  <text className="hero-sheet-info-title hero-sheet-info-title--dark">商品评价 (3.5 万+)</text>
                  <text className="hero-sheet-info-subtitle">刚刚有新增好评　›</text>
                </view>
                <view className="hero-sheet-buybar">
                  <text className="hero-sheet-buybar-note">专享价 ¥799</text>
                  <text className="hero-sheet-buybar-button">¥899　立即购买</text>
                </view>
              </view>
            </view>
          </view>
        </scroll-view>

        <view
          className="hero-sheet-nav-layer"
          style={{ opacity: navProgress }}
          event-through={navProgress < 0.01 || closing}
        >
          <view className="hero-sheet-nav-gradient" />
          <view className="hero-sheet-nav">
            <view
              className="hero-sheet-circle-button"
              bindtap={handleClose}
              accessibility-element
              accessibility-label="关闭商品详情"
              accessibility-traits="button"
            >
              <text className="hero-sheet-circle-button-text">×</text>
            </view>
            <view className="hero-sheet-hero-actions">
              <view className="hero-sheet-circle-button" accessibility-element>
                <text className="hero-sheet-circle-button-text">⌕</text>
              </view>
              <view className="hero-sheet-circle-button" accessibility-element>
                <text className="hero-sheet-circle-button-text">♡</text>
              </view>
              <view className="hero-sheet-circle-button" accessibility-element>
                <text className="hero-sheet-circle-button-text">⋯</text>
              </view>
            </view>
          </view>
        </view>
      </view>
    </view>
  )
}

function TransitionDetailContent() {
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'
  const [readyResult, setReadyResult] = useState('等待原生首帧门禁')
  const [state, setState] = useState<TransitionState | undefined>(undefined)
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`
  const globalProps = (lynx.__globalProps || {}) as Record<string, any>
  const queryItems = (globalProps.queryItems || {}) as Record<string, string>
  const nativeTransition = nativeTransitionFromGlobalProps()
  const transactionID = String(nativeTransition.transactionID || queryItems.transition_transaction_id || '')
  const transitionKind = String(
    queryItems.transition_kind
    || nativeTransition.requestedTransition
    || 'default',
  )

  useEffect(() => {
    if (!transactionID) {
      setReadyResult('未注入 transactionID；原生仍会以 onFirstScreen + timeout 决定转场')
      return
    }
    // 这里只发送一次业务 ready，不发送坐标，也不由 JS 驱动任何动画帧。
    markTransitionReady(transactionID, (result) => {
      setReadyResult(result.code === 1 ? '业务 ready 已送达原生' : `ready 失败 · ${result.msg || 'unknown'}`)
    })
  }, [transactionID])

  useEffect(() => {
    const removeRouteDone = onRouteDone((event) => {
      setReadyResult(
        `onRouteDone · ${event.direction || 'unknown'} · ${event.status}`,
      )
    })
    const removeSettled = onTransitionSettled((event) => {
      if (event.status === 'cancelled' || event.status === 'failed') {
        setReadyResult(
          `onTransitionSettled · ${event.direction || 'unknown'} · ${event.status}`,
        )
      }
    })
    return () => {
      removeRouteDone()
      removeSettled()
    }
  }, [])

  const refreshState = () => {
    'background only'
    getTransitionState((result) => {
      if (result.code === 1) {
        setState(result.data)
      } else {
        setReadyResult(`状态读取失败 · ${result.msg || 'unknown'}`)
      }
    })
  }

  // heroSheet 的页面背景必须透明，让原生快照/真实来源页留在下面；详情页的
  // 首屏偏移、滚动和顶部导航都由 HeroSheetPreview 自己承载。
  if (transitionKind === 'heroSheet') {
    return <HeroSheetPreview />
  }

  return (
    <DemoPage title="原生转场目标页">
      {transitionKind === 'shared' ? (
        <view className="transition-detail-product">
          <ShareElement
            shareKey="product-cover-10001"
            className="transition-detail-product-cover-share"
          >
            {/* 两页复用同一份内联资源，保证离线场景和原生快照一致。 */}
            <image
              className="transition-detail-product-cover"
              mode="aspectFill"
              src={require('../../assets/product-sneaker.jpg?inline')}
            />
            <view className="transition-detail-product-badge">
              <text className="transition-detail-product-badge-text">MOTION LAB · DROP 01</text>
            </view>
            <view className="transition-detail-product-index">
              <text className="transition-detail-product-index-value">01</text>
              <text className="transition-detail-product-index-label">PULSE SERIES</text>
            </view>
          </ShareElement>

          <view className="transition-detail-product-copy">
            <view className="transition-detail-product-heading">
              <view className="transition-detail-product-heading-copy">
                <text className="transition-detail-product-kicker">PERFORMANCE / EVERYDAY</text>
                <ShareElement
                  shareKey="product-title-10001"
                  className="transition-detail-product-title-share"
                >
                  <text className="transition-detail-product-title">Lynx Pulse One</text>
                </ShareElement>
              </view>
              <view className="transition-detail-product-rating">
                <text className="transition-detail-product-rating-star">★</text>
                <text className="transition-detail-product-rating-value">4.9</text>
              </view>
            </view>

            <text className="transition-detail-product-desc">
              一双为移动而生的轻量跑鞋。这个详情页刻意把封面、标题和价格放到与列表卡片完全不同的位置，用来清楚观察多元素矩形插值、裁剪和层级。
            </text>

            <view className="transition-detail-product-meta">
              <view className="transition-detail-product-meta-item">
                <text className="transition-detail-product-meta-value">248g</text>
                <text className="transition-detail-product-meta-label">单只重量</text>
              </view>
              <view className="transition-detail-product-meta-divider" />
              <view className="transition-detail-product-meta-item">
                <text className="transition-detail-product-meta-value">8mm</text>
                <text className="transition-detail-product-meta-label">前后落差</text>
              </view>
              <view className="transition-detail-product-meta-divider" />
              <view className="transition-detail-product-meta-item">
                <text className="transition-detail-product-meta-value">24/7</text>
                <text className="transition-detail-product-meta-label">日常训练</text>
              </view>
            </view>

            <view className="transition-detail-product-colors">
              <view className="transition-detail-product-color transition-detail-product-color--coral" />
              <view className="transition-detail-product-color transition-detail-product-color--violet" />
              <view className="transition-detail-product-color transition-detail-product-color--ivory" />
              <text className="transition-detail-product-color-label">Coral Pulse</text>
            </view>

            <view className="transition-detail-product-purchase">
              <ShareElement
                shareKey="product-price-10001"
                className="transition-detail-product-price-share"
              >
                <view className="transition-detail-product-price">
                  <text className="transition-detail-product-price-symbol">¥</text>
                  <text className="transition-detail-product-price-value">899</text>
                </view>
              </ShareElement>
              <view
                className="transition-detail-product-back"
                bindtap={() => { 'background only'; close() }}
                accessibility-element
                accessibility-label="沿共享元素轨迹返回商品卡片"
                accessibility-traits="button"
              >
                <text className="transition-detail-product-back-text">沿原轨迹返回</text>
                <text className="transition-detail-product-back-arrow">↙</text>
              </view>
            </view>

            <text className="transition-detail-product-gesture">
              也可以从屏幕左边缘向右滑动；取消时页面与三个共享元素会一起回到当前状态。
            </text>
          </view>
        </view>
      ) : (
        <view className="transition-detail-hero">
          <ShareElement shareKey="product-cover-10001" className="transition-detail-image-share">
            <image className="transition-detail-image" src={require('../../assets/lynx-logo.png')} />
          </ShareElement>
          <text className="transition-detail-kicker">TARGET LYNX VIEW</text>
          <ShareElement shareKey="product-title-10001">
            <text className="transition-detail-title">真实 Activity / VC 已承载目标页</text>
          </ShareElement>
          <text className="transition-detail-desc">
            页面层和返回手势共享同一个原生进度源。向右边缘滑动可验证取消与完成。
          </text>
        </view>
      )}

      <view className={dk('transition-detail-card')}>
        <text className={dk('transition-detail-card-title')}>当前请求</text>
        <view className={dk('transition-detail-row')}>
          <text className={dk('transition-detail-key')}>kind</text>
          <text className={dk('transition-detail-value')}>{transitionKind}</text>
        </view>
        <view className={dk('transition-detail-row')}>
          <text className={dk('transition-detail-key')}>transactionID</text>
          <text className={dk('transition-detail-value')}>{transactionID || '(由原生首屏门禁接管)'}</text>
        </view>
        <text className={dk('transition-detail-ready')}>{readyResult}</text>
      </view>

      <view className={dk('transition-detail-card')}>
        <text className={dk('transition-detail-card-title')}>低频诊断状态</text>
        <text className={dk('transition-detail-state')}>
          {state
            ? `${state.status} · ${state.requestedTransition} → ${state.effectiveTransition}`
              + ` · ${Math.round(state.progress * 100)}%${state.reason ? ` · ${state.reason}` : ''}`
            : '点击读取；页面不会把 progress 写回原生。'}
        </text>
        <view className="transition-detail-actions">
          <view
            className={dk('transition-detail-button')}
            bindtap={refreshState}
            accessibility-element
            accessibility-label="读取原生转场状态"
            accessibility-traits="button"
          >
            <text className={dk('transition-detail-button-text')}>读取状态</text>
          </view>
          <view
            className="transition-detail-button transition-detail-button--primary"
            bindtap={() => { 'background only'; close() }}
            accessibility-element
            accessibility-label="返回上一个原生页面"
            accessibility-traits="button"
          >
            <text className="transition-detail-button-text transition-detail-button-text--primary">原生返回</text>
          </view>
        </view>
      </view>

      <view className={dk('transition-detail-note')}>
        <text className={dk('transition-detail-note-title')}>取消语义</text>
        <text className={dk('transition-detail-note-text')}>
          手势取消时不写页面结果、不修改最终栈；完成 settle 到 100% 后，原生才提交一次 pop/finish。
        </text>
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <TransitionDetailContent />
    </ThemeProvider>
  )
}
