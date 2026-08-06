import { useState } from '@lynx-js/react'
import {
  navigate,
  close,
  back,
  popTo,
  closeAll,
  reLaunch,
  redirect,
  getNavigationState,
  closeWithResult,
  consumeNavigationResult,
  type LaunchMode,
  type NavigationState,
} from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { DemoPage } from '../../components/DemoPage/index.js'
import { ResultCard } from '../../components/ResultCard/index.js'

import './App.css'

function NavChainContent() {
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'
  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  const globalProps = lynx.__globalProps
  const queryItems: Record<string, string> = (globalProps as any)?.queryItems || {}
  const containerID: string = (globalProps as any)?.containerID || ''

  const pageSequence = ['A', 'B', 'C', 'D', 'E']
  const pageID = pageSequence.includes(queryItems.page_id) ? queryItems.page_id : 'A'
  // depth 用于说明当前示例栈，不作为原生栈定位依据；原生只认 routeKey。
  const depth = Number(queryItems.depth) || pageSequence.indexOf(pageID) + 1
  const parentDepth = queryItems.from_depth || '(root)'
  const routeKey = queryItems.route_key || `nav-chain-${pageID}`
  const nextPageID = pageSequence[pageSequence.indexOf(pageID) + 1]

  const [navResult, setNavResult] = useState<{ code: number; msg: string } | undefined>(undefined)
  const [stackState, setStackState] = useState('点击“读取原生栈”查看真实 session')
  const [pageResult, setPageResult] = useState('尚未读取页面返回结果')

  const navigateToPage = (targetPageID: string, launchMode: LaunchMode) => {
    'background only'
    navigate({
      path: 'nav-chain.lynx.bundle',
      options: {
        routeKey: `nav-chain-${targetPageID}`,
        launchMode,
        params: {
          title: `Stack ${targetPageID}`,
          container_bg_color: isDark ? '#000000' : '#f0f2f5',
          nav_bar_color: isDark ? '#000000' : '#ffffff',
          title_color: isDark ? '#FFFFFF' : '#000000',
          force_theme_style: resolved,
          page_id: targetPageID,
          depth: String(targetPageID === pageID ? depth : pageSequence.indexOf(targetPageID) + 1),
          from_depth: String(depth),
          launch_mode: launchMode,
        },
      },
    }, (res: { code: number; msg?: string }) => {
      setNavResult({ code: res.code, msg: res.msg || 'ok' })
    })
  }

  const handlePush = () => {
    'background only'
    if (!nextPageID) {
      setNavResult({ code: 0, msg: '已经到 E，请使用 popTo(A) 或 back(delta)' })
      return
    }
    navigateToPage(nextPageID, 'push')
  }

  const handleClose = () => {
    'background only'
    close()
  }

  const handlePopToA = () => {
    'background only'
    popTo('nav-chain-A', (res) => {
      setNavResult({ code: res.code, msg: res.msg || 'ok' })
    })
  }

  const handleRedirectToA = () => {
    'background only'
    redirect({
      path: 'nav-chain.lynx.bundle',
      options: {
        routeKey: 'nav-chain-A',
        params: {
          title: 'Stack A (Redirect)',
          page_id: 'A',
          depth: String(depth),
          from_depth: String(Math.max(depth - 1, 1)),
          redirected_from: pageID,
          force_theme_style: resolved,
        },
      },
    }, (res) => {
      setNavResult({ code: res.code, msg: res.msg || 'ok' })
    })
  }

  const handleCloseAll = () => {
    'background only'
    closeAll()
  }

  const handleReLaunch = () => {
    'background only'
    reLaunch({ tab: 'home', source: 'nav-chain-demo' })
  }

  const handleBackTwo = () => {
    'background only'
    back(2, { animated: true }, (res) => {
      setNavResult({ code: res.code, msg: res.msg || 'ok' })
    })
  }

  const handleSingleTop = () => {
    'background only'
    navigateToPage(pageID, 'singleTop')
  }

  const handleClearTopA = () => {
    'background only'
    navigateToPage('A', 'clearTop')
  }

  const handleSingleTaskA = () => {
    'background only'
    navigateToPage('A', 'singleTask')
  }

  const handleReadStack = () => {
    'background only'
    getNavigationState((res) => {
      const data = res.data as NavigationState | undefined
      if (!data) {
        setStackState(res.msg || '读取失败')
        return
      }
      const routes = data.stack.map((entry) => entry.routeKey.replace('nav-chain-', '')).join(' > ')
      setStackState(
        `depth=${data.depth}, canGoBack=${String(data.canGoBack)}, stack=${routes || '(empty)'}`,
      )
    })
  }

  const handleCloseWithResult = () => {
    'background only'
    closeWithResult({
      sourcePage: pageID,
      sourceRouteKey: routeKey,
      message: `来自 Stack ${pageID} 的返回结果`,
    }, (res) => {
      setNavResult({ code: res.code, msg: res.msg || 'ok' })
    })
  }

  const handleConsumeResult = () => {
    'background only'
    consumeNavigationResult((res) => {
      const data = res.data
      if (!data?.hasResult) {
        setPageResult(res.msg || '当前 entry 没有结果')
        return
      }
      setPageResult(
        `${data.sourceRouteKey || 'unknown'} -> ${JSON.stringify(data.result || {})}`,
      )
    })
  }

  // 只显示当前 A-E 示例路径；真正的原生定位使用 routeKey。
  const stackDots = pageSequence.slice(0, Math.max(1, Math.min(depth, pageSequence.length)))

  return (
    <DemoPage title={`Stack ${pageID}`}>
      {/* Stack Visualization */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Page Stack</text>
        <text className={dk('chain-section-desc')}>
          当前示例为 A-B-C-D-E。Push 逐级打开；到 E 后用 popTo(A) 一次关闭 B/C/D/E。
        </text>

        <view className="stack-visual">
          {stackDots.map((item) => (
            <view
              key={item}
              className={`stack-dot ${item === pageID ? 'stack-dot--current' : 'stack-dot--past'}`}
            >
              <text className={`stack-dot-text ${item === pageID ? 'stack-dot-text--current' : 'stack-dot-text--past'}`}>
                {item}
              </text>
            </view>
          ))}
          {nextPageID ? (
            <view className="stack-dot stack-dot--next">
              <text className="stack-dot-text stack-dot-text--next">{nextPageID}</text>
            </view>
          ) : <></>}
        </view>
      </view>

      {/* Received Data */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Received Data</text>
        <view className={dk('chain-param-row')}>
          <text className={dk('chain-param-key')}>depth</text>
          <text className={dk('chain-param-value')}>{depth}</text>
        </view>
        <view className={dk('chain-param-row')}>
          <text className={dk('chain-param-key')}>from_depth</text>
          <text className={dk('chain-param-value')}>{parentDepth}</text>
        </view>
        <view className={dk('chain-param-row')}>
          <text className={dk('chain-param-key')}>containerID</text>
          <text className={dk('chain-param-value')} style={{ fontSize: '11px' }}>{containerID || 'N/A'}</text>
        </view>
        <view className={dk('chain-param-row')}>
          <text className={dk('chain-param-key')}>routeKey</text>
          <text className={dk('chain-param-value')} style={{ fontSize: '11px' }}>{routeKey}</text>
        </view>
      </view>

      {/* Native stack state */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Native Stack State</text>
        <text className={dk('chain-section-desc')}>
          不依赖页面自己维护的 depth，直接读取 Android Activity / iOS Navigation 栈。
        </text>
        <text className={dk('chain-state-value')}>{stackState}</text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleReadStack}
          accessibility-element
          accessibility-label="读取原生导航栈"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            读取原生栈
          </text>
        </view>
      </view>

      {/* Push */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Push New Page</text>
        <text className={dk('chain-section-desc')}>
          {nextPageID
            ? `普通打开 ${pageID} -> ${nextPageID}，新增一个原生页面。`
            : '当前已经是 E；下一步请回退到已有 A。'}
        </text>
        <view
          className={isDark ? 'chain-button chain-button--primary-dark' : 'chain-button chain-button--primary-light'}
          bindtap={handlePush}
          accessibility-element
          accessibility-label={nextPageID ? `Push ${nextPageID}` : '已经到 E'}
          accessibility-traits="button"
        >
          <text className="chain-button-text">{nextPageID ? `Push ${nextPageID}` : '已经到 E'}</text>
        </view>
        <ResultCard label="Response" code={navResult?.code} msg={navResult?.msg} />
      </view>

      {/* Launch modes */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Launch Modes</text>
        <text className={dk('chain-section-desc')}>
          singleTop 只刷新同 key 栈顶；clearTop 保留已有 A 的旧参数；singleTask 回到 A 并用新参数刷新。
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleSingleTop}
          accessibility-element
          accessibility-label="singleTop 当前页"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            singleTop(Current)
          </text>
        </view>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleClearTopA}
          accessibility-element
          accessibility-label="clearTop A"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            clearTop(A)
          </text>
        </view>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleSingleTaskA}
          accessibility-element
          accessibility-label="singleTask A"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            singleTask(A)
          </text>
        </view>
      </view>

      {/* Delta back */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Back Delta</text>
        <text className={dk('chain-section-desc')}>
          back(2) 一次回退两层；深度不足时收敛到当前 Lynx session 的 A，不越过宿主页。
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleBackTwo}
          accessibility-element
          accessibility-label="回退两页"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            back(2)
          </text>
        </view>
      </view>

      {/* Pop to existing A */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Pop To Existing A</text>
        <text className={dk('chain-section-desc')}>
          在 E 调用 popTo("nav-chain-A")，关闭 B/C/D/E，只保留第一次进入的 A。
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handlePopToA}
          accessibility-element
          accessibility-label="popTo A"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            popTo(A)
          </text>
        </view>
      </view>

      {/* Redirect */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Redirect Current To A</text>
        <text className={dk('chain-section-desc')}>
          在 C 调用最直观：A-B-C redirect(A) 后得到 A-B-A，C 不再保留。
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleRedirectToA}
          accessibility-element
          accessibility-label="redirect A"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            redirect(A)
          </text>
        </view>
      </view>

      {/* Page result */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Page Result</text>
        <text className={dk('chain-section-desc')}>
          子页 closeWithResult 后，目标 entry 使用 consumeNavigationResult 一次性读取；结果不依赖跨页 JS 回调闭包。
        </text>
        <text className={dk('chain-state-value')}>{pageResult}</text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleCloseWithResult}
          accessibility-element
          accessibility-label="带结果关闭当前页"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            closeWithResult()
          </text>
        </view>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleConsumeResult}
          accessibility-element
          accessibility-label="读取页面返回结果"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            consumeResult()
          </text>
        </view>
      </view>

      {/* Close all and app home */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Leave Lynx Session</text>
        <text className={dk('chain-section-desc')}>
          closeAll 返回进入 Lynx 前的页面；reLaunch 由宿主 Home Handler 返回应用主 Tab。
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleCloseAll}
          accessibility-element
          accessibility-label="closeAll"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            closeAll()
          </text>
        </view>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleReLaunch}
          accessibility-element
          accessibility-label="reLaunch Home"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            reLaunch(Home)
          </text>
        </view>
      </view>

      {/* Pop */}
      <view className={dk('chain-section')}>
        <text className={dk('chain-section-title')}>Pop (Go Back)</text>
        <text className={dk('chain-section-desc')}>
          Calls close() to remove this page from the stack and return to level {depth - 1 || 'root'}.
        </text>
        <view
          className={isDark ? 'chain-button chain-button--secondary-dark' : 'chain-button chain-button--secondary-light'}
          bindtap={handleClose}
          accessibility-element
          accessibility-label="close current"
          accessibility-traits="button"
        >
          <text className={isDark ? 'chain-button-text chain-button-text--secondary-dark' : 'chain-button-text chain-button-text--secondary-light'}>
            Pop (Close)
          </text>
        </view>
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <NavChainContent />
    </ThemeProvider>
  )
}
