import { close } from '../../lib/navigation.js'
import './index.css'

interface MapTopBarProps {
  title: string
  subtitle?: string
  dark?: boolean
}

/** 地图沉浸式页面共用的返回栏；地图只占返回栏以下的区域。 */
export function MapTopBar(props: MapTopBarProps) {
  const handleBack = () => {
    'background only'
    close()
  }

  return (
    <view className={`map-top-bar ${props.dark ? 'map-top-bar--dark' : 'map-top-bar--light'}`}>
      <view
        className="map-top-bar-back"
        bindtap={handleBack}
        accessibility-label="返回"
        accessibility-traits="button"
      >
        <text className="map-top-bar-back-text">‹</text>
      </view>
      <view className="map-top-bar-copy">
        <text className="map-top-bar-title">{props.title}</text>
        {props.subtitle ? <text className="map-top-bar-subtitle">{props.subtitle}</text> : null}
      </view>
      <view className="map-top-bar-spacer" />
    </view>
  )
}
