import { useEffect, useRef, useState } from '@lynx-js/react'
import { MapTopBar } from '../../components/MapTopBar/index.js'
import { SafeAreaView } from '../../components/SafeAreaView.js'
import { LynxMap } from '../../native-elements/map/index.js'
import {
  getAuthorizationStatus,
  getCurrentLocation,
  onLocation,
  onLocationAuthorization,
  onLocationError,
  startLocation,
  stopLocation,
  type LynxLocation,
  type LynxLocationAuthorization,
} from '../../native-elements/location/index.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import './App.css'

const defaultCenter = { latitude: 39.9042, longitude: 116.4074 }

function formatCoordinate(value: number | undefined) {
  return Number.isFinite(value) ? value!.toFixed(6) : '—'
}

function LocationContent() {
  const { resolved } = useTheme()
  const [location, setLocation] = useState<LynxLocation | null>(null)
  const [authorization, setAuthorization] = useState<LynxLocationAuthorization | null>(null)
  const [status, setStatus] = useState('等待定位操作')
  const [tracking, setTracking] = useState(false)
  const trackingRef = useRef(false)
  const dark = resolved === 'dark'

  useEffect(() => {
    const removeLocation = onLocation((value) => {
      setLocation(value)
      setStatus('收到连续定位更新')
    })
    const removeError = onLocationError((error) => setStatus(`${error.code}：${error.message}`))
    const removeAuthorization = onLocationAuthorization((value) => {
      setAuthorization((current) => ({
        servicesEnabled: current?.servicesEnabled ?? true,
        ...value,
      }))
    })
    getAuthorizationStatus()
      .then(setAuthorization)
      .catch((error) => setStatus(error.message))
    return () => {
      removeLocation()
      removeError()
      removeAuthorization()
      if (trackingRef.current) {
        stopLocation().catch(() => {})
        trackingRef.current = false
      }
    }
  }, [])

  const requestCurrent = () => {
    setStatus('请求单次定位…')
    getCurrentLocation({
      withReGeocode: true,
      desiredAccuracy: 100,
      locationTimeout: 8,
      reGeocodeTimeout: 5,
    })
      .then((value) => {
        setLocation(value)
        setStatus('单次定位成功')
      })
      .catch((error) => setStatus(`${error.code}：${error.message}`))
  }

  const toggleTracking = () => {
    if (tracking) {
      stopLocation()
        .then(() => {
          trackingRef.current = false
          setTracking(false)
          setStatus('连续定位已停止')
        })
        .catch((error) => setStatus(`${error.code}：${error.message}`))
      return
    }
    setStatus('请求连续定位权限…')
    startLocation({ withReGeocode: false, desiredAccuracy: 100, distanceFilter: 25 })
      .then(() => {
        trackingRef.current = true
        setTracking(true)
        setStatus('连续定位已启动，等待位置更新')
      })
      .catch((error) => setStatus(`${error.code}：${error.message}`))
  }

  const refreshAuthorization = () => {
    getAuthorizationStatus()
      .then(setAuthorization)
      .catch((error) => setStatus(error.message))
  }

  const center = location
    ? { latitude: location.latitude, longitude: location.longitude }
    : defaultCenter
  const markers = location
    ? [{ id: 'current-location', coordinate: center, title: '当前位置', selected: true }]
    : []

  return (
    <SafeAreaView className="location-shell" edges={['top', 'bottom']} style={{ height: '100vh' }}>
      <MapTopBar title="高德定位 SDK" subtitle="单次定位 / 连续定位 / 权限状态" dark={dark} />
      <scroll-view className="location-scroll" scroll-orientation="vertical">
        <view className={`location-page ${dark ? 'location-page--dark' : 'location-page--light'}`}>
          <text className="location-title">定位能力 Demo</text>
          <text className="location-description">使用 AMapLocationKit 2.12.3，Key 和高德隐私同意状态沿用宿主配置；定位结果通过 typed service 返回给 Lynx。</text>

          <view className="location-map-stage">
            <LynxMap
              id="ios-amap-location"
              className="location-map"
              center={center}
              zoom={location ? 14 : 12}
              markers={markers}
              showsCompass
              showsScale
              onReady={() => setStatus('地图 ready，等待定位操作')}
              onError={(error) => setStatus(`${error.code}：${error.message}`)}
            />
            <view className="location-map-overlay">
              <text className="location-map-overlay-title">当前位置 MapView</text>
              <text className="location-map-overlay-copy">{location ? '定位点已回填到地图' : '定位成功后会显示当前位置 Marker'}</text>
            </view>
          </view>

          <view className="location-actions">
            <view className="location-action" bindtap={requestCurrent} accessibility-label="获取单次定位" accessibility-traits="button">
              <text className="location-action-text">获取单次定位</text>
            </view>
            <view className="location-action" bindtap={toggleTracking} accessibility-label={tracking ? '停止连续定位' : '开始连续定位'} accessibility-traits="button">
              <text className="location-action-text">{tracking ? '停止连续定位' : '开始连续定位'}</text>
            </view>
            <view className="location-action location-action--secondary" bindtap={refreshAuthorization} accessibility-label="刷新定位权限" accessibility-traits="button">
              <text className="location-action-text">刷新权限</text>
            </view>
          </view>

          <view className="location-card">
            <text className="location-card-title">权限状态</text>
            <text className="location-card-copy">status={authorization?.status || 'loading'} · accuracy={authorization?.accuracy || 'unknown'} · services={String(authorization?.servicesEnabled ?? 'unknown')}</text>
          </view>

          <view className="location-card">
            <text className="location-card-title">定位结果</text>
            <text className="location-card-copy">latitude：{formatCoordinate(location?.latitude)}</text>
            <text className="location-card-copy">longitude：{formatCoordinate(location?.longitude)}</text>
            <text className="location-card-copy">accuracy：{location?.accuracy?.toFixed(1) || '—'} m · timestamp：{location?.timestamp ? new Date(location.timestamp).toLocaleTimeString() : '—'}</text>
            {location?.reGeocode?.formattedAddress ? <text className="location-card-copy">address：{location.reGeocode.formattedAddress}</text> : null}
            <text className="location-status">{status}</text>
          </view>

          <view className="location-card location-card--notes">
            <text className="location-card-title">边界说明</text>
            <text className="location-card-copy">单次定位会在完成回调后保留 manager；连续定位离开页面时自动 stop 并解除 delegate。</text>
            <text className="location-card-copy">只申请 When In Use 权限；后台定位、地理围栏和轨迹上报需要独立宿主能力与产品授权。</text>
          </view>
        </view>
      </scroll-view>
    </SafeAreaView>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <LocationContent />
    </ThemeProvider>
  )
}
