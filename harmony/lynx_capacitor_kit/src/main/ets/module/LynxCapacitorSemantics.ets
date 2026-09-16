/**
 * 三端共用的能力语义字段和错误分类。
 *
 * 该类型只描述公共协议，不替代 HarmonyOS 的具体 Kit 适配器。
 */
export interface LynxCapabilityStatusDefinition {
  state: string;
  reasonCode: string;
  reason: string;
}

export default class LynxCapacitorSemantics {
  public static readonly contractVersion: string = '1.1';

  public static semanticState(state: string): string {
    if (state === 'implemented') return 'native';
    if (state === 'native' || state === 'partial' || state === 'unsupported') return state;
    return 'partial';
  }

  public static definition(name: string): LynxCapabilityStatusDefinition {
    switch (name) {
      case 'Biometrics':
        return { state: 'unsupported', reasonCode: 'PLATFORM_UNSUPPORTED', reason: '当前平台没有可安全承诺的等价实现。' };
      case 'Contacts':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '联系人 CRUD 和权限分支已接入，账户或系统 Provider 仍需设备验证。' };
      case 'Toast':
        return { state: 'partial', reasonCode: 'RUNTIME_VERIFICATION_REQUIRED', reason: '轻提示分支已接入，设备 UI 行为仍需验证。' };
      case 'Haptics':
        return { state: 'partial', reasonCode: 'APPROXIMATE_IMPLEMENTATION', reason: '使用 HarmonyOS 触感模式近似映射，不能承诺 Android primitive 硬件等价。' };
      case 'Share':
        return { state: 'partial', reasonCode: 'SEMANTIC_VARIANT', reason: '文本或 URL 分享已接入，文件 URI 和系统回执语义仍需对齐。' };
      case 'Camera':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '相册、拍照、录像和播放已有入口，权限拒绝、取消和设备行为仍需验证。' };
      case 'Audio':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: 'MediaKit 录音和播放已有入口，麦克风权限与设备音频行为仍需验证。' };
      case 'FileTransfer':
        return { state: 'partial', reasonCode: 'SEMANTIC_VARIANT', reason: '下载、进度、状态和取消已有入口，网络任务和生命周期语义仍需对账。' };
      case 'FileViewer':
        return { state: 'partial', reasonCode: 'RUNTIME_CONTEXT_REQUIRED', reason: '本地文档打开已有 Want 入口，设备查看器仍需验证。' };
      case 'CapacitorCookies':
        return { state: 'partial', reasonCode: 'SECURITY_SCOPE_RESTRICTED', reason: 'WebCookieManager 已接入，Cookie scope 和清理语义仍需对账。' };
      case 'Browser':
        return { state: 'partial', reasonCode: 'EXTERNAL_OWNER', reason: '外部浏览器由系统或第三方应用管理，close 不属于当前 Module 的控制范围。' };
      case 'InAppBrowser':
        return { state: 'partial', reasonCode: 'RUNTIME_CONTEXT_REQUIRED', reason: 'WebView 的打开和关闭已有入口，前台窗口与销毁行为仍需验证。' };
      case 'Geolocation':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '定位权限和当前位置已有入口，定位服务和设备行为仍需验证。' };
      case 'Motion':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '传感器监听和 start/stop 已接入，权限和设备传感器仍需验证。' };
      case 'ScreenOrientation':
        return { state: 'implemented', reasonCode: 'NONE', reason: '公共最小语义在源码中已实现。' };
      case 'ScreenReader':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '状态查询和播报已有入口，设备无障碍服务仍需验证。' };
      case 'Keyboard':
        return { state: 'partial', reasonCode: 'PLATFORM_UNSUPPORTED', reason: 'resize 和 hide 已接入，setStyle 按 Android 基线不提供。' };
      case 'SplashScreen':
        return { state: 'partial', reasonCode: 'RUNTIME_CONTEXT_REQUIRED', reason: '启动遮罩已有 overlay，冷启动时序仍需宿主验证。' };
      case 'Calendar':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: 'CalendarKit CRUD 和权限 gate 已接入，设备账户仍需验证。' };
      case 'LocalNotifications':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: '排程、待处理、取消和 channel 已接入，权限和设备送达仍需验证。' };
      case 'PushNotifications':
        return { state: 'partial', reasonCode: 'HOST_PROVIDER_REQUIRED', reason: '权限和宿主事件入口已保留，register 需要厂商 Provider。' };
      case 'CapacitorBarcodeScanner':
        return { state: 'partial', reasonCode: 'DEVICE_FEATURE_REQUIRED', reason: 'ScanKit 已接入，权限、取消和设备行为仍需验证。' };
      case 'BackgroundRunner':
        return { state: 'partial', reasonCode: 'HOST_PROVIDER_REQUIRED', reason: '权限方法可用，dispatchEvent 需要后台宿主能力。' };
      case 'CapacitorSQLite':
        return { state: 'partial', reasonCode: 'SEMANTIC_VARIANT', reason: 'ArkData 基础 SQL 已接入，字段和事务边界仍需与 Android 对账。' };
      case 'Filesystem':
        return { state: 'implemented', reasonCode: 'NONE', reason: '公共最小语义在源码中已实现。' };
      case 'Network':
      case 'CapacitorHttp':
      case 'TextZoom':
      case 'App':
      case 'AppLauncher':
      case 'Device':
      case 'Preferences':
      case 'Dialog':
      case 'ActionSheet':
      case 'Clipboard':
      case 'StatusBar':
      case 'SystemBars':
      case 'PrivacyScreen':
      case 'KeepAwake':
      case 'SafeArea':
        return { state: 'implemented', reasonCode: 'NONE', reason: '公共最小语义在源码中已实现。' };
      default:
        return { state: 'partial', reasonCode: 'RUNTIME_VERIFICATION_REQUIRED', reason: '源码分支存在，但还没有完整运行证据。' };
    }
  }

  public static unsupportedMethods(name: string): Array<string> {
    switch (name) {
      case 'Biometrics': return ['isAvailable', 'getBiometryType', 'authenticate'];
      case 'Browser': return ['close'];
      case 'Keyboard': return ['setStyle'];
      case 'PushNotifications': return ['register'];
      case 'BackgroundRunner': return ['dispatchEvent'];
      default: return [];
    }
  }

  public static methodReasonCode(name: string, method: string, implemented: boolean): string {
    if (implemented) return 'NONE';
    if (name === 'Browser' && method === 'close') return 'EXTERNAL_OWNER';
    if (name === 'Keyboard' && method === 'setStyle') return 'PLATFORM_UNSUPPORTED';
    if (name === 'PushNotifications' && method === 'register') return 'HOST_PROVIDER_REQUIRED';
    if (name === 'BackgroundRunner' && method === 'dispatchEvent') return 'HOST_PROVIDER_REQUIRED';
    if (name === 'Biometrics') return 'PLATFORM_UNSUPPORTED';
    return 'METHOD_GAP';
  }

  public static methodStatus(name: string, methods: Array<string>): Array<Record<string, Object>> {
    const missing = LynxCapacitorSemantics.unsupportedMethods(name);
    const result: Array<Record<string, Object>> = [];
    methods.forEach((method: string): void => {
      const implemented = missing.indexOf(method) < 0;
      result.push({
        name: method,
        state: implemented ? 'native' : 'unsupported',
        reasonCode: LynxCapacitorSemantics.methodReasonCode(name, method, implemented)
      });
    });
    return result;
  }

  public static verification(): Record<string, Object> {
    return { source: 'verified', build: 'not_run', host: 'not_integrated', device: 'not_run' };
  }

  public static errorReasonCode(code: string): string {
    switch (code) {
      case 'INVALID_PAYLOAD': return 'INVALID_PAYLOAD';
      case 'INVALID_ARGUMENT': return 'INVALID_ARGUMENT';
      case 'UNIMPLEMENTED': return 'METHOD_GAP';
      case 'UNSUPPORTED': return 'PLATFORM_UNSUPPORTED';
      case 'PERMISSION_NOT_DECLARED': return 'HOST_PERMISSION_CONFIGURATION_REQUIRED';
      case 'PERMISSION_DENIED': return 'RUNTIME_PERMISSION_DENIED';
      case 'MODULE_UNAVAILABLE':
      case 'SCENE_UNAVAILABLE':
      case 'HOST_UNAVAILABLE': return 'RUNTIME_CONTEXT_REQUIRED';
      case 'CANCELLED': return 'CANCELLED';
      case 'ACTIVITY_DESTROYED':
      case 'HOST_DESTROYED': return 'HOST_DESTROYED';
      default: return 'NATIVE_ERROR';
    }
  }
}
