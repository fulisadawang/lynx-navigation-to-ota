import LynxCapacitorSemantics from './LynxCapacitorSemantics';

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

  /** 状态保留旧字段，同时输出三端统一的语义状态、原因和验证层级。 */
  public static status(): string {
    const rows = JSON.parse(LynxCapacitorCatalog.headers()) as Array<Record<string, Object>>;
    const result: Array<Record<string, Object>> = [];
    rows.forEach((row: Record<string, Object>): void => {
      const name = String(row['name'] ?? '');
      const methodsRows = row['methods'] as Array<Record<string, Object>>;
      const methods: Array<string> = [];
      methodsRows.forEach((method: Record<string, Object>): void => {
        methods.push(String(method['name'] ?? ''));
      });
      const definition = LynxCapacitorSemantics.definition(name);
      result.push({
        name: name,
        methods: methods,
        implementedMethods: methods.filter((method: string): boolean => LynxCapacitorSemantics.unsupportedMethods(name).indexOf(method) < 0),
        state: definition.state,
        contractVersion: LynxCapacitorSemantics.contractVersion,
        semanticState: LynxCapacitorSemantics.semanticState(definition.state),
        reasonCode: definition.reasonCode,
        reason: definition.reason,
        methodStatus: LynxCapacitorSemantics.methodStatus(name, methods),
        verification: LynxCapacitorSemantics.verification(),
        platform: 'harmony'
      });
    });
    return JSON.stringify(result);
  }
}
