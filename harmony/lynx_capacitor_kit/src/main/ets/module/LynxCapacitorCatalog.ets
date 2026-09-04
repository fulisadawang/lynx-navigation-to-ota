/**
 * Android 自有 NativeModule 的 HarmonyOS 协议目录。
 *
 * 这里的 pluginId、方法顺序和 rtype 必须与 Android
 * NativeCapabilityCatalog.kt 保持一致。Harmony 平台没有等价实现时仍保留
 * 方法，让前端能够得到确定的 UNSUPPORTED/UNAVAILABLE 结果，而不是因为
 * headers 缺项落入“能力不存在”的默认分支。
 */
export default class LynxCapacitorCatalog {
  public static headers(): string {
    return '[' +
      '{"name":"Device","methods":[{"name":"getInfo","rtype":"promise"},{"name":"getId","rtype":"promise"},{"name":"getBatteryInfo","rtype":"promise"},{"name":"getLanguageCode","rtype":"promise"},{"name":"getLanguageTag","rtype":"promise"}]},' +
      '{"name":"Biometrics","methods":[{"name":"isAvailable","rtype":"promise"},{"name":"getBiometryType","rtype":"promise"},{"name":"authenticate","rtype":"promise"}]},' +
      '{"name":"App","methods":[{"name":"getInfo","rtype":"promise"},{"name":"getState","rtype":"promise"},{"name":"getLaunchUrl","rtype":"promise"}]},' +
      '{"name":"AppLauncher","methods":[{"name":"canOpenUrl","rtype":"promise"},{"name":"openUrl","rtype":"promise"}]},' +
      '{"name":"Contacts","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"save","rtype":"promise"},{"name":"find","rtype":"promise"},{"name":"remove","rtype":"promise"}]},' +
      '{"name":"Preferences","methods":[{"name":"set","rtype":"promise"},{"name":"get","rtype":"promise"},{"name":"keys","rtype":"promise"},{"name":"remove","rtype":"promise"}]},' +
      '{"name":"Dialog","methods":[{"name":"alert","rtype":"promise"},{"name":"confirm","rtype":"promise"},{"name":"prompt","rtype":"promise"}]},' +
      '{"name":"ActionSheet","methods":[{"name":"showActions","rtype":"promise"}]},' +
      '{"name":"Toast","methods":[{"name":"show","rtype":"promise"},{"name":"getCapabilities","rtype":"promise"},{"name":"cancel","rtype":"promise"}]},' +
      '{"name":"Haptics","methods":[{"name":"impact","rtype":"promise"},{"name":"notification","rtype":"promise"},{"name":"selection","rtype":"promise"},{"name":"vibrate","rtype":"promise"},{"name":"vibrateLong","rtype":"promise"},{"name":"vibrateWaveform","rtype":"promise"},{"name":"vibratePredefined","rtype":"promise"},{"name":"vibrateComposition","rtype":"promise"},{"name":"getCapabilities","rtype":"promise"},{"name":"cancel","rtype":"promise"}]},' +
      '{"name":"Share","methods":[{"name":"canShare","rtype":"promise"},{"name":"share","rtype":"promise"}]},' +
      '{"name":"Clipboard","methods":[{"name":"write","rtype":"promise"},{"name":"read","rtype":"promise"}]},' +
      '{"name":"Filesystem","methods":[{"name":"writeFile","rtype":"promise"},{"name":"readFile","rtype":"promise"},{"name":"readdir","rtype":"promise"},{"name":"stat","rtype":"promise"},{"name":"mkdir","rtype":"promise"},{"name":"getUri","rtype":"promise"}]},' +
      '{"name":"Camera","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"getPhoto","rtype":"promise"},{"name":"pickImages","rtype":"promise"},{"name":"chooseFromGallery","rtype":"promise"},{"name":"takePhoto","rtype":"promise"},{"name":"recordVideo","rtype":"promise"},{"name":"playVideo","rtype":"promise"}]},' +
      '{"name":"Audio","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"record","rtype":"promise"},{"name":"stopRecording","rtype":"promise"},{"name":"play","rtype":"promise"},{"name":"stopPlayback","rtype":"promise"},{"name":"getState","rtype":"promise"}]},' +
      '{"name":"FileTransfer","methods":[{"name":"downloadFile","rtype":"promise"},{"name":"getStatus","rtype":"promise"},{"name":"cancel","rtype":"promise"}]},' +
      '{"name":"FileViewer","methods":[{"name":"openDocumentFromLocalPath","rtype":"promise"}]},' +
      '{"name":"Network","methods":[{"name":"getStatus","rtype":"promise"}]},' +
      '{"name":"CapacitorHttp","methods":[{"name":"request","rtype":"promise"},{"name":"get","rtype":"promise"},{"name":"post","rtype":"promise"}]},' +
      '{"name":"CapacitorCookies","methods":[{"name":"setCookie","rtype":"promise"},{"name":"getCookies","rtype":"promise"},{"name":"clearAllCookies","rtype":"promise"}]},' +
      '{"name":"Browser","methods":[{"name":"open","rtype":"promise"},{"name":"close","rtype":"promise"}]},' +
      '{"name":"InAppBrowser","methods":[{"name":"openInWebView","rtype":"promise"},{"name":"close","rtype":"promise"}]},' +
      '{"name":"Geolocation","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"getCurrentPosition","rtype":"promise"}]},' +
      '{"name":"Motion","methods":[{"name":"addListener","rtype":"promise"},{"name":"removeListener","rtype":"promise"},{"name":"removeAllListeners","rtype":"promise"},{"name":"start","rtype":"promise"},{"name":"stop","rtype":"promise"}]},' +
      '{"name":"StatusBar","methods":[{"name":"getInfo","rtype":"promise"},{"name":"setStyle","rtype":"promise"},{"name":"hide","rtype":"promise"},{"name":"show","rtype":"promise"}]},' +
      '{"name":"SystemBars","methods":[{"name":"setStyle","rtype":"promise"}]},' +
      '{"name":"ScreenOrientation","methods":[{"name":"orientation","rtype":"promise"},{"name":"lock","rtype":"promise"},{"name":"unlock","rtype":"promise"}]},' +
      '{"name":"ScreenReader","methods":[{"name":"isEnabled","rtype":"promise"},{"name":"speak","rtype":"promise"}]},' +
      '{"name":"TextZoom","methods":[{"name":"getPreferred","rtype":"promise"},{"name":"get","rtype":"promise"},{"name":"set","rtype":"promise"}]},' +
      '{"name":"Keyboard","methods":[{"name":"getResizeMode","rtype":"promise"},{"name":"setStyle","rtype":"promise"},{"name":"hide","rtype":"promise"}]},' +
      '{"name":"SplashScreen","methods":[{"name":"hide","rtype":"promise"},{"name":"show","rtype":"promise"}]},' +
      '{"name":"PrivacyScreen","methods":[{"name":"isEnabled","rtype":"promise"},{"name":"enable","rtype":"promise"},{"name":"disable","rtype":"promise"}]},' +
      '{"name":"Calendar","methods":[{"name":"createCalendar","rtype":"promise"},{"name":"createEvent","rtype":"promise"},{"name":"findEvents","rtype":"promise"},{"name":"deleteEvent","rtype":"promise"},{"name":"deleteCalendar","rtype":"promise"},{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"listCalendars","rtype":"promise"}]},' +
      '{"name":"LocalNotifications","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"schedule","rtype":"promise"},{"name":"getPending","rtype":"promise"},{"name":"cancel","rtype":"promise"},{"name":"getDeliveredNotifications","rtype":"promise"},{"name":"createChannel","rtype":"promise"},{"name":"listChannels","rtype":"promise"}]},' +
      '{"name":"PushNotifications","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"register","rtype":"promise"}]},' +
      '{"name":"CapacitorBarcodeScanner","methods":[{"name":"scanBarcode","rtype":"promise"}]},' +
      '{"name":"BackgroundRunner","methods":[{"name":"checkPermissions","rtype":"promise"},{"name":"requestPermissions","rtype":"promise"},{"name":"dispatchEvent","rtype":"promise"}]},' +
      '{"name":"KeepAwake","methods":[{"name":"isSupported","rtype":"promise"},{"name":"isKeptAwake","rtype":"promise"},{"name":"keepAwake","rtype":"promise"},{"name":"allowSleep","rtype":"promise"}]},' +
      '{"name":"SafeArea","methods":[{"name":"setSystemBarsStyle","rtype":"promise"},{"name":"hideSystemBars","rtype":"promise"},{"name":"showSystemBars","rtype":"promise"}]},' +
      '{"name":"CapacitorSQLite","methods":[{"name":"echo","rtype":"promise"},{"name":"createConnection","rtype":"promise"},{"name":"open","rtype":"promise"},{"name":"execute","rtype":"promise"},{"name":"run","rtype":"promise"},{"name":"query","rtype":"promise"},{"name":"close","rtype":"promise"},{"name":"isAvailable","rtype":"promise"}]}' +
      ']';
  }

  /** 统一入口在处理通用 listener 前调用，避免 catalog 外方法绕过核心协议。 */
  public static has(pluginId: string, methodName: string): boolean {
    const rows = JSON.parse(LynxCapacitorCatalog.headers()) as Array<Record<string, Object>>;
    for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      const row = rows[rowIndex];
      if (row === undefined || String(row['name'] ?? '') !== pluginId) continue;
      const methods = row['methods'] as Array<Record<string, Object>>;
      for (let methodIndex = 0; methodIndex < methods.length; methodIndex += 1) {
        const method = methods[methodIndex];
        if (method !== undefined && String(method['name'] ?? '') === methodName) return true;
      }
      return false;
    }
    return false;
  }

  /** 状态只描述 Android 核心 40 域，不包含 Harmony 专属扩展。 */
  public static status(): string {
    return '[' +
      '{"name":"Device","state":"implemented"},' +
      '{"name":"Biometrics","state":"unsupported","reason":"Android 基线明确为 unsupported，Harmony 不返回假成功"},' +
      '{"name":"App","state":"implemented"},' +
      '{"name":"AppLauncher","state":"implemented"},' +
      '{"name":"Contacts","state":"partial","reason":"CRUD、checkPermissions、requestPermissions 已接入；账户/系统 Provider 仍需设备验证"},' +
      '{"name":"Preferences","state":"implemented"},' +
      '{"name":"Dialog","state":"implemented"},' +
      '{"name":"ActionSheet","state":"implemented"},' +
      '{"name":"Toast","state":"partial","reason":"show/getCapabilities/cancel 已接入 UIContext openToast/closeToast；设备 UI 仍需验证"},' +
      '{"name":"Haptics","state":"partial","reason":"impact/notification/selection/长振动/波形/预定义/能力查询/取消已接入；Composition 以 Harmony VibratorPattern 近似复刻，未承诺 Android primitive 硬件等价"},' +
      '{"name":"Share","state":"partial","reason":"文本/URL 已接入，文件 URI 与系统回执仍需补齐"},' +
      '{"name":"Clipboard","state":"implemented"},' +
      '{"name":"Filesystem","state":"implemented"},' +
      '{"name":"Camera","state":"partial","reason":"相册、拍照、录像和播放已有入口，权限拒绝/取消仍需设备验证"},' +
      '{"name":"Audio","state":"partial","reason":"MediaKit AVRecorder/AVPlayer、MICROPHONE 权限、录音/播放/停止和销毁释放已接入；设备音频验证仍需补齐"},' +
      '{"name":"FileTransfer","state":"partial","reason":"NetworkKit 下载已接入 operationId、progress、getStatus、cancel 和 Module 销毁清理；设备网络验证仍需补齐"},' +
      '{"name":"FileViewer","state":"partial","reason":"本地文档打开已有 Want 入口，设备查看器仍需验证"},' +
      '{"name":"Network","state":"implemented"},' +
      '{"name":"CapacitorHttp","state":"implemented"},' +
      '{"name":"CapacitorCookies","state":"partial","reason":"WebCookieManager 已接入，scope 与清理语义仍需对账"},' +
      '{"name":"Browser","state":"partial","reason":"open 已接入，close 按 Android 基线返回 unsupported"},' +
      '{"name":"InAppBrowser","state":"partial","reason":"WebView open/close 已接入，设备验证仍需补齐"},' +
      '{"name":"Geolocation","state":"partial","reason":"权限与当前位置已有实现，设备定位服务仍需验证"},' +
      '{"name":"Motion","state":"partial","reason":"监听和显式 start/stop 已接入 SensorServiceKit；权限/传感器设备验证仍需补齐"},' +
      '{"name":"StatusBar","state":"implemented"},' +
      '{"name":"SystemBars","state":"implemented"},' +
      '{"name":"ScreenOrientation","state":"implemented"},' +
      '{"name":"ScreenReader","state":"partial","reason":"状态查询与播报已接入，设备验证仍需补齐"},' +
      '{"name":"TextZoom","state":"implemented"},' +
      '{"name":"Keyboard","state":"partial","reason":"resize/hide 已接入，setStyle 按 Android 基线返回 unsupported"},' +
      '{"name":"SplashScreen","state":"partial","reason":"overlay 已接入，冷启动时序仍需宿主验证"},' +
      '{"name":"PrivacyScreen","state":"implemented"},' +
      '{"name":"Calendar","state":"partial","reason":"CalendarKit CRUD 与权限 gate 已接入，设备账户权限仍需验证"},' +
      '{"name":"LocalNotifications","state":"partial","reason":"排程、待处理、取消和 channel create/list 已接入 ReminderAgent slot；通知权限与设备送达仍需验证"},' +
      '{"name":"PushNotifications","state":"partial","reason":"权限与宿主事件转发已接入，register 按 Android 基线返回 unsupported"},' +
      '{"name":"CapacitorBarcodeScanner","state":"partial","reason":"ScanKit 已接入，权限、取消和设备验证仍需补齐"},' +
      '{"name":"BackgroundRunner","state":"partial","reason":"权限方法可用，dispatchEvent 按 Android 基线返回 unsupported"},' +
      '{"name":"KeepAwake","state":"implemented"},' +
      '{"name":"SafeArea","state":"implemented"},' +
      '{"name":"CapacitorSQLite","state":"partial","reason":"ArkData 基础 SQL、正式 ID 和 isAvailable 已接入；与 Android SQLite 字段/事务边界仍需设备对账"}' +
      ']';
  }
}
