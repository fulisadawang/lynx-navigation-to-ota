import { shareElementSelector } from '../../lib/navigation.js'

export interface ShareElementProps {
  /** 同一条原生路由的来源页、目标页使用相同 key 即可自动配对。 */
  shareKey: string
  className?: string
  style?: Record<string, string | number>
  children: any
}

/**
 * Skyline share-element 的 Lynx 侧轻量包装。
 *
 * 组件只负责把业务 key 稳定映射为相同 id；元素测量、快照、矩形插值、
 * push/pop 动画与跟手返回均由 Activity / UIViewController 原生层完成。
 */
export function ShareElement(props: ShareElementProps) {
  // 共享元素必须拥有独立原生渲染节点。若沿用 view 默认的 flatten=true，
  // 子图片/文字可能被提升到外层，原生隐藏 wrapper 时就会留下重影。
  return (
    <view
      id={shareElementSelector(props.shareKey)}
      flatten={false}
      className={props.className}
      style={props.style}
    >
      {props.children}
    </view>
  )
}
