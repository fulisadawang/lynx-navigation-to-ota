import { useEffect, useState } from '@lynx-js/react'

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
