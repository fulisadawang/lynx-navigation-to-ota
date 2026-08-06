import { useState } from '@lynx-js/react'
import { DemoPage } from '../../components/DemoPage/index.js'
import {
  GO_LYNX_BUNDLE_CATEGORIES,
  GO_LYNX_BUNDLE_EXAMPLES,
  type GoLynxBundleExample,
} from '../../data/goLynxBundleUrls.js'
import { navigate } from '../../lib/navigation.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

const PAGE_SIZE = 40

/**
 * go.lynxjs.org 官方 Bundle 索引。
 *
 * 清单有 565 项，因此只渲染当前筛选结果的前 PAGE_SIZE 项，用户点击“加载更多”后再
 * 扩容。这样能避免一次创建数百个 Lynx 节点，降低首屏和滚动压力。
 */
function GoBundleLibrary() {
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'
  const [query, setQuery] = useState('')
  const [category, setCategory] = useState('全部')
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE)
  const [openingPath, setOpeningPath] = useState('')
  const [status, setStatus] = useState('')

  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`
  const normalizedQuery = query.trim().toLowerCase()
  const filteredExamples = GO_LYNX_BUNDLE_EXAMPLES.filter((item) => {
    const categoryMatches = category === '全部' || item.category === category
    const queryMatches = normalizedQuery.length === 0
      || item.name.toLowerCase().includes(normalizedQuery)
      || item.category.toLowerCase().includes(normalizedQuery)
      || item.path.toLowerCase().includes(normalizedQuery)
    return categoryMatches && queryMatches
  })
  const visibleExamples = filteredExamples.slice(0, visibleCount)
  const hasMore = visibleExamples.length < filteredExamples.length

  const handleSearch = (event: { detail: { value: string } }) => {
    'background only'
    setQuery(event.detail.value)
    setVisibleCount(PAGE_SIZE)
  }

  const handleCategory = (nextCategory: string) => {
    'background only'
    setCategory(nextCategory)
    setVisibleCount(PAGE_SIZE)
  }

  const handleOpen = (item: GoLynxBundleExample) => {
    'background only'
    setOpeningPath(item.path)
    setStatus(`正在打开 ${item.category}/${item.name}…`)

    navigate({
      path: item.url,
      options: {
        routeKey: `go-lynx:${item.path}`,
        launchMode: 'push',
        params: {
          title: `${item.category}/${item.name}`,
        },
      },
    }, (result) => {
      setOpeningPath('')
      setStatus(
        result.code === 1
          ? `已提交打开：${item.name}`
          : `打开失败：${result.msg || '未知错误'}`,
      )
    })
  }

  return (
    <DemoPage title="官方 Bundle 示例">
      <view className="go-header">
        <view className="go-header-icon">
          <text className="go-header-icon-text">{'\u{1F9EA}'}</text>
        </view>
        <view className="go-header-copy">
          <text className={dk('go-title')}>官方 Bundle 示例库</text>
          <text className={dk('go-subtitle')}>
            go.lynxjs.org · {GO_LYNX_BUNDLE_EXAMPLES.length} 个示例
          </text>
        </view>
      </view>

      <view className={dk('go-notice')}>
        <text className={dk('go-notice-text')}>
          示例来自清单快照。部分页面可能依赖更新版 Lynx、额外原生组件或网络资源，
          能否完整渲染以目标 Bundle 的运行要求为准。
        </text>
      </view>

      <view className={dk('go-search-card')}>
        <input
          className={dk('go-search-input')}
          value={query}
          bindinput={handleSearch}
          placeholder="搜索分类、示例名或路径"
          confirm-type="search"
          accessibility-label="搜索官方 Lynx Bundle"
        />
        {query.length > 0 ? (
          <view
            className={dk('go-clear-button')}
            bindtap={() => {
              'background only'
              setQuery('')
              setVisibleCount(PAGE_SIZE)
            }}
            accessibility-element
            accessibility-label="清空搜索"
            accessibility-traits="button"
          >
            <text className={dk('go-clear-text')}>清空</text>
          </view>
        ) : null}
      </view>

      <scroll-view className="go-category-scroll" scroll-orientation="horizontal">
        <view className="go-category-row">
          {['全部', ...GO_LYNX_BUNDLE_CATEGORIES].map((item) => {
            const selected = item === category
            return (
              <view
                key={item}
                className={`go-category-chip ${selected ? 'go-category-chip--selected' : dk('go-category-chip')}`}
                bindtap={() => handleCategory(item)}
                accessibility-element
                accessibility-label={`筛选 ${item}`}
                accessibility-traits="button"
              >
                <text
                  className={`go-category-text ${selected ? 'go-category-text--selected' : dk('go-category-text')}`}
                >
                  {item}
                </text>
              </view>
            )
          })}
        </view>
      </scroll-view>

      <view className="go-result-header">
        <text className={dk('go-result-count')}>
          找到 {filteredExamples.length} 个，当前显示 {visibleExamples.length} 个
        </text>
        {category !== '全部' ? (
          <text className="go-active-category">{category}</text>
        ) : null}
      </view>

      {status.length > 0 ? (
        <view className={dk('go-status')}>
          <text className={dk('go-status-text')}>{status}</text>
        </view>
      ) : null}

      <view className="go-results">
        {visibleExamples.map((item) => (
          <view
            key={item.path}
            className={dk('go-bundle-card')}
            bindtap={() => handleOpen(item)}
            accessibility-element
            accessibility-label={`打开 ${item.category} ${item.name}`}
            accessibility-traits="button"
          >
            <view className="go-bundle-main">
              <view className="go-bundle-title-row">
                <text className="go-bundle-category">{item.category}</text>
                <text className={dk('go-bundle-name')}>{item.name}</text>
              </view>
              <text className={dk('go-bundle-path')}>{item.path}</text>
            </view>
            <view
              className={`go-open-button ${openingPath === item.path ? 'go-open-button--loading' : ''}`}
            >
              <text className="go-open-button-text">
                {openingPath === item.path ? '打开中' : '打开'}
              </text>
            </view>
          </view>
        ))}
      </view>

      {filteredExamples.length === 0 ? (
        <view className={dk('go-empty')}>
          <text className="go-empty-icon">{'\u{1F50D}'}</text>
          <text className={dk('go-empty-title')}>没有匹配的 Bundle</text>
          <text className={dk('go-empty-hint')}>换一个关键词或选择“全部”分类。</text>
        </view>
      ) : null}

      {hasMore ? (
        <view
          className={dk('go-load-more')}
          bindtap={() => {
            'background only'
            setVisibleCount((count) => count + PAGE_SIZE)
          }}
          accessibility-element
          accessibility-label="加载更多 Bundle"
          accessibility-traits="button"
        >
          <text className="go-load-more-text">
            再加载 {Math.min(PAGE_SIZE, filteredExamples.length - visibleExamples.length)} 个
          </text>
        </view>
      ) : null}
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <GoBundleLibrary />
    </ThemeProvider>
  )
}
