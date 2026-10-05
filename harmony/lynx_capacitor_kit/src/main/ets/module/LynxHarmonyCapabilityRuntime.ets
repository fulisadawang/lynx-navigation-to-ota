import { LynxHarmonyPreferences } from './LynxHarmonyPreferences';
import { LynxHarmonyLegacyMedia } from './LynxHarmonyLegacyMedia';
import { LynxHarmonyShare } from './LynxHarmonyShare';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxCapacitorHost, LynxCapacitorHosts, LynxCapacitorWindowLeases } from './LynxCapacitorHost';
import { LynxHarmonyNativeIO, LYNX_PAYLOAD_BYTES, LYNX_RESULT_BYTES, lynxUTF8Bytes, lynxNativeErrorCode } from './LynxHarmonyNativeIO';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';
import { LynxHarmonyPermissions } from './LynxHarmonyPermissions';
import { LynxHarmonyHttp } from './LynxHarmonyHttp';
import { LynxHarmonyTransfer } from './LynxHarmonyTransfer';
import { LynxHarmonySQLite } from './LynxHarmonySQLite';
import { LynxHarmonyBiometrics } from './LynxHarmonyBiometrics';
import { LynxHarmonyMediaCapabilities } from './LynxHarmonyMediaCapabilities';
import { LynxHarmonyMediaMenu, LynxHarmonyMediaChoice } from './LynxHarmonyMediaDialog';
import { BusinessError, batteryInfo, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';
import util from '@ohos.util';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import Want from '@ohos.app.ability.Want';
import vibrator from '@ohos.vibrator';
import { ComponentContent, display, promptAction, uiAppearance, window } from '@kit.ArkUI';
import { UIContext } from '@ohos.arkui.UIContext';
import { i18n } from '@kit.LocalizationKit';
import { sensor } from '@kit.SensorServiceKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { contact } from '@kit.ContactsKit';
import { calendarManager } from '@kit.CalendarKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { accessibility } from '@kit.AccessibilityKit';
import { inputMethod } from '@kit.IMEKit';
import { webview } from '@kit.ArkWeb';
import { LynxContext } from '@lynx/lynx';
import LynxCapacitorCatalog from './LynxCapacitorCatalog';
import LynxCapacitorEnvelope from './LynxCapacitorEnvelope';
import LynxHarmonyAudioCapabilities, { LynxHarmonyAudioResult } from './LynxHarmonyAudioCapabilities';

interface LynxCapacitorListener {
  pluginId: string;
  eventName: string;
}

interface LynxCapacitorRotationRate {
  alpha: number;
  beta: number;
  gamma: number;
}

interface LynxCapacitorLocalNotification {
  id: number;
  title: string;
  body: string;
}

interface LynxCapacitorNotificationChannel {
  id: string;
  name: string;
  description: string;
  importance: string;
  slotType: notificationManager.SlotType;
}

interface LynxCapacitorNotificationSlot {
  notificationType: notificationManager.SlotType;
  desc: string;
  vibrationEnabled: boolean;
  soundEnabled: boolean;
}

interface LynxCapacitorNotificationReference {
  id: string;
}

interface LynxCapacitorHapticsCompositionStatus {
  available: boolean;
  mode?: string;
  androidPrimitiveParity?: boolean;
  reason: string;
}

interface LynxCapacitorNotificationActionEvent {
  actionId: string;
  notification: LynxCapacitorNotificationReference;
}

interface LynxCapacitorDeliveredNotification {
  id: number;
  title: string;
  body: string;
  data: Object;
  tag?: string;
  group?: string;
  deliveryTime?: number;
}

interface LynxCapacitorPendingNotification {
  id: number;
  title: string;
  body: string;
}

interface LynxCapacitorCalendarEventMatch {
  calendar: calendarManager.Calendar;
  event: calendarManager.Event;
}

interface LynxCapacitorCalendarEventGroup {
  calendar: calendarManager.Calendar;
  events: Array<calendarManager.Event>;
}

interface LynxCapacitorAccessibilityEvent {
  type: string;
  textAnnouncedForAccessibility: string;
}

interface LynxCapacitorPromptDialogParams {
  title: string;
  message: string;
  placeholder: string;
  initialValue: string;
  showInput: boolean;
  showCancel: boolean;
  cancelText: string;
  confirmText: string;
  onConfirm: (value: string) => void;
  onCancel: () => void;
}

@Component
struct LynxCapacitorPromptDialog {
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop placeholder: string = '';
  @Prop initialValue: string = '';
  @Prop showInput: boolean = true;
  @Prop showCancel: boolean = true;
  @Prop cancelText: string = 'Cancel';
  @Prop confirmText: string = 'OK';
  onConfirm: (value: string) => void = (_value: string): void => {};
  onCancel: () => void = (): void => {};
  @State inputValue: string = '';

  aboutToAppear(): void {
    this.inputValue = this.initialValue;
  }

  build(): void {
    Column() {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
          .width('100%');
      }
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(16)
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 12 });
      }
      if (this.showInput) {
      TextInput({ placeholder: this.placeholder, text: this.inputValue })
        .width('100%')
        .height(44)
        .margin({ top: 20 })
        .onChange((value: string): void => {
          this.inputValue = value;
        });
      }
      Row() {
        if (this.showCancel) {
        Text(this.cancelText)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .height(48)
          .onClick((): void => {
            this.onCancel();
          });
        }
        Text(this.confirmText)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .height(48)
          .onClick((): void => {
            this.onConfirm(this.inputValue);
          });
      }
      .width('100%')
      .margin({ top: 16 });
    }
    .width(327)
    .padding(24)
    .backgroundColor(Color.White)
    .borderRadius(20);
  }
}

@Builder
function LynxCapacitorPromptDialogBuilder(params: LynxCapacitorPromptDialogParams): void {
  LynxCapacitorPromptDialog({
    title: params.title,
    message: params.message,
    placeholder: params.placeholder,
    initialValue: params.initialValue,
    showInput: params.showInput,
    showCancel: params.showCancel,
    cancelText: params.cancelText,
    confirmText: params.confirmText,
    onConfirm: params.onConfirm,
    onCancel: params.onCancel,
  });
}

interface LynxCapacitorWebViewDialogParams {
  url: string;
  headers: Array<webview.WebHeader>;
  onPageBegin: (url: string) => void;
  onClose: () => void;
  onPageLoaded: (url: string) => void;
  onTitle: (title: string) => void;
  onError: (url: string, code: number, message: string) => void;
}

interface LynxCapacitorWebViewError {
  code: number;
  message: string;
}

interface LynxCapacitorWebViewErrorPayload {
  success: boolean;
  url: string;
  error: LynxCapacitorWebViewError;
}

/**
 * Harmony InAppBrowser 的宿主 UI coordinator。
 *
 * Web 仍然是 ArkUI 原生 Web 组件，Lynx 页面只通过 LynxHarmonyCapabilityRuntime 调用；
 * 不把 Web 注册成 Lynx UI 元素，也不依赖 Autolink 或 WebView transport。
 */
@Component
struct LynxCapacitorWebViewDialog {
  @Prop url: string = '';
  @Prop headers: Array<webview.WebHeader> = [];
  onClose: () => void = (): void => {};
  onPageBegin: (url: string) => void = (_url: string): void => {};
  onPageLoaded: (url: string) => void = (_url: string): void => {};
  onTitle: (title: string) => void = (_title: string): void => {};
  onError: (url: string, code: number, message: string) => void = (_url: string, _code: number, _message: string): void => {};
  private webController: webview.WebviewController = new webview.WebviewController();
  @State pageTitle: string = '';

  aboutToAppear(): void {
    this.pageTitle = this.url;
  }

  build(): void {
    Column() {
      Row() {
        Text(this.pageTitle.length > 0 ? this.pageTitle : this.url)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(16)
          .fontWeight(FontWeight.Medium);
        Text('×')
          .fontSize(28)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick((): void => this.onClose());
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 8 })
      .backgroundColor('#F7F7F7');

      Web({ src: '', controller: this.webController })
        .layoutWeight(1)
        .javaScriptAccess(true)
        .onControllerAttached((): void => {
          try {
            this.webController.loadUrl(this.url, this.headers);
          } catch (error) {
            this.onError(this.url, -1, String(error));
          }
        })
        .onPageBegin((event: OnPageBeginEvent): void => {
          this.onPageBegin(event.url);
        })
        .onPageEnd((event: OnPageEndEvent): void => {
          this.onPageLoaded(event.url);
        })
        .onTitleReceive((event: OnTitleReceiveEvent): void => {
          if (event.title.length > 0) this.pageTitle = event.title;
          this.onTitle(event.title);
        })
        .onErrorReceive((event: OnErrorReceiveEvent): void => {
          this.onError(this.url, event.error.getErrorCode(), event.error.getErrorInfo());
        });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White);
  }
}

@Builder
function LynxCapacitorWebViewDialogBuilder(params: LynxCapacitorWebViewDialogParams): void {
  LynxCapacitorWebViewDialog({
    url: params.url,
    headers: params.headers,
    onPageBegin: params.onPageBegin,
    onClose: params.onClose,
    onPageLoaded: params.onPageLoaded,
    onTitle: params.onTitle,
    onError: params.onError,
  });
}

interface LynxCapacitorSplashDialogParams {
  backgroundColor: string;
}

/** Harmony SplashScreen 的显式内容层 overlay；冷启动系统 splash 仍由 Ability 管理。 */
@Component
struct LynxCapacitorSplashDialog {
  @Prop overlayColor: string = '#FFFFFF';

  build(): void {
    Column() {}
      .width('100%')
      .height('100%')
      .backgroundColor(this.overlayColor);
  }
}

@Builder
function LynxCapacitorSplashDialogBuilder(params: LynxCapacitorSplashDialogParams): void {
  LynxCapacitorSplashDialog({ overlayColor: params.backgroundColor });
}

/**
 * HarmonyOS 显式 Capacitor-compatible LynxModule。
 *
 * 该类由 lynx_shell_kit 的容器直接放入 modules Map，不使用 Lynx Autolink、Hvigor
 * 自动发现或生成 registry。当前通过系统 Kit 显式实现 Device/App/Preferences、网络、
 * 文件、媒体选择/CameraKit、Contacts/Calendar、LocalNotifications、ScreenReader、Motion、位置、窗口、
 * 反馈、系统浏览器和 ArkWeb InAppBrowser 能力；无等价能力按 catalog 状态返回结构化
 * UNAVAILABLE，避免假成功。
 */
export class LynxHarmonyCapabilityRuntime {
  /** Lynx 4.1 NativeModules 对这三个无副作用查询使用同步返回语义。 */
  private static readonly localNotificationIdsKey: string = '__lynx_capacitor_local_notification_ids';
  private static readonly localNotificationChannelsKey: string = '__lynx_capacitor_local_notification_channels';
  private static instances: Array<LynxHarmonyCapabilityRuntime> = [];
  private static contextInstances: Map<LynxContext, LynxHarmonyCapabilityRuntime> = new Map();
  private static launchUrl: string = '';
  private static appIsActive: boolean = true;
  private static hostContexts: Set<common.UIAbilityContext> = new Set();
  private dataPreferences: preferences.Preferences | null = null;
  private notificationInitialization: Promise<void> | null = null;
  private keepAwake: boolean = false;
  private privacyScreen: boolean = false;
  private statusBarVisible: boolean = true;
  private statusBarOverlays: boolean = false;
  private statusBarStyle: string = 'DEFAULT';
  private statusBarColor: string = '';
  private listeners: Map<string, LynxCapacitorListener> = new Map();
  private eventSequence: number = 0;
  private networkConnection: connection.NetConnection | null = null;
  private networkCallback: ((info: connection.NetCapabilityInfo) => void) | null = null;
  private motionAccelerationCallback: ((event: sensor.AccelerometerResponse) => void) | null = null;
  private motionGyroscopeCallback: ((event: sensor.GyroscopeResponse) => void) | null = null;
  private motionListening: boolean = false;
  private lastMotionTimestamp: number = 0;
  private rotationRate: LynxCapacitorRotationRate = { alpha: 0, beta: 0, gamma: 0 };
  private localNotificationIds: Map<number, LynxCapacitorLocalNotification> = new Map();
  private localNotificationChannels: Map<string, LynxCapacitorNotificationChannel> = new Map();
  private reminderStateCallback: ((states: Array<reminderAgentManager.ReminderState>) => void) | null = null;
  private browserDialogContent: ComponentContent<LynxCapacitorWebViewDialogParams> | null = null;
  private browserDialogUIContext: UIContext | null = null;
  private splashDialogContent: ComponentContent<LynxCapacitorSplashDialogParams> | null = null;
  private splashDialogUIContext: UIContext | null = null;
  private screenReaderStateCallback: ((enabled: boolean) => void) | null = null;
  private screenOrientationWindow: window.Window | null = null;
  private screenOrientationCallback: ((size: window.Size) => void) | null = null;
  private screenOrientationStarting: boolean = false;
  private screenOrientationGeneration: number = 0;
  private backButtonHandlerEnabled: boolean = true;
  private toastGeneration: number = 0;
  private toastUIContext: UIContext | null = null;
  private toastId: number | null = null;

  public readonly owner: LynxHarmonyNativeOwner = new LynxHarmonyNativeOwner();
  private pending: Map<number, () => void> = new Map();
  private nextCall: number = 0;
  private readonly context: LynxContext;
  private readonly media: LynxHarmonyMediaCapabilities;
  private readonly actionMenus: Set<LynxHarmonyMediaMenu> = new Set();
  private readonly sqlite: LynxHarmonySQLite;
  private readonly httpAdapter: LynxHarmonyHttp;
  private readonly transfer: LynxHarmonyTransfer;
  private readonly biometrics: LynxHarmonyBiometrics;
  private readonly legacy: LynxHarmonyLegacyMedia;
  private readonly share: LynxHarmonyShare;
  private readonly preferenceAdapter: LynxHarmonyPreferences;

  private constructor(context: LynxContext) {
    this.context = context;
    this.media = new LynxHarmonyMediaCapabilities(this.owner, (): LynxCapacitorHost | null => LynxCapacitorHosts.find(this.context));
    this.sqlite = new LynxHarmonySQLite(this.owner, (): common.UIAbilityContext => this.abilityContext());
    this.httpAdapter = new LynxHarmonyHttp(this.owner);
    this.transfer = new LynxHarmonyTransfer(this.owner, (): common.UIAbilityContext => this.abilityContext(), (id: string, url: string, bytes: number, total: number): void => this.emitTransferProgress('FileTransfer', 'download', url, bytes, total, id, id));
    this.biometrics = new LynxHarmonyBiometrics(this.owner, (): LynxCapacitorHost | null => LynxCapacitorHosts.find(this.context));
    this.legacy = new LynxHarmonyLegacyMedia(this.owner, (): common.UIAbilityContext => this.abilityContext(), this.media, this.transfer);
    this.preferenceAdapter = new LynxHarmonyPreferences(this.owner, (): common.UIAbilityContext => this.abilityContext());
    this.share = new LynxHarmonyShare(this.owner, (): LynxCapacitorHost => this.requireHost());
    LynxHarmonyCapabilityRuntime.instances.push(this);
    LynxHarmonyCapabilityRuntime.contextInstances.set(context, this);
  }

  private static destroyedContexts: WeakSet<LynxContext> = new WeakSet();

  public static forContext(context: LynxContext): LynxHarmonyCapabilityRuntime {
    if (LynxHarmonyCapabilityRuntime.destroyedContexts.has(context)) throw new Error('ACTIVITY_DESTROYED: LynxContext 已移除');
    const existing = LynxHarmonyCapabilityRuntime.contextInstances.get(context);
    if (existing !== undefined) return existing;
    return new LynxHarmonyCapabilityRuntime(context);
  }

  public handleLegacyMedia(method: string, optionsJSON: string, callback: (json: string) => void): void {
    this.legacy.dispatch(method, optionsJSON, callback);
  }

  public static onHostVisibilityChanged(context: LynxContext): void {
    const runtime = LynxHarmonyCapabilityRuntime.contextInstances.get(context);
    runtime?.handleHostVisibilityChanged();
  }

  private handleHostVisibilityChanged(): void {
    this.media.onHostVisibilityChanged();
    const host = LynxCapacitorHosts.find(this.context);
    if (host !== null && host.isVisible()) return;
    this.actionMenus.forEach((menu: LynxHarmonyMediaMenu): void => menu.cancel('UNAVAILABLE: 操作菜单所属页面已离开前台'));
  }

  private requireHost(): LynxCapacitorHost {
    this.owner.checkActive();
    const host = LynxCapacitorHosts.find(this.context);
    if (host === null) throw new Error('UNAVAILABLE: 当前 LynxContext 未登记 Host');
    return host;
  }

  private abilityContext(): common.UIAbilityContext { return this.requireHost().abilityContext; }
  private currentWindow(): Promise<window.Window> {
    const host = this.requireHost();
    if (!host.isVisible()) return Promise.reject(new Error('UNAVAILABLE: 当前页面不在前台'));
    return Promise.resolve(host.window);
  }

  /** 页面销毁时释放系统 observer、传感器和位置 watcher，避免残留回调持有 LynxContext。 */
  public destroy(): void {
    if (!this.owner.isActive) return;
    const host = LynxCapacitorHosts.find(this.context);
    this.owner.close();
    this.pending.forEach((cancel: () => void): void => cancel());
    this.pending.clear();
    this.media.destroy();
    this.sqlite.destroy();
    this.transfer.destroy();
    LynxHarmonyAudioCapabilities.releaseOwner(this.owner.id);
    if (host !== null) LynxCapacitorWindowLeases.release(host.window, this.owner.id);
    LynxCapacitorHosts.unbind(this.context);
    LynxHarmonyCapabilityRuntime.destroyedContexts.add(this.context);
    const instanceIndex = LynxHarmonyCapabilityRuntime.instances.indexOf(this);
    if (instanceIndex >= 0) LynxHarmonyCapabilityRuntime.instances.splice(instanceIndex, 1);
    LynxHarmonyCapabilityRuntime.contextInstances.delete(this.context);
    const browserContent = this.browserDialogContent;
    const browserUIContext = this.browserDialogUIContext;
    this.browserDialogContent = null;
    this.browserDialogUIContext = null;
    if (browserContent !== null && browserUIContext !== null) {
      try {
        browserUIContext.getPromptAction().closeCustomDialog(browserContent).catch((error: Object): void => {
          console.error('LynxHarmonyCapabilityRuntime', `InAppBrowser close during destroy failed: ${String(error)}`);
        });
      } catch (error) {
        console.error('LynxHarmonyCapabilityRuntime', `InAppBrowser close during destroy failed: ${String(error)}`);
      }
    }
    const splashContent = this.splashDialogContent;
    const splashUIContext = this.splashDialogUIContext;
    this.splashDialogContent = null;
    this.splashDialogUIContext = null;
    if (splashContent !== null && splashUIContext !== null) {
      try {
        splashUIContext.getPromptAction().closeCustomDialog(splashContent).catch((error: Object): void => {
          console.error('LynxHarmonyCapabilityRuntime', `SplashScreen close during destroy failed: ${String(error)}`);
        });
      } catch (error) {
        console.error('LynxHarmonyCapabilityRuntime', `SplashScreen close during destroy failed: ${String(error)}`);
      }
    }
    this.stopNetworkListener();
    this.stopMotionListeners();
    this.stopReminderStateListener();
    this.stopScreenReaderListener();
    this.stopScreenOrientationListener();
    this.toastGeneration += 1;
    this.closeActiveToast();
    this.listeners.clear();
  }

  /** Shell 在真正移除 LynxView 时显式释放对应 Module，避免依赖运行时的隐式销毁回调。 */
  public static destroyForContext(context: LynxContext | null): void {
    if (context === null) return;
    LynxHarmonyCapabilityRuntime.destroyedContexts.add(context);
    LynxHarmonyCapabilityRuntime.contextInstances.get(context)?.destroy();
    LynxCapacitorHosts.unbind(context);
  }

  /** Ability 在创建 LynxView 前注入真实 UIAbilityContext，供系统 Picker/Provider 使用。 */
  public static setHostContext(context: common.UIAbilityContext): void {
    LynxHarmonyCapabilityRuntime.hostContexts.add(context);
  }

  public static clearHostContext(context: common.UIAbilityContext): void {
    LynxHarmonyCapabilityRuntime.instances.slice().forEach((runtime: LynxHarmonyCapabilityRuntime): void => {
      if (LynxCapacitorHosts.find(runtime.context)?.abilityContext === context) runtime.destroy();
    });
    LynxHarmonyCapabilityRuntime.hostContexts.delete(context);
  }

  /**
   * Host push providers call these explicit entry points after receiving a token or payload.
   * The Module never discovers or initializes a vendor push provider by itself.
   */
  public static emitPushRegistration(token: string): void {
    if (token.length === 0) return;
    LynxHarmonyCapabilityRuntime.emitPushEvent('registration', JSON.stringify({ value: token }));
  }

  public static emitPushRegistrationError(message: string): void {
    LynxHarmonyCapabilityRuntime.emitPushEvent('registrationError', JSON.stringify({ error: message }));
  }

  public static emitPushNotification(data: Record<string, Object>): void {
    LynxHarmonyCapabilityRuntime.emitPushEvent('pushNotificationReceived', JSON.stringify(data));
  }

  private static emitPushEvent(eventName: string, dataJSON: string): void {
    LynxHarmonyCapabilityRuntime.instances.slice().forEach((module: LynxHarmonyCapabilityRuntime) => {
      module.emitEvent('PushNotifications', eventName, dataJSON);
    });
  }

  /** Host Ability forwards the initial deep link and subsequent Want URL events explicitly. */
  public static setLaunchUrl(url: string): void {
    LynxHarmonyCapabilityRuntime.launchUrl = url;
  }

  public static emitAppUrlOpen(url: string): void {
    const value = url.trim();
    if (value.length === 0) return;
    LynxHarmonyCapabilityRuntime.emitAppEvent('appUrlOpen', JSON.stringify({ url: value }));
  }

  public static emitAppState(isActive: boolean): void {
    LynxHarmonyCapabilityRuntime.appIsActive = isActive;
    LynxHarmonyCapabilityRuntime.instances.forEach((runtime: LynxHarmonyCapabilityRuntime): void => runtime.handleHostVisibilityChanged());
    LynxHarmonyCapabilityRuntime.emitAppEvent('appStateChange', JSON.stringify({ isActive: isActive }));
    LynxHarmonyCapabilityRuntime.emitAppEvent(isActive ? 'resume' : 'pause', '{}');
  }

  /** LynxContainer 在系统返回回调中调用；只有页面显式订阅且 handler enabled 才消费返回。 */
  public static dispatchBackButton(): boolean {
    for (let index = LynxHarmonyCapabilityRuntime.instances.length - 1; index >= 0; index -= 1) {
      const module = LynxHarmonyCapabilityRuntime.instances[index];
      if (module !== undefined && module.backButtonHandlerEnabled && module.hasPluginListeners('App', 'backButton')) {
        module.emitEvent('App', 'backButton', '{"canGoBack":false}');
        return true;
      }
    }
    return false;
  }

  /** 容器只允许当前 LynxContext 的监听消费返回，后台 Tab/Page 不能抢占。 */
  public static dispatchBackButtonForContext(context: LynxContext): boolean {
    const module = LynxHarmonyCapabilityRuntime.contextInstances.get(context);
    if (module !== undefined && module.backButtonHandlerEnabled && module.hasPluginListeners('App', 'backButton')) {
      module.emitEvent('App', 'backButton', '{"canGoBack":false}');
      return true;
    }
    return false;
  }

  private static emitAppEvent(eventName: string, dataJSON: string): void {
    LynxHarmonyCapabilityRuntime.instances.slice().forEach((module: LynxHarmonyCapabilityRuntime) => {
      module.emitEvent('App', eventName, dataJSON);
    });
  }

  public getPlatform(): string {
    return 'harmony';
  }

  public getPluginHeaders(): string {
    return LynxCapacitorCatalog.headers();
  }

  public getCapabilityStatus(): string {
    const rows = JSON.parse(LynxCapacitorCatalog.status()) as Array<Record<string, Object>>;
    const host = LynxCapacitorHosts.find(this.context);
    rows.forEach((row: Record<string, Object>): void => {
      row['ownerActive'] = this.owner.isActive;
      row['hostAvailable'] = host !== null;
      row['foreground'] = host !== null && host.isVisible();
      const methods = row['methodStatus'] as Array<Record<string, Object>>;
      methods.forEach((method: Record<string, Object>): void => {
        const implemented = method['state'] !== 'unsupported';
        method['runtimeAvailable'] = implemented && this.owner.isActive && host !== null;
        if (implemented && host === null) method['runtimeReasonCode'] = 'RUNTIME_CONTEXT_REQUIRED';
      });
    });
    return JSON.stringify(rows);
  }

  public handleCall(payload: string, callback: (resultJSON: string) => void): void {
    if (!this.owner.isActive) { callback(this.failure('-1', '', '', 'ACTIVITY_DESTROYED', '页面已销毁')); return; }
    if (lynxUTF8Bytes(payload) > LYNX_PAYLOAD_BYTES) { callback(this.failure('-1', '', '', 'PAYLOAD_TOO_LARGE', '普通调用 payload 超过 1 MiB')); return; }
    if (this.pending.size >= 64) { callback(this.failure('-1', '', '', 'BUSY', '页面待完成调用过多')); return; }
    let completed = false;
    const sequence = ++this.nextCall;
    const complete = (result: string): void => {
      if (completed) return;
      completed = true;
      this.pending.delete(sequence);
      if (!this.owner.isActive) {
        callback(this.failure(String(metadata['callbackId'] ?? '-1'), String(metadata['pluginId'] ?? ''), String(metadata['methodName'] ?? ''), 'ACTIVITY_DESTROYED', '页面关闭取消调用'));
        return;
      }
      if (lynxUTF8Bytes(result) > LYNX_RESULT_BYTES) {
        callback(this.failure(String(metadata['callbackId'] ?? '-1'), String(metadata['pluginId'] ?? ''), String(metadata['methodName'] ?? ''), 'RESULT_TOO_LARGE', 'Bridge 结果超过 2 MiB'));
      } else callback(result);
    };
    let metadata: Record<string, Object>;
    try { const parsed = JSON.parse(payload) as Object; metadata = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as Record<string, Object> : {}; } catch (_error) { metadata = {}; }
    this.pending.set(sequence, (): void => complete(this.failure(String(metadata['callbackId'] ?? '-1'), String(metadata['pluginId'] ?? ''), String(metadata['methodName'] ?? ''), 'ACTIVITY_DESTROYED', '页面关闭取消调用')));
    try {
      this.dispatchCall(payload, complete);
    } catch (error) { complete(this.failure(String(metadata['callbackId'] ?? '-1'), String(metadata['pluginId'] ?? ''), String(metadata['methodName'] ?? ''), lynxNativeErrorCode(error), String(error))); }
  }

  private dispatchCall(payload: string, callback: (resultJSON: string) => void): void {
    let root: Record<string, Object>;
    try {
      const parsed = JSON.parse(payload) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('payload must be a JSON object');
      root = parsed as Record<string, Object>;
    } catch (error) {
      callback(this.failure('-1', '', '', 'INVALID_PAYLOAD', `Invalid Capacitor call payload: ${error}`));
      return;
    }
    const pluginValue = root['pluginId'];
    const methodValue = root['methodName'];
    const pluginId = typeof pluginValue === 'string' ? pluginValue.trim() : '';
    const methodName = typeof methodValue === 'string' ? methodValue.trim() : '';
    const callbackValue = root['callbackId'];
    let callbackId: string = '-1';
    if (callbackValue !== undefined && callbackValue !== null) {
      if (typeof callbackValue !== 'string' || callbackValue.trim().length === 0) {
        callback(this.failure('-1', pluginId, methodName, 'INVALID_ARGUMENT', 'callbackId 必须是非空字符串，缺省或 null 才使用 -1'));
        return;
      }
      callbackId = callbackValue.trim();
    }
    if ((pluginValue !== undefined && pluginValue !== null && typeof pluginValue !== 'string') ||
      (methodValue !== undefined && methodValue !== null && typeof methodValue !== 'string') ||
      pluginId.length === 0 || methodName.length === 0) {
      callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'pluginId 和 methodName 必须是非空字符串'));
      return;
    }
    let options: Record<string, Object>;
    if (root['options'] === null || root['options'] === undefined) {
      options = JSON.parse('{}') as Record<string, Object>;
    } else if (typeof root['options'] !== 'object' || Array.isArray(root['options'])) {
      callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'options must be a JSON object'));
      return;
    } else {
      options = root['options'] as Record<string, Object>;
    }

    // 先做三端公共目录闸门。这样目录外的 Harmony 扩展、旧别名和通用
    // listener 都不能绕过协议直接得到假成功。
    if (!LynxCapacitorCatalog.has(pluginId, methodName)) {
      callback(this.failure(callbackId, pluginId, methodName, 'UNIMPLEMENTED', `${pluginId}.${methodName} is not declared by the public NativeModule contract`));
      return;
    }

    if (methodName === 'addListener') {
      const eventName = String(options['eventName'] ?? '');
      if (eventName.length === 0) {
        callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'eventName is required'));
        return;
      }
      const listener: LynxCapacitorListener = { pluginId: pluginId, eventName: eventName };
      this.listeners.set(callbackId, listener);
      if (pluginId === 'Network' && eventName === 'networkStatusChange') this.startNetworkListener();
      if (pluginId === 'Motion' && (eventName === 'accel' || eventName === 'orientation')) this.startMotionListeners();
      if (pluginId === 'LocalNotifications' && (eventName === 'localNotificationReceived' || eventName === 'localNotificationActionPerformed')) this.startReminderStateListener();
      if (pluginId === 'ScreenReader' && eventName === 'stateChange') this.startScreenReaderListener();
      if (pluginId === 'ScreenOrientation' && eventName === 'screenOrientationChange') this.startScreenOrientationListener();
      callback(this.success(callbackId, pluginId, methodName));
      return;
    }
    if (methodName === 'removeListener') {
      const removedId = String(options['callbackId'] ?? '');
      const removed = this.listeners.get(removedId);
      this.listeners.delete(removedId);
      if (removed?.pluginId === 'Network' && !this.hasPluginListeners('Network')) this.stopNetworkListener();
      if (removed?.pluginId === 'Motion' && !this.hasPluginListeners('Motion')) this.stopMotionListeners();
      if (removed?.pluginId === 'LocalNotifications' && !this.hasPluginListeners('LocalNotifications')) this.stopReminderStateListener();
      if (removed?.pluginId === 'ScreenReader' && !this.hasPluginListeners('ScreenReader')) this.stopScreenReaderListener();
      if (removed?.pluginId === 'ScreenOrientation' && !this.hasPluginListeners('ScreenOrientation')) this.stopScreenOrientationListener();
      callback(this.success(callbackId, pluginId, methodName));
      return;
    }
    if (methodName === 'removeAllListeners') {
      this.listeners.forEach((listener: LynxCapacitorListener, id: string) => {
        if (listener.pluginId === pluginId) this.listeners.delete(id);
      });
      if (pluginId === 'Network') this.stopNetworkListener();
      if (pluginId === 'Motion') this.stopMotionListeners();
      if (pluginId === 'LocalNotifications') this.stopReminderStateListener();
      if (pluginId === 'ScreenReader') this.stopScreenReaderListener();
      if (pluginId === 'ScreenOrientation') this.stopScreenOrientationListener();
      callback(this.success(callbackId, pluginId, methodName));
      return;
    }
    switch (pluginId) {
      case 'App':
        this.handleApp(callbackId, methodName, options, callback);
        return;
      case 'AppLauncher':
        this.handleAppLauncher(callbackId, methodName, options, callback);
        return;
      case 'Device':
        this.handleDevice(callbackId, methodName, callback);
        return;
      case 'Biometrics':
        this.handleBiometrics(callbackId, methodName, options, callback);
        return;
      case 'Preferences':
        this.handlePreferences(callbackId, methodName, options, callback);
        return;
      case 'Network':
        this.handleNetwork(callbackId, methodName, callback);
        return;
      case 'Clipboard':
        this.handleClipboard(callbackId, methodName, options, callback);
        return;
      case 'CapacitorCookies':
        this.handleCookies(callbackId, methodName, options, callback);
        return;
      case 'CapacitorHttp':
        this.handleHttp(callbackId, methodName, options, callback);
        return;
      case 'Filesystem':
        this.handleFilesystem(callbackId, methodName, options, callback);
        return;
      case 'FileTransfer':
        this.handleFileTransfer(callbackId, methodName, options, callback);
        return;
      case 'Browser':
      case 'InAppBrowser':
        this.handleBrowser(callbackId, pluginId, methodName, options, callback);
        return;
      case 'FileViewer':
        this.handleFileViewer(callbackId, methodName, options, callback);
        return;
      case 'Haptics':
        this.handleHaptics(callbackId, methodName, options, callback);
        return;
      case 'Toast':
        this.handleToast(callbackId, methodName, options, callback);
        return;
      case 'KeepAwake':
        this.handleKeepAwake(callbackId, methodName, callback);
        return;
      case 'SafeArea':
        this.handleSafeArea(callbackId, methodName, options, callback);
        return;
      case 'ActionSheet':
        this.handleActionSheet(callbackId, methodName, options, callback);
        return;
      case 'Dialog':
        this.handleDialog(callbackId, methodName, options, callback);
        return;
      case 'Share':
        this.handleShare(callbackId, methodName, options, callback);
        return;
      case 'PrivacyScreen':
        this.handlePrivacyScreen(callbackId, methodName, callback);
        return;
      case 'ScreenOrientation':
        this.handleScreenOrientation(callbackId, methodName, options, callback);
        return;
      case 'Motion':
        this.handleMotion(callbackId, methodName, callback);
        return;
      case 'StatusBar':
        this.handleStatusBar(callbackId, methodName, options, callback);
        return;
      case 'SystemBars':
        this.handleSystemBars(callbackId, methodName, options, callback);
        return;
      case 'Camera':
        this.handleCamera(callbackId, methodName, options, callback);
        return;
      case 'Audio':
        this.handleAudio(callbackId, methodName, options, callback);
        return;
      case 'CapacitorBarcodeScanner':
        this.handleBarcodeScanner(callbackId, methodName, options, callback);
        return;
      case 'Contacts':
        this.handleContacts(callbackId, methodName, options, callback);
        return;
      case 'Calendar':
        this.handleCalendar(callbackId, methodName, options, callback);
        return;
      case 'LocalNotifications':
        this.initializePreferences().then((): void => { this.owner.checkActive(); this.handleLocalNotifications(callbackId, methodName, options, callback); }).catch((error: Object): void => callback(this.failure(callbackId, pluginId, methodName, lynxNativeErrorCode(error), String(error))));
        return;
      case 'PushNotifications':
        this.handlePushNotifications(callbackId, methodName, options, callback);
        return;
      case 'BackgroundRunner':
        this.handleBackgroundRunner(callbackId, methodName, callback);
        return;
      case 'CapacitorSQLite':
        this.handleSQLite(callbackId, methodName, options, callback);
        return;
      case 'ScreenReader':
        this.handleScreenReader(callbackId, methodName, options, callback);
        return;
      case 'Keyboard':
        this.handleKeyboard(callbackId, methodName, callback);
        return;
      case 'TextZoom':
        this.handleTextZoom(callbackId, methodName, options, callback);
        return;
      case 'Geolocation':
        this.handleGeolocation(callbackId, methodName, options, callback);
        return;
      case 'SplashScreen':
        this.handleSplashScreen(callbackId, methodName, options, callback);
        return;
      default:
        callback(this.failure(callbackId, pluginId, methodName, 'UNIMPLEMENTED', `${pluginId}.${methodName} is not implemented on HarmonyOS`));
    }
  }

  private hasPluginListeners(pluginId: string, eventName: string = ''): boolean {
    let found = false;
    this.listeners.forEach((listener: LynxCapacitorListener) => {
      if (listener.pluginId === pluginId && (eventName.length === 0 || listener.eventName === eventName)) found = true;
    });
    return found;
  }

  private emitEvent(pluginId: string, eventName: string, dataJSON: string): void {
    if (!this.owner.isActive) return;
    this.listeners.forEach((listener: LynxCapacitorListener, callbackId: string) => {
      if (listener.pluginId !== pluginId || listener.eventName !== eventName) return;
      this.context.sendGlobalEvent(
        'lynx-capacitor-result',
        [this.eventEnvelope(callbackId, pluginId, 'addListener', eventName, dataJSON)],
      );
    });
  }

  /** NetworkKit 的文件传输进度统一转换为 Capacitor 风格的插件级 retained event。 */
  private emitTransferProgress(
    pluginId: string,
    type: string,
    url: string,
    bytes: number,
    contentLength: number,
    operationId: string = '',
    callbackId: string = '',
  ): void {
    if (!this.owner.isActive) return;
    const total = Number(contentLength);
    const progress: Record<string, Object> = {};
    progress['type'] = type;
    progress['url'] = url;
    progress['bytes'] = Number(bytes);
    progress['contentLength'] = total;
    progress['lengthComputable'] = total >= 0;
    if (operationId.length > 0) progress['operationId'] = operationId;
    const dataJSON = JSON.stringify(progress);
    // FileTransfer 的进度事件也必须使用统一 retained envelope，不能发送裸 data 对象。
    const eventCallbackId = callbackId.length > 0 ? callbackId : operationId;
    this.context.sendGlobalEvent(
      'lynx-capacitor-result',
      [this.eventEnvelope(eventCallbackId, pluginId, 'progress', 'progress', dataJSON, operationId)],
    );
    this.emitEvent(pluginId, 'progress', dataJSON);
  }

  /** 为 listener 和长任务生成相同字段集合的 retained event。 */
  private eventEnvelope(
    callbackId: string,
    pluginId: string,
    methodName: string,
    eventName: string,
    dataJSON: string,
    operationId: string = '',
  ): string {
    const envelope = JSON.parse(this.success(callbackId, pluginId, methodName, dataJSON, true)) as Record<string, Object>;
    envelope['eventName'] = eventName;
    envelope['save'] = true;
    if (eventName !== 'progress') envelope['listenerId'] = callbackId;
    if (operationId.length > 0) envelope['operationId'] = operationId;
    this.eventSequence += 1;
    envelope['sequence'] = this.eventSequence;
    return JSON.stringify(envelope);
  }

  private startNetworkListener(): void {
    if (this.networkConnection !== null) return;
    try {
      const monitor = connection.createNetConnection();
      const emitConnected = (bearerTypes: Array<connection.NetBearType>): void => {
        let connectionType = 'unknown';
        if (bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) connectionType = 'wifi';
        else if (bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) connectionType = 'cellular';
        else if (bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0) connectionType = 'ethernet';
        this.emitEvent('Network', 'networkStatusChange', `{"connected":true,"connectionType":${JSON.stringify(connectionType)}}`);
      };
      const onCapabilitiesChanged = (info: connection.NetCapabilityInfo): void => {
        emitConnected(info.netCap.bearerTypes);
      };
      const onAvailable = (handle: connection.NetHandle): void => {
        try {
          emitConnected(connection.getNetCapabilitiesSync(handle).bearerTypes);
        } catch (error) {
          console.error('LynxHarmonyCapabilityRuntime', `Network capability query after netAvailable failed: ${String(error)}`);
          this.emitEvent('Network', 'networkStatusChange', '{"connected":true,"connectionType":"unknown"}');
        }
      };
      const onLost = (_handle: connection.NetHandle): void => {
        this.emitEvent('Network', 'networkStatusChange', '{"connected":false,"connectionType":"none"}');
      };
      const onUnavailable = (): void => {
        this.emitEvent('Network', 'networkStatusChange', '{"connected":false,"connectionType":"none"}');
      };
      this.networkConnection = monitor;
      this.networkCallback = onCapabilitiesChanged;
      monitor.on('netAvailable', onAvailable);
      monitor.on('netCapabilitiesChange', onCapabilitiesChanged);
      monitor.on('netLost', onLost);
      monitor.on('netUnavailable', onUnavailable);
      monitor.register((error: BusinessError<void>, _data: void): void => {
        if (error) console.error('LynxHarmonyCapabilityRuntime', `Network listener registration failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Network listener setup failed: ${String(error)}`);
      this.networkConnection = null;
      this.networkCallback = null;
    }
  }

  private stopNetworkListener(): void {
    const monitor = this.networkConnection;
    if (monitor === null) return;
    try {
      monitor.unregister((error: BusinessError<void>, _data: void): void => {
        if (error) console.error('LynxHarmonyCapabilityRuntime', `Network listener removal failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Network listener removal failed: ${String(error)}`);
    }
    this.networkConnection = null;
    this.networkCallback = null;
  }

  private startMotionListeners(): void {
    if (this.motionListening) return;
    const onAcceleration = (event: sensor.AccelerometerResponse): void => {
      const interval = this.lastMotionTimestamp === 0 ? 0 : Math.max(0, event.timestamp - this.lastMotionTimestamp);
      this.lastMotionTimestamp = event.timestamp;
      this.emitEvent('Motion', 'accel', `{"acceleration":{"x":${String(event.x)},"y":${String(event.y)},"z":${String(event.z)}},"accelerationIncludingGravity":{"x":${String(event.x)},"y":${String(event.y)},"z":${String(event.z)}},"rotationRate":${JSON.stringify(this.rotationRate)},"interval":${String(interval)}}`);
    };
    const onGyroscope = (event: sensor.GyroscopeResponse): void => {
      const factor = 180 / Math.PI;
      this.rotationRate = { alpha: event.z * factor, beta: event.x * factor, gamma: event.y * factor };
      this.emitEvent('Motion', 'orientation', JSON.stringify(this.rotationRate));
    };
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, onAcceleration);
      sensor.on(sensor.SensorId.GYROSCOPE, onGyroscope);
      this.motionAccelerationCallback = onAcceleration;
      this.motionGyroscopeCallback = onGyroscope;
      this.motionListening = true;
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Motion listener setup failed: ${String(error)}`);
      this.stopMotionListeners();
    }
  }

  private stopMotionListeners(): void {
    try {
      if (this.motionAccelerationCallback !== null) sensor.off(sensor.SensorId.ACCELEROMETER, this.motionAccelerationCallback);
      if (this.motionGyroscopeCallback !== null) sensor.off(sensor.SensorId.GYROSCOPE, this.motionGyroscopeCallback);
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Motion listener removal failed: ${String(error)}`);
    }
    this.motionAccelerationCallback = null;
    this.motionGyroscopeCallback = null;
    this.motionListening = false;
    this.lastMotionTimestamp = 0;
    this.rotationRate = { alpha: 0, beta: 0, gamma: 0 };
  }

  private handleMotion(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    if (methodName === 'start') {
      try {
        this.startMotionListeners();
        callback(this.success(callbackId, 'Motion', methodName, '{"started":true}'));
      } catch (error) {
        callback(this.failure(callbackId, 'Motion', methodName, 'UNAVAILABLE', `Motion start failed: ${String(error)}`));
      }
      return;
    }
    if (methodName === 'stop') {
      try {
        this.stopMotionListeners();
        callback(this.success(callbackId, 'Motion', methodName, '{"stopped":true}'));
      } catch (error) {
        callback(this.failure(callbackId, 'Motion', methodName, 'UNAVAILABLE', `Motion stop failed: ${String(error)}`));
      }
      return;
    }
    callback(this.failure(callbackId, 'Motion', methodName, 'UNIMPLEMENTED', `Motion.${methodName} is not implemented`));
  }

  /** Harmony ReminderAgent 的 retained state 回调；只在 JS 注册通知 listener 后订阅。 */
  private startReminderStateListener(): void {
    if (this.reminderStateCallback !== null) return;
    const onReminderState = (states: Array<reminderAgentManager.ReminderState>): void => {
      states.forEach((state: reminderAgentManager.ReminderState) => {
        if (!this.localNotificationIds.has(state.reminderId)) return;
        const actionId = state.buttonType === reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_SNOOZE ? 'snooze' : 'close';
        const payload: LynxCapacitorNotificationActionEvent = {
          actionId: actionId,
          notification: { id: String(state.reminderId) } as LynxCapacitorNotificationReference,
        };
        this.emitEvent('LocalNotifications', 'localNotificationActionPerformed', JSON.stringify(payload));
      });
    };
    this.reminderStateCallback = onReminderState;
    try {
      reminderAgentManager.subscribeReminderState(onReminderState).catch((error: Object) => {
        console.error('LynxHarmonyCapabilityRuntime', `Reminder state listener setup failed: ${String(error)}`);
        this.reminderStateCallback = null;
      });
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Reminder state listener setup failed: ${String(error)}`);
      this.reminderStateCallback = null;
    }
  }

  private stopReminderStateListener(): void {
    const callback = this.reminderStateCallback;
    if (callback === null) return;
    this.reminderStateCallback = null;
    try {
      reminderAgentManager.unsubscribeReminderState(callback).catch((error: Object) => {
        console.error('LynxHarmonyCapabilityRuntime', `Reminder state listener removal failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Reminder state listener removal failed: ${String(error)}`);
    }
  }

  private handleActionSheet(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName !== 'showActions') {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'UNIMPLEMENTED', 'ActionSheet.' + methodName + ' is not implemented'));
      return;
    }
    const rawOptions = options['options'];
    const values: Array<Object> = Array.isArray(rawOptions) ? rawOptions : [];
    const choices: Array<LynxHarmonyMediaChoice> = [];
    values.forEach((value: Object, index: number): void => {
      const item = value as Record<string, Object>;
      choices.push({
        label: String(item['title'] ?? ''),
        value: String(index),
        color: item['destructive'] === true ? '#d00000' : '#000000',
        disabled: item['disabled'] === true,
      });
    });
    if (choices.length === 0) {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'INVALID_ARGUMENT', 'options must contain at least one action'));
      return;
    }
    try {
      choices.push({ label: String(options['cancelButtonTitle'] ?? '取消'), value: '-1' });
      const menu = new LynxHarmonyMediaMenu(this.owner, this.requireHost());
      this.actionMenus.add(menu);
      menu.select(String(options['title'] ?? ''), choices, String(options['message'] ?? '')).then((index: string): void => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'ActionSheet', methodName, JSON.stringify({ index: Number(index), cancelled: index === '-1' })));
      }).catch((error: Object): void => {
        if (lynxNativeErrorCode(error) === 'CANCELLED') {
          callback(this.success(callbackId, 'ActionSheet', methodName, '{"index":-1,"cancelled":true}'));
        } else callback(this.failure(callbackId, 'ActionSheet', methodName, lynxNativeErrorCode(error), String(error)));
      }).finally((): void => { this.actionMenus.delete(menu); });
    } catch (error) {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'UNAVAILABLE', 'ActionSheet operation failed: ' + String(error)));
    }
  }

  private handleDialog(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.handleDialogPrompt(callbackId, options, callback, methodName);
  }

  /** 使用宿主 UIContext 创建真正的文本输入 Dialog；所有退出路径只完成一次 callback。 */
  private handleDialogPrompt(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void, methodName: string = 'prompt'): void {
    let completed = false;
    const complete = (value: string, cancelled: boolean): void => {
      if (completed) return;
      completed = true;
      const data: Record<string, Object> = methodName === 'prompt' ? { value: value, cancelled: cancelled } : methodName === 'confirm' ? { value: !cancelled } : {};
      callback(this.success(callbackId, 'Dialog', methodName, JSON.stringify(data)));
    };
    const fail = (error: Object): void => {
      if (completed) return;
      completed = true;
      callback(this.failure(callbackId, 'Dialog', methodName, 'UNAVAILABLE', 'Dialog.prompt failed: ' + String(error)));
    };
    try {
      this.currentWindow().then((lastWindow: window.Window): void => {
        this.owner.checkActive();
        const uiContext: UIContext = this.requireHost().uiContext;
        const params: LynxCapacitorPromptDialogParams = {
          title: String(options['title'] ?? ''),
          message: String(options['message'] ?? ''),
          placeholder: String(options['placeholder'] ?? ''),
          initialValue: String(options['value'] ?? options['input'] ?? ''),
          showInput: methodName === 'prompt',
          showCancel: methodName !== 'alert',
          cancelText: String(options['cancelButtonTitle'] ?? 'Cancel'),
          confirmText: String(options['buttonTitle'] ?? options['okButtonTitle'] ?? 'OK'),
          onConfirm: (value: string): void => { complete(value, false); uiContext.getPromptAction().closeCustomDialog(contentNode).catch((error: Object): void => console.error('LynxCapacitor', 'Dialog close failed: ' + String(error))); },
          onCancel: (): void => { complete('', true); uiContext.getPromptAction().closeCustomDialog(contentNode).catch((error: Object): void => console.error('LynxCapacitor', 'Dialog close failed: ' + String(error))); },
        };
        const contentNode = new ComponentContent(uiContext, wrapBuilder(LynxCapacitorPromptDialogBuilder), params);
        const dialogOptions: promptAction.BaseDialogOptions = {
          alignment: DialogAlignment.Center,
          autoCancel: true,
          maskColor: 'rgba(0, 0, 0, 0.6)',
          onDidDisappear: (): void => { this.owner.disown(key); complete('', true); },
        };
        const key = 'dialog:' + util.generateRandomUUID(false);
        this.owner.own(key, (): void => { uiContext.getPromptAction().closeCustomDialog(contentNode).catch((error: Object): void => console.error('LynxCapacitor', 'Dialog close failed: ' + String(error))); });
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).then(async (): Promise<void> => {
          if (!this.owner.isActive) await uiContext.getPromptAction().closeCustomDialog(contentNode);
        }).catch((error: Object): void => { this.owner.disown(key); fail(error); });
      }).catch((error: Object): void => fail(error));
    } catch (error) {
      fail(error);
    }
  }

  private handleShare(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'Share', methodName, this.share.dispatch(methodName, options), callback);
  }

  private handlePrivacyScreen(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    if (methodName === 'isEnabled') {
      callback(this.success(callbackId, 'PrivacyScreen', methodName, '{"value":' + String(this.privacyScreen) + '}'));
      return;
    }
    if (methodName !== 'enable' && methodName !== 'disable') {
      callback(this.failure(callbackId, 'PrivacyScreen', methodName, 'UNIMPLEMENTED', 'PrivacyScreen.' + methodName + ' is not implemented'));
      return;
    }
    const value = methodName === 'enable';
    try {
      this.currentWindow().then((lastWindow: window.Window) => { this.owner.checkActive(); return LynxCapacitorWindowLeases.set(lastWindow, this.owner.id, true, value); }).then(() => {
        this.owner.checkActive();
        this.privacyScreen = value;
        callback(this.success(callbackId, 'PrivacyScreen', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'PrivacyScreen', methodName, 'UNAVAILABLE', 'PrivacyScreen operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'PrivacyScreen', methodName, 'UNAVAILABLE', 'PrivacyScreen operation failed: ' + String(error)));
    }
  }

  private handleScreenOrientation(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'lock') {
      const requested = String(options['orientation'] ?? '').toLowerCase().replace(/_/g, '-');
      const supported = ['any', 'natural', 'portrait', 'portrait-primary', 'portrait-secondary', 'landscape', 'landscape-primary', 'landscape-secondary'];
      if (supported.indexOf(requested) < 0) {
        callback(this.failure(callbackId, 'ScreenOrientation', methodName, 'INVALID_ARGUMENT', 'orientation must be any, natural, portrait, portrait-primary, portrait-secondary, landscape, landscape-primary, or landscape-secondary'));
        return;
      }
    }
    try {
      this.currentWindow().then((lastWindow: window.Window) => {
        this.owner.checkActive();
        if (methodName === 'orientation') {
          const orientation = Number(display.getDefaultDisplaySync().orientation);
          const value = orientation === 1 ? 'landscape-primary' : orientation === 2 ? 'portrait-secondary' : orientation === 3 ? 'landscape-secondary' : 'portrait-primary';
          callback(this.success(callbackId, 'ScreenOrientation', methodName, '{"type":' + JSON.stringify(value) + '}'));
          return;
        }
        if (methodName === 'unlock') return lastWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
        if (methodName === 'lock') {
          const requested = String(options['orientation'] ?? '').toLowerCase().replace(/_/g, '-');
          let orientation: window.Orientation;
          switch (requested) {
            case 'any':
              orientation = window.Orientation.AUTO_ROTATION;
              break;
            case 'natural':
              orientation = window.Orientation.UNSPECIFIED;
              break;
            case 'portrait':
            case 'portrait-primary':
              orientation = window.Orientation.PORTRAIT;
              break;
            case 'portrait-secondary':
              orientation = window.Orientation.PORTRAIT_INVERTED;
              break;
            case 'landscape':
            case 'landscape-primary':
              orientation = window.Orientation.LANDSCAPE;
              break;
            case 'landscape-secondary':
              orientation = window.Orientation.LANDSCAPE_INVERTED;
              break;
            default:
              throw new Error('orientation must be any, natural, portrait, portrait-primary, portrait-secondary, landscape, landscape-primary, or landscape-secondary');
          }
          return lastWindow.setPreferredOrientation(orientation);
        }
        throw new Error('ScreenOrientation.' + methodName + ' is not implemented');
      }).then(() => {
        this.owner.checkActive();
        if (methodName !== 'orientation') callback(this.success(callbackId, 'ScreenOrientation', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'ScreenOrientation', methodName, 'UNAVAILABLE', 'ScreenOrientation operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'ScreenOrientation', methodName, 'UNAVAILABLE', 'ScreenOrientation operation failed: ' + String(error)));
    }
  }

  private handleStatusBar(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      this.currentWindow().then((lastWindow: window.Window) => {
        this.owner.checkActive();
        if (methodName === 'show' || methodName === 'hide') return lastWindow.setSpecificSystemBarEnabled('status', methodName === 'show');
        if (methodName === 'setStyle') {
          const style = String(options['style'] ?? '').toUpperCase();
          return lastWindow.setWindowSystemBarProperties({ isStatusBarLightIcon: style === 'LIGHT' });
        }
        if (methodName === 'setBackgroundColor') {
          return lastWindow.setWindowSystemBarProperties({ statusBarColor: String(options['color'] ?? '#000000') });
        }
        if (methodName === 'setOverlaysWebView') return lastWindow.setWindowLayoutFullScreen(Boolean(options['overlay'] ?? false));
        if (methodName === 'getInfo') {
          callback(this.success(callbackId, 'StatusBar', methodName, this.statusBarInfoJSON()));
          return;
        }
        throw new Error('StatusBar.' + methodName + ' is not implemented');
      }).then(() => {
        this.owner.checkActive();
        if (methodName === 'show' || methodName === 'hide') {
          this.statusBarVisible = methodName === 'show';
          this.emitEvent('StatusBar', 'statusBarVisibilityChanged', this.statusBarInfoJSON());
        } else if (methodName === 'setOverlaysWebView') {
          this.statusBarOverlays = Boolean(options['overlay'] ?? false);
          this.emitEvent('StatusBar', 'statusBarOverlayChanged', this.statusBarInfoJSON());
        } else if (methodName === 'setStyle') {
          this.statusBarStyle = String(options['style'] ?? 'DEFAULT').toUpperCase();
        } else if (methodName === 'setBackgroundColor') {
          this.statusBarColor = String(options['color'] ?? '#000000');
        }
        if (methodName !== 'getInfo') callback(this.success(callbackId, 'StatusBar', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'StatusBar', methodName, 'UNAVAILABLE', 'StatusBar operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'StatusBar', methodName, 'UNAVAILABLE', 'StatusBar operation failed: ' + String(error)));
    }
  }

  private statusBarInfoJSON(): string {
    return JSON.stringify({
      visible: this.statusBarVisible,
      style: this.statusBarStyle,
      color: this.statusBarColor,
      overlays: this.statusBarOverlays,
      height: 0,
    });
  }

  private handleSystemBars(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      this.currentWindow().then((lastWindow: window.Window) => {
        this.owner.checkActive();
        if (methodName === 'setStyle') {
          const style = String(options['style'] ?? '').toUpperCase();
          return lastWindow.setWindowSystemBarProperties({
            isStatusBarLightIcon: style === 'LIGHT',
            isNavigationBarLightIcon: style === 'LIGHT',
          });
        }
        if (methodName === 'setVisible') {
          const visible = Boolean(options['visible'] ?? true);
          return visible ? lastWindow.setWindowSystemBarEnable(['status', 'navigation']) : Promise.all([
            lastWindow.setSpecificSystemBarEnabled('status', false),
            lastWindow.setSpecificSystemBarEnabled('navigation', false),
          ]).then(() => undefined);
        }
        throw new Error('SystemBars.' + methodName + ' is not implemented');
      }).then(() => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'SystemBars', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'SystemBars', methodName, 'UNAVAILABLE', 'SystemBars operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'SystemBars', methodName, 'UNAVAILABLE', 'SystemBars operation failed: ' + String(error)));
    }
  }

  /** 使用 Harmony ScanKit 承载 CapacitorBarcodeScanner.scanBarcode；ScanKit 自己管理扫码 UI。 */
  private handleBarcodeScanner(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName !== 'scanBarcode') {
      callback(this.failure(callbackId, 'CapacitorBarcodeScanner', methodName, 'UNIMPLEMENTED', 'CapacitorBarcodeScanner.' + methodName + ' is not implemented'));
      return;
    }
    const rawHint = options['hint'];
    const hint = rawHint === undefined ? 17 : Number(rawHint);
    if (!Number.isInteger(hint) || hint < 0 || hint > 17) {
      callback(this.failure(callbackId, 'CapacitorBarcodeScanner', methodName, 'INVALID_ARGUMENT', 'hint must be between 0 and 17'));
      return;
    }
    const scanOptions: scanBarcode.ScanOptions = {
      scanTypes: [this.barcodeScanType(hint)],
      enableMultiMode: false,
      enableAlbum: false
    };
    try {
      const context = this.abilityContext() as common.UIAbilityContext;
      scanBarcode.startScanForResult(context, scanOptions).then((result: scanBarcode.ScanResult): void => {
        this.owner.checkActive();
        const format = this.barcodeResultHint(result.scanType, hint);
        callback(this.success(callbackId, 'CapacitorBarcodeScanner', methodName, JSON.stringify({ ScanResult: result.originalValue, format: format })));
      }).catch((error: BusinessError): void => {
        if (Number(error.code) === scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
          callback(this.failure(callbackId, 'CapacitorBarcodeScanner', methodName, 'CANCELLED', 'Barcode scan was cancelled'));
          return;
        }
        callback(this.failure(callbackId, 'CapacitorBarcodeScanner', methodName, 'UNAVAILABLE', 'Barcode scan failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'CapacitorBarcodeScanner', methodName, 'UNAVAILABLE', 'Unable to start barcode scanner: ' + String(error)));
    }
  }

  private barcodeScanType(hint: number): scanCore.ScanType {
    switch (hint) {
      case 0: return scanCore.ScanType.QR_CODE;
      case 1: return scanCore.ScanType.AZTEC_CODE;
      case 2: return scanCore.ScanType.CODABAR_CODE;
      case 3: return scanCore.ScanType.CODE39_CODE;
      case 4: return scanCore.ScanType.CODE93_CODE;
      case 5: return scanCore.ScanType.CODE128_CODE;
      case 6: return scanCore.ScanType.DATAMATRIX_CODE;
      case 8: return scanCore.ScanType.ITF14_CODE;
      case 9: return scanCore.ScanType.EAN13_CODE;
      case 10: return scanCore.ScanType.EAN8_CODE;
      case 11: return scanCore.ScanType.PDF417_CODE;
      case 14: return scanCore.ScanType.UPC_A_CODE;
      case 15: return scanCore.ScanType.UPC_E_CODE;
      default: return scanCore.ScanType.ALL;
    }
  }

  private barcodeResultHint(scanType: scanCore.ScanType, requestedHint: number): number {
    switch (scanType) {
      case scanCore.ScanType.QR_CODE: return 0;
      case scanCore.ScanType.AZTEC_CODE: return 1;
      case scanCore.ScanType.CODABAR_CODE: return 2;
      case scanCore.ScanType.CODE39_CODE: return 3;
      case scanCore.ScanType.CODE93_CODE: return 4;
      case scanCore.ScanType.CODE128_CODE: return 5;
      case scanCore.ScanType.DATAMATRIX_CODE: return 6;
      case scanCore.ScanType.ITF14_CODE: return 8;
      case scanCore.ScanType.EAN13_CODE: return 9;
      case scanCore.ScanType.EAN8_CODE: return 10;
      case scanCore.ScanType.PDF417_CODE: return 11;
      case scanCore.ScanType.UPC_A_CODE: return 14;
      case scanCore.ScanType.UPC_E_CODE: return 15;
      default: return requestedHint === 17 ? 17 : requestedHint;
    }
  }

  private handleCamera(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'checkPermissions') {
      callback(this.success(callbackId, 'Camera', methodName, this.cameraPermissionJSON()));
      return;
    }
    if (methodName === 'requestPermissions') {
      const required: Array<Permissions> = ['ohos.permission.CAMERA'];
      const requested = options['permissions'];
      if (Array.isArray(requested) && requested.includes('microphone')) required.push('ohos.permission.MICROPHONE');
      LynxHarmonyPermissions.ensure(this.owner, this.requireHost(), required).then((): void => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'Camera', methodName, this.cameraPermissionJSON()));
      }).catch((error: Object): void => callback(this.failure(callbackId, 'Camera', methodName, lynxNativeErrorCode(error, 'PERMISSION_DENIED'), String(error))));
      return;
    }
    this.media.dispatch(callbackId, 'Camera', methodName, options, callback);
  }

  private cameraPermissionJSON(): string {
    const manager = abilityAccessCtrl.createAtManager();
    const state = (permission: Permissions): string => manager.getSelfPermissionStatus(permission) === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : 'prompt';
    return JSON.stringify({ camera: state('ohos.permission.CAMERA'), photos: 'granted', microphone: state('ohos.permission.MICROPHONE') });
  }

  private ensureHarmonyPermissions(
    callbackId: string,
    pluginId: string,
    methodName: string,
    permissions: Array<Permissions>,
    callback: (resultJSON: string) => void,
    continuation: () => void
  ): void {
    LynxHarmonyPermissions.ensure(this.owner, this.requireHost(), permissions).then((): void => {
      this.owner.checkActive();
      continuation();
    }).catch((error: Object): void => callback(this.failure(callbackId, pluginId, methodName, lynxNativeErrorCode(error, 'PERMISSION_DENIED'), String(error))));
  }

  private contactsRequiredPermissions(methodName: string): Array<Permissions> {
    switch (methodName) {
      case 'find':
        return ['ohos.permission.READ_CONTACTS'];
      case 'save':
      case 'remove':
        return ['ohos.permission.READ_CONTACTS', 'ohos.permission.WRITE_CONTACTS'];
      default:
        return [];
    }
  }

  private contactPermissionState(permission: Permissions): string {
    try {
      const status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus(permission);
      return status === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : status === abilityAccessCtrl.PermissionStatus.DENIED ? 'denied' : 'prompt';
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Contacts permission status failed: ${String(error)}`);
      return 'prompt';
    }
  }

  private contactsPermissionJSON(): string {
    return JSON.stringify({
      readContacts: this.contactPermissionState('ohos.permission.READ_CONTACTS'),
      writeContacts: this.contactPermissionState('ohos.permission.WRITE_CONTACTS'),
    });
  }

  private contactsRequestedPermissions(options: Record<string, Object>): Array<Permissions> {
    const rawPermissions = options['permissions'];
    const names: string[] = [];
    if (Array.isArray(rawPermissions)) {
      (rawPermissions as Array<Object>).forEach((value: Object): void => { names.push(String(value).trim().toLowerCase()); });
    } else if (rawPermissions !== undefined && rawPermissions !== null) {
      names.push(String(rawPermissions).trim().toLowerCase());
    } else if (options['permission'] !== undefined && options['permission'] !== null) {
      names.push(String(options['permission']).trim().toLowerCase());
    } else {
      names.push('read', 'write');
    }
    const unique: string[] = [];
    names.forEach((name: string): void => {
      if (unique.indexOf(name) < 0) unique.push(name);
    });
    const permissions: Array<Permissions> = [];
    unique.forEach((name: string): void => {
      if (name === 'read' || name === 'contacts' || name === 'readcontacts') permissions.push('ohos.permission.READ_CONTACTS');
      else if (name === 'write' || name === 'contacts' || name === 'writecontacts') permissions.push('ohos.permission.WRITE_CONTACTS');
      else throw new Error('permissions contains an unsupported Contacts permission');
    });
    if (permissions.length === 0) throw new Error('permissions must not be empty');
    return permissions.filter((permission: Permissions, index: number): boolean => permissions.indexOf(permission) === index);
  }

  /** 使用 Harmony ContactsKit 承载 Capacitor Contacts 的保存、查询、删除和选择。 */
  private handleContacts(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    const context = this.abilityContext() as common.UIAbilityContext;
    try {
      if (methodName === 'checkPermissions') {
        callback(this.success(callbackId, 'Contacts', methodName, this.contactsPermissionJSON()));
        return;
      }
      if (methodName === 'requestPermissions') {
        let requested: Array<Permissions>;
        try {
          requested = this.contactsRequestedPermissions(options);
        } catch (error) {
          callback(this.failure(callbackId, 'Contacts', methodName, 'INVALID_ARGUMENT', String(error)));
          return;
        }
        LynxHarmonyPermissions.ensure(this.owner, this.requireHost(), requested).then(() => {
        this.owner.checkActive();
          callback(this.success(callbackId, 'Contacts', methodName, this.contactsPermissionJSON()));
        }).catch((error: Object) => callback(this.failure(callbackId, 'Contacts', methodName, 'PERMISSION_DENIED', 'Contacts permission request failed: ' + String(error))));
        return;
      }
      if (!permissionsAlreadyGranted) {
        const requiredPermissions = this.contactsRequiredPermissions(methodName);
        if (requiredPermissions.length > 0) {
          this.ensureHarmonyPermissions(callbackId, 'Contacts', methodName, requiredPermissions, callback, (): void => {
            this.handleContacts(callbackId, methodName, options, callback, true);
          });
          return;
        }
      }
      switch (methodName) {
        case 'save': {
          const value = this.toNativeContact(options);
          contact.addContact(context, value).then((id: number) => {
        this.owner.checkActive();
            callback(this.success(callbackId, 'Contacts', methodName, this.contactJSON(value, id)));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        }
        case 'find': {
          const filter = String(options['filter'] ?? '');
          contact.queryContacts(context).then((values: Array<contact.Contact>) => {
        this.owner.checkActive();
            const filtered = filter.length === 0 ? values : values.filter((value: contact.Contact) => {
              return String(value.id ?? '') === filter || this.contactDisplayName(value).indexOf(filter) >= 0;
            });
            callback(this.success(callbackId, 'Contacts', methodName, '{"contacts":[' + filtered.map((value: contact.Contact) => this.contactJSON(value)).join(',') + ']}'));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        }
        case 'pickContact':
          contact.selectContacts({ isMultiSelect: false }).then((values: Array<contact.Contact>) => {
        this.owner.checkActive();
            if (values.length === 0) {
              callback(this.failure(callbackId, 'Contacts', methodName, 'CANCELLED', 'Contact picker was cancelled'));
              return;
            }
            callback(this.success(callbackId, 'Contacts', methodName, this.contactJSON(values[0])));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        case 'remove': {
          const rawId = String(options['id'] ?? '');
          if (rawId.length === 0) {
            callback(this.failure(callbackId, 'Contacts', methodName, 'INVALID_ARGUMENT', 'id is required'));
            return;
          }
          const keyPromise: Promise<string> = /^\d+$/.test(rawId) ? contact.queryKey(context, Number(rawId)) : Promise.resolve(rawId);
          keyPromise.then((key: string) => { this.owner.checkActive(); return contact.deleteContact(context, key); }).then(() => {
        this.owner.checkActive();
            callback(this.success(callbackId, 'Contacts', methodName));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        }
        default:
          callback(this.failure(callbackId, 'Contacts', methodName, 'UNIMPLEMENTED', 'Contacts.' + methodName + ' is not implemented'));
      }
    } catch (error) {
      callback(this.contactsFailure(callbackId, methodName, error));
    }
  }

  private toNativeContact(options: Record<string, Object>): contact.Contact {
    const raw = (options['contact'] ?? {}) as Record<string, Object>;
    const rawName = (raw['name'] ?? {}) as Record<string, Object>;
    const givenName = String(rawName['givenName'] ?? '');
    const familyName = String(rawName['familyName'] ?? '');
    const fullName = String(rawName['fullName'] ?? [givenName, familyName].filter((value: string) => value.length > 0).join(' '));
    const value = { name: { fullName: fullName, givenName: givenName, familyName: familyName } as contact.Name } as contact.Contact;
    const rawPhones = raw['phoneNumbers'];
    if (Array.isArray(rawPhones)) {
      const phones: Array<contact.PhoneNumber> = [];
      (rawPhones as Array<Object>).forEach((item: Object) => {
        const phone = item as Record<string, Object>;
        phones.push({ phoneNumber: String(phone['number'] ?? phone['phoneNumber'] ?? ''), labelId: contact.PhoneNumber.NUM_MOBILE } as contact.PhoneNumber);
      });
      value.phoneNumbers = phones;
    }
    const rawEmails = raw['emails'];
    if (Array.isArray(rawEmails)) {
      const emails: Array<contact.Email> = [];
      (rawEmails as Array<Object>).forEach((item: Object) => {
        const email = item as Record<string, Object>;
        emails.push({ email: String(email['address'] ?? email['email'] ?? ''), labelId: contact.Email.EMAIL_OTHER } as contact.Email);
      });
      value.emails = emails;
    }
    const note = String(raw['note'] ?? '');
    if (note.length > 0) value.note = { noteContent: note } as contact.Note;
    return value;
  }

  private contactDisplayName(value: contact.Contact): string {
    return value.name?.fullName ?? '';
  }

  private contactJSON(value: contact.Contact, id?: number): string {
    const nativeId = id === undefined ? value.id : id;
    return JSON.stringify({
      id: nativeId === undefined ? null : String(nativeId),
      displayName: this.contactDisplayName(value),
      name: value.name ?? null,
      phoneNumbers: (value.phoneNumbers ?? []).map((phone: contact.PhoneNumber): Record<string, Object> => ({ number: phone.phoneNumber ?? '', label: phone.labelName ?? String(phone.labelId ?? '') })),
      emails: (value.emails ?? []).map((email: contact.Email): Record<string, Object> => ({ address: email.email ?? '', label: email.labelName ?? String(email.labelId ?? '') })),
    });
  }

  private contactsFailure(callbackId: string, methodName: string, error: Object): string {
    const message = 'Contacts.' + methodName + ' failed: ' + String(error);
    const code = lynxNativeErrorCode(error, String(error).indexOf('201') >= 0 ? 'PERMISSION_DENIED' : 'UNAVAILABLE');
    return this.failure(callbackId, 'Contacts', methodName, code, message);
  }

  /** 使用 Harmony CalendarKit 对齐 Capacitor Calendar 的账户、事件和权限操作。 */
  private handleCalendar(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    const context = this.abilityContext() as common.UIAbilityContext;
    try {
      if (methodName === 'checkPermissions') {
        callback(this.success(callbackId, 'Calendar', methodName, this.calendarPermissionJSON()));
        return;
      }
      if (methodName === 'requestPermissions') {
        LynxHarmonyPermissions.ensure(this.owner, this.requireHost(), ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']).then(() => {
        this.owner.checkActive();
          callback(this.success(callbackId, 'Calendar', methodName, this.calendarPermissionJSON()));
        }).catch((error: Object) => callback(this.failure(callbackId, 'Calendar', methodName, 'PERMISSION_DENIED', 'Calendar permission request failed: ' + String(error))));
        return;
      }
      if (!permissionsAlreadyGranted) {
        const requiredPermissions = this.calendarRequiredPermissions(methodName);
        if (requiredPermissions.length > 0) {
          this.ensureHarmonyPermissions(callbackId, 'Calendar', methodName, requiredPermissions, callback, (): void => {
            this.handleCalendar(callbackId, methodName, options, callback, true);
          });
          return;
        }
      }
      const calendar = calendarManager.getCalendarManager(context);
      switch (methodName) {
        case 'listCalendars':
          calendar.getAllCalendars().then((values: Array<calendarManager.Calendar>) => {
        this.owner.checkActive();
            callback(this.success(callbackId, 'Calendar', methodName, '{"calendars":[' + values.map((value: calendarManager.Calendar) => this.calendarJSON(value)).join(',') + ']}'));
          }).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        case 'createCalendar': {
          const name = String(options['name'] ?? '');
          if (name.length === 0) {
            callback(this.failure(callbackId, 'Calendar', methodName, 'INVALID_ARGUMENT', 'name is required'));
            return;
          }
          const account: calendarManager.CalendarAccount = { name: name, displayName: name, type: calendarManager.CalendarType.LOCAL };
          calendar.createCalendar(account).then((value: calendarManager.Calendar) => callback(this.success(callbackId, 'Calendar', methodName, this.calendarJSON(value)))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'deleteCalendar': {
          const requestedId = Number(options['id'] ?? -1);
          const requestedName = String(options['name'] ?? '');
          calendar.getAllCalendars().then((values: Array<calendarManager.Calendar>) => {
        this.owner.checkActive();
            const target = values.find((value: calendarManager.Calendar) => value.id === requestedId || this.calendarName(value) === requestedName);
            if (target === undefined) throw new Error('Calendar was not found');
            return calendar.deleteCalendar(target);
          }).then(() => callback(this.success(callbackId, 'Calendar', methodName))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'createEvent': {
          const event = this.toNativeCalendarEvent(options);
          const requestedId = Number(options['calendarId'] ?? -1);
          const requestedName = String(options['calendarName'] ?? '');
          calendar.getAllCalendars().then((values: Array<calendarManager.Calendar>) => {
            this.owner.checkActive();
            const explicit = options['calendarId'] !== undefined || requestedName.length > 0;
            const target = explicit ? values.find((value: calendarManager.Calendar) => value.id === requestedId || (requestedName.length > 0 && this.calendarName(value) === requestedName)) : values[0];
            if (explicit && target === undefined) throw new Error('NOT_FOUND: 指定日历不存在');
            if (target === undefined) throw new Error('No calendar is available');
            return target.addEvent(event);
          }).then((id: number) => callback(this.success(callbackId, 'Calendar', methodName, '{"id":' + JSON.stringify(String(id)) + '}'))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'findEvents': {
          this.matchingCalendarEvents(calendar, options).then((matches: Array<LynxCapacitorCalendarEventMatch>) => {
        this.owner.checkActive();
            callback(this.success(callbackId, 'Calendar', methodName, '{"events":[' + matches.map((match: LynxCapacitorCalendarEventMatch) => this.calendarEventJSON(match.event, match.calendar)).join(',') + ']}'));
          }).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'deleteEvent': {
          if (options['fromDate'] !== undefined) {
            callback(this.failure(callbackId, 'Calendar', methodName, 'UNAVAILABLE', 'Recurring event truncation requires an event-series coordinator'));
            return;
          }
          const rawId = String(options['id'] ?? '');
          const operation = calendar.getAllCalendars().then((values: Array<calendarManager.Calendar>) => {
        this.owner.checkActive();
            if (rawId.length > 0) {
              const id = Number(rawId);
              return Promise.all(values.map((value: calendarManager.Calendar) => value.getEvents().then((events: Array<calendarManager.Event>) => ({ calendar: value, events: events.filter((event: calendarManager.Event) => event.id === id) } as LynxCapacitorCalendarEventGroup)))).then((groups: Array<LynxCapacitorCalendarEventGroup>) => {
        this.owner.checkActive();
                const match = groups.find((group: LynxCapacitorCalendarEventGroup) => group.events.length > 0);
                if (match === undefined || match.events[0] === undefined) throw new Error('Calendar event was not found');
                return match.calendar.deleteEvent(id);
              }).then((): void => {});
            }
            return this.matchingCalendarEvents(calendar, options).then((matches: Array<LynxCapacitorCalendarEventMatch>) => {
        this.owner.checkActive();
              if (matches.length === 0) throw new Error('No calendar event matches the filter');
              return Promise.all(matches.map((match: LynxCapacitorCalendarEventMatch) => match.event.id === undefined ? Promise.reject(new Error('Calendar event id is missing')) : match.calendar.deleteEvent(match.event.id))).then((): void => {});
            });
          });
          operation.then(() => callback(this.success(callbackId, 'Calendar', methodName))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'modifyEvent': {
          const rawFilter = options['filter'];
          const rawNewEvent = options['newEvent'];
          const filter = rawFilter === undefined ? options : rawFilter as Record<string, Object>;
          const newEvent = rawNewEvent === undefined ? options : rawNewEvent as Record<string, Object>;
          this.matchingCalendarEvents(calendar, filter).then((matches: Array<LynxCapacitorCalendarEventMatch>) => {
        this.owner.checkActive();
            const target = matches[0];
            if (target === undefined) throw new Error('Calendar event was not found');
            this.applyCalendarEventPatch(target.event, newEvent);
            return target.calendar.updateEvent(target.event);
          }).then(() => callback(this.success(callbackId, 'Calendar', methodName))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'createEventInteractively':
        case 'openCalendar':
          callback(this.failure(callbackId, 'Calendar', methodName, 'UNAVAILABLE', 'Calendar interactive UI requires a host-owned Ability surface'));
          return;
        default:
          callback(this.failure(callbackId, 'Calendar', methodName, 'UNIMPLEMENTED', 'Calendar.' + methodName + ' is not implemented'));
      }
    } catch (error) {
      callback(this.calendarFailure(callbackId, methodName, error));
    }
  }

  private calendarPermissionJSON(): string {
    const manager = abilityAccessCtrl.createAtManager();
    const read = manager.getSelfPermissionStatus('ohos.permission.READ_CALENDAR') === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : 'denied';
    const write = manager.getSelfPermissionStatus('ohos.permission.WRITE_CALENDAR') === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : 'denied';
    return '{"read":' + JSON.stringify(read) + ',"write":' + JSON.stringify(write) + '}';
  }

  private calendarRequiredPermissions(methodName: string): Array<Permissions> {
    switch (methodName) {
      case 'listCalendars':
      case 'findEvents':
        return ['ohos.permission.READ_CALENDAR'];
      case 'createEvent':
      case 'createEventInteractively':
      case 'createCalendar':
        return ['ohos.permission.WRITE_CALENDAR'];
      case 'modifyEvent':
      case 'deleteEvent':
      case 'deleteCalendar':
        return ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
      default:
        return [];
    }
  }

  private calendarName(value: calendarManager.Calendar): string {
    const account = value.getAccount();
    return account.displayName ?? account.name;
  }

  private calendarJSON(value: calendarManager.Calendar): string {
    return JSON.stringify({ id: String(value.id), name: this.calendarName(value) });
  }

  private toNativeCalendarEvent(options: Record<string, Object>): calendarManager.Event {
    const startTime = Number(options['startDate'] ?? options['startTime'] ?? Date.now());
    const endTime = Number(options['endDate'] ?? options['endTime'] ?? startTime + 3600000);
    const event = { type: calendarManager.EventType.NORMAL, title: String(options['title'] ?? ''), description: String(options['notes'] ?? options['description'] ?? ''), startTime: startTime, endTime: endTime, isAllDay: Boolean(options['isAllDay'] ?? false) } as calendarManager.Event;
    const location = String(options['location'] ?? '');
    if (location.length > 0) event.location = { location: location } as calendarManager.Location;
    const recurrence = this.toNativeCalendarRecurrence(options['recurrence']);
    if (recurrence !== undefined) event.recurrenceRule = recurrence;
    const reminders = this.calendarReminderTimes(options);
    if (reminders.length > 0) event.reminderTime = reminders;
    return event;
  }

  private toNativeCalendarRecurrence(raw: Object | undefined): calendarManager.RecurrenceRule | undefined {
    if (raw === undefined || raw === null) return undefined;
    const value = raw as Record<string, Object>;
    const frequencyValue = String(value['frequency'] ?? '').toLowerCase();
    let recurrenceFrequency: calendarManager.RecurrenceFrequency;
    switch (frequencyValue) {
      case 'daily': recurrenceFrequency = calendarManager.RecurrenceFrequency.DAILY; break;
      case 'weekly': recurrenceFrequency = calendarManager.RecurrenceFrequency.WEEKLY; break;
      case 'monthly': recurrenceFrequency = calendarManager.RecurrenceFrequency.MONTHLY; break;
      case 'yearly': recurrenceFrequency = calendarManager.RecurrenceFrequency.YEARLY; break;
      default: throw new Error('recurrence.frequency must be daily, weekly, monthly, or yearly');
    }
    const rule = { recurrenceFrequency: recurrenceFrequency } as calendarManager.RecurrenceRule;
    if (value['interval'] !== undefined) rule.interval = Math.max(1, Number(value['interval']));
    if (value['count'] !== undefined) rule.count = Math.max(1, Number(value['count']));
    if (value['endDate'] !== undefined) rule.expire = Number(value['endDate']);
    return rule;
  }

  private calendarReminderTimes(options: Record<string, Object>): Array<number> {
    const values: Array<number> = [];
    ['firstReminderMinutes', 'secondReminderMinutes'].forEach((key: string) => {
      if (options[key] !== undefined) {
        const minutes = Number(options[key]);
        if (Number.isFinite(minutes) && minutes >= 0) values.push(minutes);
      }
    });
    return values;
  }

  private applyCalendarEventPatch(event: calendarManager.Event, patch: Record<string, Object>): void {
    if (patch['title'] !== undefined) event.title = String(patch['title']);
    if (patch['notes'] !== undefined || patch['description'] !== undefined) event.description = String(patch['notes'] ?? patch['description'] ?? '');
    if (patch['location'] !== undefined) event.location = { location: String(patch['location']) } as calendarManager.Location;
    if (patch['startDate'] !== undefined || patch['startTime'] !== undefined) event.startTime = Number(patch['startDate'] ?? patch['startTime']);
    if (patch['endDate'] !== undefined || patch['endTime'] !== undefined) event.endTime = Number(patch['endDate'] ?? patch['endTime']);
    if (patch['isAllDay'] !== undefined) event.isAllDay = Boolean(patch['isAllDay']);
    if (patch['recurrence'] !== undefined) event.recurrenceRule = this.toNativeCalendarRecurrence(patch['recurrence']);
    if (patch['firstReminderMinutes'] !== undefined || patch['secondReminderMinutes'] !== undefined) event.reminderTime = this.calendarReminderTimes(patch);
  }

  private calendarEventJSON(event: calendarManager.Event, calendar: calendarManager.Calendar): string {
    const location = event.location?.location ?? '';
    return JSON.stringify({
      id: event.id === undefined ? null : String(event.id),
      title: event.title ?? '',
      location: location,
      notes: event.description ?? '',
      startDate: event.startTime,
      endDate: event.endTime,
      isAllDay: event.isAllDay ?? false,
      calendarId: String(calendar.id),
      calendarName: this.calendarName(calendar),
      attendees: event.attendee ?? [],
    });
  }

  private matchingCalendarEvents(calendar: calendarManager.CalendarManager, options: Record<string, Object>): Promise<Array<LynxCapacitorCalendarEventMatch>> {
    const title = String(options['title'] ?? '').toLowerCase();
    const location = String(options['location'] ?? '').toLowerCase();
    const notes = String(options['notes'] ?? '').toLowerCase();
    const calendarName = String(options['calendarName'] ?? '');
    const start = Number(options['startDate'] ?? options['startTime'] ?? Date.now() - 182 * 24 * 3600000);
    const end = Number(options['endDate'] ?? options['endTime'] ?? Date.now() + 2 * 365 * 24 * 3600000);
    return calendar.getAllCalendars().then((values: Array<calendarManager.Calendar>) => Promise.all(values.map((value: calendarManager.Calendar) => {
        this.owner.checkActive();
      if (calendarName.length > 0 && this.calendarName(value) !== calendarName) return Promise.resolve([] as Array<LynxCapacitorCalendarEventMatch>);
      return value.getEvents().then((events: Array<calendarManager.Event>) => events.filter((event: calendarManager.Event) => {
        this.owner.checkActive();
        const eventTitle = String(event.title ?? '').toLowerCase();
        const eventLocation = String(event.location?.location ?? '').toLowerCase();
        const eventNotes = String(event.description ?? '').toLowerCase();
        return (title.length === 0 || eventTitle.indexOf(title) >= 0)
          && (location.length === 0 || eventLocation.indexOf(location) >= 0)
          && (notes.length === 0 || eventNotes.indexOf(notes) >= 0)
          && event.endTime >= start
          && event.startTime <= end;
      }).map((event: calendarManager.Event) => ({ calendar: value, event: event } as LynxCapacitorCalendarEventMatch)));
    }))).then((groups: Array<Array<LynxCapacitorCalendarEventMatch>>) => {
        this.owner.checkActive();
      const result: Array<LynxCapacitorCalendarEventMatch> = [];
      groups.forEach((group: Array<LynxCapacitorCalendarEventMatch>) => group.forEach((match: LynxCapacitorCalendarEventMatch) => result.push(match)));
      return result;
    });
  }

  private calendarFailure(callbackId: string, methodName: string, error: Object): string {
    const message = 'Calendar.' + methodName + ' failed: ' + String(error);
    const code = lynxNativeErrorCode(error, String(error).indexOf('201') >= 0 ? 'PERMISSION_DENIED' : 'UNAVAILABLE');
    return this.failure(callbackId, 'Calendar', methodName, code, message);
  }

  /** 使用 BackgroundTasksKit reminderAgentManager 支持可排程的本地通知基础闭环。 */
  private handleLocalNotifications(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (this.handleNotificationHistory(callbackId, 'LocalNotifications', methodName, options, callback)) return;
    if (methodName === 'checkPermissions' || methodName === 'areEnabled') {
      try {
        notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        this.owner.checkActive();
          const data = methodName === 'areEnabled' ? '{"value":' + String(enabled) + '}' : '{"display":' + JSON.stringify(enabled ? 'granted' : 'denied') + '}';
          callback(this.success(callbackId, 'LocalNotifications', methodName, data));
        }).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      } catch (error) {
        callback(this.notificationsFailure(callbackId, methodName, error));
      }
      return;
    }
    if (methodName === 'requestPermissions') {
      try {
        notificationManager.requestEnableNotification(this.abilityContext() as common.UIAbilityContext).then(() => {
        this.owner.checkActive();
          notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        this.owner.checkActive();
            callback(this.success(callbackId, 'LocalNotifications', methodName, '{"display":' + JSON.stringify(enabled ? 'granted' : 'denied') + '}'));
          }).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
        }).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      } catch (error) {
        callback(this.notificationsFailure(callbackId, methodName, error));
      }
      return;
    }
    if (methodName === 'schedule') {
      const values: Array<Object> = Array.isArray(options['notifications']) ? options['notifications'] as Array<Object> : [];
      if (values.length === 0) {
        callback(this.failure(callbackId, 'LocalNotifications', methodName, 'INVALID_ARGUMENT', 'notifications must not be empty'));
        return;
      }
    Promise.all(values.map((raw: Object) => {
        const value = raw as Record<string, Object>;
        const id = Number(value['id'] ?? Math.floor(Date.now() % 2147483647));
        const schedule = (value['schedule'] ?? {}) as Record<string, Object>;
        const request: reminderAgentManager.ReminderRequestTimer = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
          triggerTimeInSeconds: this.notificationDelaySeconds(schedule),
          title: String(value['title'] ?? ''),
          content: String(value['body'] ?? value['extra'] ?? ''),
          notificationId: id,
        };
        const channelId = String(value['channelId'] ?? '').trim();
        const channel = channelId.length > 0 ? this.localNotificationChannels.get(channelId) : undefined;
        if (channel !== undefined) request.slotType = channel.slotType;
        const rawActions = value['actions'];
        if (Array.isArray(rawActions)) {
          const buttons: Array<reminderAgentManager.ActionButton | undefined> = [];
          (rawActions as Array<Object>).slice(0, 3).forEach((rawAction: Object, index: number) => {
            const action = rawAction as Record<string, Object>;
            const type = index === 0
              ? reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
              : reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_SNOOZE;
            buttons.push({ title: String(action['title'] ?? action['id'] ?? ''), type: type });
          });
          request.actionButton = buttons as [reminderAgentManager.ActionButton?, reminderAgentManager.ActionButton?, reminderAgentManager.ActionButton?];
        }
        return reminderAgentManager.publishReminder(request).then(async (reminderId: number) => {
        this.owner.checkActive();
          this.localNotificationIds.set(reminderId, { id: reminderId, title: request.title ?? '', body: request.content ?? '' });
          await this.persistLocalNotificationIds();
          return reminderId;
        });
      })).then((ids: Array<number>) => callback(this.success(callbackId, 'LocalNotifications', methodName, '{"notifications":[' + ids.map((id: number) => '{"id":' + JSON.stringify(String(id)) + '}').join(',') + ']}'))).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      return;
    }
    if (methodName === 'getPending') {
      try {
        reminderAgentManager.getAllValidReminders().then((values: Array<reminderAgentManager.ReminderInfo>) => {
        this.owner.checkActive();
          const ownedReminders = values.filter((value: reminderAgentManager.ReminderInfo): boolean => this.localNotificationIds.has(value.reminderId));
          const notifications: Array<LynxCapacitorPendingNotification> = ownedReminders.map((value: reminderAgentManager.ReminderInfo) => ({
            id: value.reminderId,
            title: value.reminderReq.title ?? '',
            body: value.reminderReq.content ?? '',
          } as LynxCapacitorPendingNotification));
          callback(this.success(callbackId, 'LocalNotifications', methodName, '{"notifications":' + JSON.stringify(notifications) + '}'));
        }).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      } catch (error) {
        callback(this.notificationsFailure(callbackId, methodName, error));
      }
      return;
    }
    if (methodName === 'cancel') {
      const rawNotifications = options['notifications'];
      const values: Array<Object> = Array.isArray(rawNotifications) ? rawNotifications as Array<Object> : [options];
      Promise.all(values.map((raw: Object) => {
        const id = Number((raw as Record<string, Object>)['id'] ?? -1);
        if (id < 0) return Promise.reject(new Error('notification id is required'));
        if (!this.localNotificationIds.has(id)) return Promise.resolve();
        return reminderAgentManager.cancelReminder(id).then(async () => {
        this.owner.checkActive();
          this.localNotificationIds.delete(id);
          await this.persistLocalNotificationIds();
        });
      })).then(() => callback(this.success(callbackId, 'LocalNotifications', methodName))).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      return;
    }
    if (methodName === 'createChannel') {
      const rawChannel = options['channel'];
      const channel = rawChannel !== null && rawChannel !== undefined && typeof rawChannel === 'object' && !Array.isArray(rawChannel)
        ? rawChannel as Record<string, Object>
        : options;
      const id = String(channel['id'] ?? '').trim();
      if (id.length === 0) {
        callback(this.failure(callbackId, 'LocalNotifications', methodName, 'INVALID_ARGUMENT', 'channel.id is required'));
        return;
      }
      const name = String(channel['name'] ?? id);
      const description = String(channel['description'] ?? '');
      const importance = String(channel['importance'] ?? 'default').toLowerCase();
      let slotType: notificationManager.SlotType;
      try {
        slotType = this.notificationSlotType(channel['importance']);
      } catch (error) {
        callback(this.failure(callbackId, 'LocalNotifications', methodName, 'INVALID_ARGUMENT', String(error)));
        return;
      }
      // Harmony ReminderAgent 用 notification slot 承载 Android channel 的重要性/提醒级别。
      const slot: LynxCapacitorNotificationSlot = {
        notificationType: slotType,
        desc: description.length > 0 ? description : name,
        vibrationEnabled: Boolean(channel['sound'] ?? true),
        soundEnabled: Boolean(channel['sound'] ?? true),
      };
      try {
        reminderAgentManager.addNotificationSlot(slot).then(async () => {
        this.owner.checkActive();
          const record: LynxCapacitorNotificationChannel = {
            id: id,
            name: name,
            description: description,
            importance: importance,
            slotType: slotType,
          };
          this.localNotificationChannels.set(id, record);
          await this.persistLocalNotificationChannels();
          callback(this.success(callbackId, 'LocalNotifications', methodName, JSON.stringify(record)));
        }).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      } catch (error) {
        callback(this.notificationsFailure(callbackId, methodName, error));
      }
      return;
    }
    if (methodName === 'listChannels') {
      const channels: string[] = [];
      this.localNotificationChannels.forEach((channel: LynxCapacitorNotificationChannel): void => { channels.push(JSON.stringify(channel)); });
      callback(this.success(callbackId, 'LocalNotifications', methodName, `{"channels":[${channels.join(',')}]}`));
      return;
    }
    callback(this.failure(callbackId, 'LocalNotifications', methodName, 'UNAVAILABLE', 'LocalNotifications.' + methodName + ' requires an additional notification adapter'));
  }

  private notificationSlotType(rawImportance: Object | undefined): notificationManager.SlotType {
    const numeric = Number(rawImportance);
    if (Number.isFinite(numeric)) {
      if (numeric >= 4) return notificationManager.SlotType.SOCIAL_COMMUNICATION;
      if (numeric >= 3) return notificationManager.SlotType.SERVICE_INFORMATION;
      if (numeric >= 1) return notificationManager.SlotType.CONTENT_INFORMATION;
      return notificationManager.SlotType.OTHER_TYPES;
    }
    switch (String(rawImportance ?? 'default').toLowerCase()) {
      case 'max':
      case 'high': return notificationManager.SlotType.SOCIAL_COMMUNICATION;
      case 'default': return notificationManager.SlotType.SERVICE_INFORMATION;
      case 'low': return notificationManager.SlotType.CONTENT_INFORMATION;
      case 'min': return notificationManager.SlotType.OTHER_TYPES;
      default: throw new Error('channel.importance only supports max, high, default, low, or min');
    }
  }

  private notificationDelaySeconds(schedule: Record<string, Object>): number {
    if (schedule['in'] !== null && schedule['in'] !== undefined) {
      const delay = Number(schedule['in']);
      if (!Number.isFinite(delay) || delay < 0) throw new Error('schedule.in must be a finite non-negative number');
      return Math.max(1, Math.ceil(delay));
    }
    if (schedule['at'] !== null && schedule['at'] !== undefined) {
      const rawAt = schedule['at'];
      const numericAt = Number(rawAt);
      const isNumeric = typeof rawAt === 'number' || (typeof rawAt === 'string' && rawAt.trim().length > 0 && Number.isFinite(numericAt));
      const target = isNumeric ? numericAt : new Date(String(rawAt)).getTime();
      if (!Number.isFinite(target)) throw new Error('schedule.at must be epoch milliseconds or a valid ISO date');
      return Math.max(1, Math.ceil((target - Date.now()) / 1000));
    }
    return 1;
  }

  private notificationsFailure(callbackId: string, methodName: string, error: Object): string {
    const message = 'LocalNotifications.' + methodName + ' failed: ' + String(error);
    const normalized = message.toLowerCase();
    const code = normalized.indexOf('1700001') >= 0 || normalized.indexOf('permission') >= 0 || normalized.indexOf('not enabled') >= 0
      ? 'PERMISSION_DENIED'
      : normalized.indexOf('401') >= 0 || normalized.indexOf('invalid') >= 0 ? 'INVALID_ARGUMENT' : 'UNAVAILABLE';
    return this.failure(callbackId, 'LocalNotifications', methodName, code, message);
  }

  private handlePushNotifications(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (this.handleNotificationHistory(callbackId, 'PushNotifications', methodName, options, callback)) return;
    if (methodName === 'checkPermissions') {
      try {
        notificationManager.isNotificationEnabled().then((enabled: boolean) => callback(this.success(callbackId, 'PushNotifications', methodName, '{"receive":' + JSON.stringify(enabled ? 'granted' : 'denied') + '}'))).catch((error: Object) => callback(this.failure(callbackId, 'PushNotifications', methodName, 'UNAVAILABLE', 'Push permission query failed: ' + String(error))));
      } catch (error) {
        callback(this.failure(callbackId, 'PushNotifications', methodName, 'UNAVAILABLE', 'Push permission query failed: ' + String(error)));
      }
      return;
    }
    if (methodName === 'requestPermissions') {
      try {
        notificationManager.requestEnableNotification(this.abilityContext() as common.UIAbilityContext).then(() => {
        this.owner.checkActive();
          notificationManager.isNotificationEnabled().then((enabled: boolean) => callback(this.success(callbackId, 'PushNotifications', methodName, '{"receive":' + JSON.stringify(enabled ? 'granted' : 'denied') + '}'))).catch((error: Object) => callback(this.failure(callbackId, 'PushNotifications', methodName, 'UNAVAILABLE', 'Push permission query failed: ' + String(error))));
        }).catch((error: Object) => callback(this.failure(callbackId, 'PushNotifications', methodName, 'PERMISSION_DENIED', 'Push permission request failed: ' + String(error))));
      } catch (error) {
        callback(this.failure(callbackId, 'PushNotifications', methodName, 'PERMISSION_DENIED', 'Push permission request failed: ' + String(error)));
      }
      return;
    }
    callback(this.failure(callbackId, 'PushNotifications', methodName, 'UNSUPPORTED', 'PushNotifications.register requires a vendor push provider; the Module does not initialize a third-party SDK'));
  }

  /** BackgroundRunner 与 Android 一样只提供权限状态；没有后台 JS runner 时拒绝 dispatch。 */
  private handleBackgroundRunner(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    if (methodName === 'dispatchEvent') {
      callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'UNSUPPORTED', 'HarmonyOS host does not provide a background JavaScript runner'));
      return;
    }
    if (methodName === 'checkPermissions') {
      this.backgroundRunnerPermissionStatus(callbackId, methodName, callback);
      return;
    }
    if (methodName === 'requestPermissions') {
      try {
        const manager = abilityAccessCtrl.createAtManager();
        const locationGranted = manager.getSelfPermissionStatus('ohos.permission.APPROXIMATELY_LOCATION') === abilityAccessCtrl.PermissionStatus.GRANTED;
        const requestLocation = locationGranted
          ? Promise.resolve()
          : LynxHarmonyPermissions.ensure(this.owner, this.requireHost(), ['ohos.permission.APPROXIMATELY_LOCATION']);
        requestLocation.then(() => { this.owner.checkActive(); return notificationManager.requestEnableNotification(this.abilityContext()); }).then(() => {
        this.owner.checkActive();
          this.backgroundRunnerPermissionStatus(callbackId, methodName, callback);
        }).catch((error: Object) => callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'PERMISSION_DENIED', `BackgroundRunner permission request failed: ${String(error)}`)));
      } catch (error) {
        callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'PERMISSION_DENIED', `BackgroundRunner permission request failed: ${String(error)}`));
      }
      return;
    }
    callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'UNIMPLEMENTED', `BackgroundRunner.${methodName} is not implemented`));
  }

  private backgroundRunnerPermissionStatus(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    let location = 'prompt';
    try {
      const status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus('ohos.permission.APPROXIMATELY_LOCATION');
      location = status === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : status === abilityAccessCtrl.PermissionStatus.DENIED ? 'denied' : 'prompt';
    } catch (error) {
      location = 'prompt';
    }
    try {
      notificationManager.isNotificationEnabled().then((enabled: boolean) => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'BackgroundRunner', methodName, JSON.stringify({ geolocation: location, notifications: enabled ? 'granted' : 'denied' })));
      }).catch((error: Object) => callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'UNAVAILABLE', `BackgroundRunner notification status failed: ${String(error)}`)));
    } catch (error) {
      callback(this.failure(callbackId, 'BackgroundRunner', methodName, 'UNAVAILABLE', `BackgroundRunner notification status failed: ${String(error)}`));
    }
  }

  /** NotificationKit 提供应用级 active history；Push 仍只保留 provider 注册在宿主侧。 */
  private handleNotificationHistory(callbackId: string, pluginId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): boolean {
    if (methodName === 'getDeliveredNotifications') {
      try {
        notificationManager.getActiveNotifications().then((values: Array<notificationManager.NotificationRequest>) => {
        this.owner.checkActive();
          const ownedValues = values.filter((value: notificationManager.NotificationRequest): boolean => {
            const id = Number(value.id ?? -1);
            const isLocal = this.localNotificationIds.has(id);
            return pluginId === 'LocalNotifications' ? isLocal : pluginId === 'PushNotifications' ? !isLocal : true;
          });
          const notifications: Array<LynxCapacitorDeliveredNotification> = ownedValues.map((value: notificationManager.NotificationRequest) => {
            const normal = value.content.normal;
            const data = value.extraInfo === undefined ? JSON.parse('{}') as Object : value.extraInfo as Object;
            const item: LynxCapacitorDeliveredNotification = {
              id: Number(value.id ?? 0),
              title: normal?.title ?? '',
              body: normal?.text ?? '',
              data: data,
            };
            if (value.label !== undefined && value.label.length > 0) item.tag = value.label;
            if (value.groupName !== undefined && value.groupName.length > 0) item.group = value.groupName;
            if (value.deliveryTime !== undefined) item.deliveryTime = value.deliveryTime;
            return item;
          });
          callback(this.success(callbackId, pluginId, methodName, JSON.stringify({ notifications: notifications })));
        }).catch((error: Object) => callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error))));
      } catch (error) {
        callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error)));
      }
      return true;
    }
    if (methodName === 'removeDeliveredNotifications') {
      const rawNotifications = options['notifications'];
      if (!Array.isArray(rawNotifications)) {
        callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'notifications must be an array'));
        return true;
      }
      Promise.all((rawNotifications as Array<Object>).map((raw: Object) => {
        const value = raw as Record<string, Object>;
        const id = Number(value['id'] ?? NaN);
        if (!Number.isInteger(id) || id < 0) return Promise.reject(new Error('notification id must be a non-negative integer'));
        const rawTag = value['tag'] ?? value['label'];
        const tag = rawTag === null || rawTag === undefined ? '' : String(rawTag);
        const isLocal = this.localNotificationIds.has(id);
        if ((pluginId === 'LocalNotifications' && !isLocal) || (pluginId === 'PushNotifications' && isLocal)) return Promise.resolve();
        const operation = tag.length > 0 ? notificationManager.cancel(id, tag) : notificationManager.cancel(id);
        return operation.then(async (): Promise<void> => {
        this.owner.checkActive();
          if (pluginId === 'LocalNotifications') {
            this.localNotificationIds.delete(id);
            await this.persistLocalNotificationIds();
          }
        });
      })).then(() => callback(this.success(callbackId, pluginId, methodName))).catch((error: Object) => callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error))));
      return true;
    }
    if (methodName === 'removeAllDeliveredNotifications') {
      try {
        notificationManager.getActiveNotifications().then((values: Array<notificationManager.NotificationRequest>) => {
        this.owner.checkActive();
          const ownedValues = values.filter((value: notificationManager.NotificationRequest): boolean => {
            const isLocal = this.localNotificationIds.has(Number(value.id ?? -1));
            return pluginId === 'LocalNotifications' ? isLocal : pluginId === 'PushNotifications' ? !isLocal : true;
          });
          return Promise.all(ownedValues.map((value: notificationManager.NotificationRequest) => {
            const id = Number(value.id ?? -1);
            const label = value.label === undefined ? '' : String(value.label);
            return label.length > 0 ? notificationManager.cancel(id, label) : notificationManager.cancel(id);
          })).then(async (): Promise<void> => {
        this.owner.checkActive();
            if (pluginId === 'LocalNotifications') {
              ownedValues.forEach((value: notificationManager.NotificationRequest): void => {
                this.localNotificationIds.delete(Number(value.id ?? -1));
              });
              await this.persistLocalNotificationIds();
            }
            callback(this.success(callbackId, pluginId, methodName));
          });
        }).catch((error: Object) => callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error))));
      } catch (error) {
        callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error)));
      }
      return true;
    }
    return false;
  }

  /** 使用 ArkData relationalStore 对齐 Community SQLite 的非加密 SQL 基础能力。 */
  private handleSQLite(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'CapacitorSQLite', methodName, this.sqlite.dispatch(methodName, options), callback);
  }

  private handleScreenReader(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      if (methodName === 'isEnabled') {
        callback(this.success(callbackId, 'ScreenReader', methodName, '{"value":' + String(accessibility.isScreenReaderOpenSync()) + '}'));
        return;
      }
      if (methodName === 'speak') {
        const text = String(options['value'] ?? options['text'] ?? '');
        if (text.length === 0) {
          callback(this.failure(callbackId, 'ScreenReader', methodName, 'INVALID_ARGUMENT', 'value is required'));
          return;
        }
        const eventPayload: LynxCapacitorAccessibilityEvent = { type: 'announceForAccessibility', textAnnouncedForAccessibility: text };
        const event = new accessibility.EventInfo(eventPayload);
        accessibility.sendAccessibilityEvent(event).then(() => callback(this.success(callbackId, 'ScreenReader', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'ScreenReader', methodName, 'UNAVAILABLE', 'ScreenReader announcement failed: ' + String(error))));
        return;
      }
      callback(this.failure(callbackId, 'ScreenReader', methodName, 'UNIMPLEMENTED', 'ScreenReader.' + methodName + ' is not implemented'));
    } catch (error) {
      callback(this.failure(callbackId, 'ScreenReader', methodName, 'UNAVAILABLE', 'ScreenReader operation failed: ' + String(error)));
    }
  }

  /** AccessibilityKit 的 ScreenReader 状态 retained listener；只在页面注册后订阅。 */
  private startScreenReaderListener(): void {
    if (this.screenReaderStateCallback !== null) return;
    const onStateChange = (enabled: boolean): void => {
      this.emitEvent('ScreenReader', 'stateChange', JSON.stringify({ value: enabled }));
    };
    try {
      accessibility.on('screenReaderStateChange', onStateChange);
      this.screenReaderStateCallback = onStateChange;
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `ScreenReader listener setup failed: ${String(error)}`);
    }
  }

  private stopScreenReaderListener(): void {
    const onStateChange = this.screenReaderStateCallback;
    if (onStateChange === null) return;
    this.screenReaderStateCallback = null;
    try {
      accessibility.off('screenReaderStateChange', onStateChange);
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `ScreenReader listener removal failed: ${String(error)}`);
    }
  }

  /** 使用 Window.windowSizeChange 承载 ScreenOrientation.screenOrientationChange。 */
  private startScreenOrientationListener(): void {
    if (this.screenOrientationCallback !== null || this.screenOrientationStarting) return;
    this.screenOrientationStarting = true;
    const generation = this.screenOrientationGeneration + 1;
    this.screenOrientationGeneration = generation;
    try {
      this.currentWindow().then((lastWindow: window.Window): void => {
        this.owner.checkActive();
        this.screenOrientationStarting = false;
        if (generation !== this.screenOrientationGeneration || !this.hasPluginListeners('ScreenOrientation')) return;
        const onSizeChange = (size: window.Size): void => {
          const type = Number(size.width) >= Number(size.height) ? 'landscape' : 'portrait';
          this.emitEvent('ScreenOrientation', 'screenOrientationChange', JSON.stringify({ type: type }));
        };
        lastWindow.on('windowSizeChange', onSizeChange);
        this.screenOrientationWindow = lastWindow;
        this.screenOrientationCallback = onSizeChange;
      }).catch((error: Object): void => {
        this.screenOrientationStarting = false;
        console.error('LynxHarmonyCapabilityRuntime', `ScreenOrientation listener setup failed: ${String(error)}`);
      });
    } catch (error) {
      this.screenOrientationStarting = false;
      console.error('LynxHarmonyCapabilityRuntime', `ScreenOrientation listener setup failed: ${String(error)}`);
    }
  }

  private stopScreenOrientationListener(): void {
    this.screenOrientationGeneration += 1;
    this.screenOrientationStarting = false;
    const target = this.screenOrientationWindow;
    const callback = this.screenOrientationCallback;
    this.screenOrientationWindow = null;
    this.screenOrientationCallback = null;
    if (target === null || callback === null) return;
    try {
      target.off('windowSizeChange', callback);
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `ScreenOrientation listener removal failed: ${String(error)}`);
    }
  }

  /** 使用 IMEKit 控制当前获得焦点的 Lynx 输入框；resize/style 仍由宿主容器负责。 */
  private handleKeyboard(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    try {
      const controller = inputMethod.getInputMethodController();
      if (methodName === 'getResizeMode') {
        callback(this.success(callbackId, 'Keyboard', methodName, JSON.stringify({ mode: this.requireHost().keyboardResizeMode ?? 'native' })));
        return;
      }
      if (methodName === 'show' || methodName === 'hide') {
        const operation = methodName === 'show' ? controller.showTextInput() : controller.hideTextInput();
        operation.then(() => callback(this.success(callbackId, 'Keyboard', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'Keyboard', methodName, 'UNAVAILABLE', 'Keyboard operation failed: ' + String(error))));
        return;
      }
      if (methodName === 'setStyle') {
        callback(this.failure(callbackId, 'Keyboard', methodName, 'UNSUPPORTED', 'Keyboard.setStyle is not implemented by the Android NativeModule baseline'));
        return;
      }
      callback(this.failure(callbackId, 'Keyboard', methodName, 'UNAVAILABLE', 'Keyboard resize/style is owned by the Lynx input and host window'));
    } catch (error) {
      callback(this.failure(callbackId, 'Keyboard', methodName, 'UNAVAILABLE', 'Keyboard operation failed: ' + String(error)));
    }
  }

  /** 使用 Harmony 应用字体缩放 API；这是宿主级能力，不伪装成单独 WebView zoom。 */
  private handleTextZoom(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      if (methodName === 'get' || methodName === 'getPreferred') {
        callback(this.success(callbackId, 'TextZoom', methodName, '{"value":' + String(uiAppearance.getFontScale()) + '}'));
        return;
      }
      if (methodName === 'set') {
        const requested = Number(options['value'] ?? 1.0);
        if (!Number.isFinite(requested)) {
          callback(this.failure(callbackId, 'TextZoom', methodName, 'INVALID_ARGUMENT', 'value must be a finite number'));
          return;
        }
        const value = Math.max(0.5, Math.min(3.0, requested));
        this.abilityContext().getApplicationContext().setFontSizeScale(value);
        callback(this.success(callbackId, 'TextZoom', methodName, '{"value":' + String(value) + '}'));
        return;
      }
      callback(this.failure(callbackId, 'TextZoom', methodName, 'UNIMPLEMENTED', 'TextZoom.' + methodName + ' is not implemented'));
    } catch (error) {
      callback(this.failure(callbackId, 'TextZoom', methodName, 'UNAVAILABLE', 'TextZoom operation failed: ' + String(error)));
    }
  }

  private handleGeolocation(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    const highAccuracy = options['enableHighAccuracy'] === true;
    const approximate: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
    const precise: Permissions = 'ohos.permission.LOCATION';
    const manager = abilityAccessCtrl.createAtManager();
    const coarse = manager.getSelfPermissionStatus(approximate) === abilityAccessCtrl.PermissionStatus.GRANTED;
    const fine = manager.getSelfPermissionStatus(precise) === abilityAccessCtrl.PermissionStatus.GRANTED;
    const permissionJSON = JSON.stringify({ location: fine ? 'granted' : 'prompt', coarseLocation: coarse ? 'granted' : 'prompt' });
    if (methodName === 'checkPermissions') { callback(this.success(callbackId, 'Geolocation', methodName, permissionJSON)); return; }
    if (methodName === 'requestPermissions') {
      this.ensureHarmonyPermissions(callbackId, 'Geolocation', methodName, [approximate, precise], callback, (): void => this.handleGeolocation(callbackId, 'checkPermissions', options, callback));
      return;
    }
    if (methodName !== 'getCurrentPosition') { callback(this.failure(callbackId, 'Geolocation', methodName, 'UNIMPLEMENTED', '未知定位方法')); return; }
    if (options['enableHighAccuracy'] !== undefined && typeof options['enableHighAccuracy'] !== 'boolean') { callback(this.failure(callbackId, 'Geolocation', methodName, 'INVALID_ARGUMENT', 'enableHighAccuracy 必须为 boolean')); return; }
    const timeout = Number(options['timeout'] ?? 10000);
    if (!Number.isSafeInteger(timeout) || timeout <= 0) { callback(this.failure(callbackId, 'Geolocation', methodName, 'INVALID_ARGUMENT', 'timeout 必须为正整数毫秒')); return; }
    if (!coarse || (highAccuracy && !fine)) {
      if (permissionsAlreadyGranted) { callback(this.failure(callbackId, 'Geolocation', methodName, 'PERMISSION_DENIED', '定位权限未授予')); return; }
      this.ensureHarmonyPermissions(callbackId, 'Geolocation', methodName, highAccuracy ? [approximate, precise] : [approximate], callback, (): void => this.handleGeolocation(callbackId, methodName, options, callback, true));
      return;
    }
    const request: geoLocationManager.CurrentLocationRequest = { timeoutMs: timeout, priority: highAccuracy ? geoLocationManager.LocationRequestPriority.ACCURACY : geoLocationManager.LocationRequestPriority.FIRST_FIX };
    geoLocationManager.getCurrentLocation(request).then((location: geoLocationManager.Location): void => {
      this.owner.checkActive();
      callback(this.success(callbackId, 'Geolocation', methodName, JSON.stringify({ timestamp: location.timeStamp, coords: { latitude: location.latitude, longitude: location.longitude, accuracy: location.accuracy, altitude: location.altitude, altitudeAccuracy: null, speed: location.speed, heading: null, magneticHeading: null, trueHeading: null, headingAccuracy: null, course: null } })));
    }).catch((error: Object): void => callback(this.failure(callbackId, 'Geolocation', methodName, lynxNativeErrorCode(error, 'POSITION_UNAVAILABLE'), String(error))));
  }

  private handleApp(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'exitApp' || methodName === 'minimizeApp') {
      try {
        const context = this.abilityContext() as common.UIAbilityContext;
        const operation = methodName === 'exitApp' ? context.terminateSelf() : context.moveAbilityToBackground();
        operation.then((): void => {
        this.owner.checkActive();
          callback(this.success(callbackId, 'App', methodName));
        }).catch((error: Object): void => {
          callback(this.failure(callbackId, 'App', methodName, 'UNAVAILABLE', `App.${methodName} failed: ${String(error)}`));
        });
      } catch (error) {
        callback(this.failure(callbackId, 'App', methodName, 'UNAVAILABLE', `App.${methodName} failed: ${String(error)}`));
      }
      return;
    }
    switch (methodName) {
      case 'getInfo': {
        try {
          const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
          callback(this.success(callbackId, 'App', methodName, JSON.stringify({
            name: info.appInfo.name,
            id: info.name,
            build: String(info.versionCode),
            version: info.versionName,
          })));
        } catch (error) {
          callback(this.failure(callbackId, 'App', methodName, 'UNAVAILABLE', 'BundleManager metadata query failed: ' + String(error)));
        }
        break;
      }
      case 'getState':
        callback(this.success(callbackId, 'App', methodName, `{"isActive":${String(LynxHarmonyCapabilityRuntime.appIsActive)}}`));
        break;
      case 'getLaunchUrl':
        callback(this.success(callbackId, 'App', methodName, LynxHarmonyCapabilityRuntime.launchUrl.length === 0 ? '{"url":null}' : `{"url":${JSON.stringify(LynxHarmonyCapabilityRuntime.launchUrl)}}`));
        break;
      case 'getAppLanguage': {
        try {
          const rawLanguage = String(i18n.getSystemLanguage()).trim();
          const hyphenIndex = rawLanguage.indexOf('-');
          const underscoreIndex = rawLanguage.indexOf('_');
          let endIndex = rawLanguage.length;
          if (hyphenIndex >= 0) endIndex = hyphenIndex;
          if (underscoreIndex >= 0 && underscoreIndex < endIndex) endIndex = underscoreIndex;
          const language = rawLanguage.substring(0, endIndex).toLowerCase();
          callback(this.success(callbackId, 'App', methodName, JSON.stringify({ value: language })));
        } catch (error) {
          callback(this.failure(callbackId, 'App', methodName, 'UNAVAILABLE', 'App.getAppLanguage failed: ' + String(error)));
        }
        break;
      }
      case 'toggleBackButtonHandler': {
        const rawEnabled = options['enabled'];
        if (typeof rawEnabled !== 'boolean') {
          callback(this.failure(callbackId, 'App', methodName, 'INVALID_ARGUMENT', 'enabled is required and must be boolean'));
          break;
        }
        this.backButtonHandlerEnabled = rawEnabled as boolean;
        callback(this.success(callbackId, 'App', methodName));
        break;
      }
      default:
        callback(this.failure(callbackId, 'App', methodName, 'UNIMPLEMENTED', `App.${methodName} is not implemented`));
    }
  }

  private handleAppLauncher(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const url = String(options['url'] ?? '');
    if (url.length === 0) {
      callback(this.failure(callbackId, 'AppLauncher', methodName, 'INVALID_ARGUMENT', 'url is required'));
      return;
    }
    try {
      if (methodName === 'canOpenUrl') {
        callback(this.success(callbackId, 'AppLauncher', methodName, `{"value":${String(bundleManager.canOpenLink(url))}}`));
        return;
      }
      if (methodName !== 'openUrl') {
        callback(this.failure(callbackId, 'AppLauncher', methodName, 'UNIMPLEMENTED', `AppLauncher.${methodName} is not implemented`));
        return;
      }
      const context = this.abilityContext() as common.UIAbilityContext;
      context.openLink(url).then(() => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'AppLauncher', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'AppLauncher', methodName, 'UNAVAILABLE', `Unable to open URL: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'AppLauncher', methodName, 'UNAVAILABLE', `Unable to open URL: ${String(error)}`));
    }
  }

  private handleBrowser(callbackId: string, pluginId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'close') {
      if (pluginId === 'InAppBrowser') {
        this.closeInAppBrowser(callbackId, methodName, callback);
        return;
      }
      callback(this.failure(callbackId, pluginId, methodName, 'UNSUPPORTED', 'Browser.close cannot close an external browser activity'));
      return;
    }
    const url = String(options['url'] ?? '');
    if (url.length === 0 || !(url.startsWith('https://') || url.startsWith('http://'))) {
      callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
      return;
    }
    if (pluginId === 'InAppBrowser' && methodName === 'openInWebView') {
      this.openInAppBrowser(callbackId, url, options, callback);
      return;
    }
    if (methodName !== 'open' && methodName !== 'openInSystemBrowser' && methodName !== 'openInExternalBrowser') {
      callback(this.failure(callbackId, pluginId, methodName, 'UNIMPLEMENTED', `${pluginId}.${methodName} is not implemented`));
      return;
    }
    try {
      const context = this.abilityContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable'],
      };
      context.startAbility(want).then(() => {
        this.owner.checkActive();
        callback(this.success(callbackId, pluginId, methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', `Unable to open browser: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', `Unable to open browser: ${String(error)}`));
    }
  }

  private openInAppBrowser(callbackId: string, url: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (this.browserDialogContent !== null) {
      callback(this.failure(callbackId, 'InAppBrowser', 'openInWebView', 'UNAVAILABLE', 'Another InAppBrowser session is already visible'));
      return;
    }
    try {
      this.currentWindow().then((lastWindow: window.Window): void => {
        this.owner.checkActive();
        const uiContext: UIContext = this.requireHost().uiContext;
        const params: LynxCapacitorWebViewDialogParams = {
          url: url,
          headers: this.browserHeaders(options),
          onPageBegin: (_pageUrl: string): void => {},
          onClose: (): void => { uiContext.getPromptAction().closeCustomDialog(contentNode).catch((error: Object): void => console.error('LynxCapacitor', 'WebView close failed: ' + String(error))); },
          onPageLoaded: (pageUrl: string): void => {
            this.emitEvent('InAppBrowser', 'browserPageLoaded', '{}');
            this.emitEvent('InAppBrowser', 'browserPageNavigationCompleted', JSON.stringify({ url: pageUrl }));
          },
          onTitle: (_title: string): void => {},
          onError: (pageUrl: string, code: number, message: string): void => {
            const payload: LynxCapacitorWebViewErrorPayload = {
              success: false,
              url: pageUrl,
              error: { code: code, message: message },
            };
            this.emitEvent('InAppBrowser', 'browserPageLoaded', JSON.stringify(payload));
          },
        };
        const contentNode = new ComponentContent(uiContext, wrapBuilder(LynxCapacitorWebViewDialogBuilder), params);
        this.browserDialogContent = contentNode;
        this.browserDialogUIContext = uiContext;
        const dialogOptions: promptAction.BaseDialogOptions = {
          alignment: DialogAlignment.Center,
          autoCancel: true,
          maskColor: 'rgba(0, 0, 0, 0.6)',
          onDidDisappear: (): void => {
            if (this.browserDialogContent !== contentNode) return;
            this.browserDialogContent = null;
            this.browserDialogUIContext = null;
            this.emitEvent('InAppBrowser', 'browserClosed', '{}');
          },
        };
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).then(async (): Promise<void> => {
          if (!this.owner.isActive) { await uiContext.getPromptAction().closeCustomDialog(contentNode); this.owner.checkActive(); }
          callback(this.success(callbackId, 'InAppBrowser', 'openInWebView'));
        }).catch((error: Object): void => {
          if (this.browserDialogContent === contentNode) {
            this.browserDialogContent = null;
            this.browserDialogUIContext = null;
          }
          callback(this.failure(callbackId, 'InAppBrowser', 'openInWebView', 'UNAVAILABLE', `Unable to open in-app browser: ${String(error)}`));
        });
      }).catch((error: Object): void => {
        callback(this.failure(callbackId, 'InAppBrowser', 'openInWebView', 'UNAVAILABLE', `Unable to open in-app browser: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'InAppBrowser', 'openInWebView', 'UNAVAILABLE', `Unable to open in-app browser: ${String(error)}`));
    }
  }

  private closeInAppBrowser(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    const contentNode = this.browserDialogContent;
    const uiContext = this.browserDialogUIContext;
    if (contentNode === null || uiContext === null) {
      callback(this.failure(callbackId, 'InAppBrowser', methodName, 'UNAVAILABLE', 'No InAppBrowser WebView session is visible'));
      return;
    }
    uiContext.getPromptAction().closeCustomDialog(contentNode).then((): void => {
        this.owner.checkActive();
      callback(this.success(callbackId, 'InAppBrowser', methodName));
    }).catch((error: Object): void => {
      callback(this.failure(callbackId, 'InAppBrowser', methodName, 'UNAVAILABLE', `Unable to close in-app browser: ${String(error)}`));
    });
  }

  private browserHeaders(options: Record<string, Object>): Array<webview.WebHeader> {
    const rawHeaders = options['customHeaders'];
    if (rawHeaders === null || rawHeaders === undefined || typeof rawHeaders !== 'object') return [];
    const headers: Array<webview.WebHeader> = [];
    const values = rawHeaders as Record<string, Object>;
    Object.keys(values).forEach((key: string): void => {
      headers.push({ headerKey: key, headerValue: String(values[key] ?? '') });
    });
    return headers;
  }

  private handleSplashScreen(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName !== 'show' && methodName !== 'hide') {
      callback(this.failure(callbackId, 'SplashScreen', methodName, 'UNIMPLEMENTED', `SplashScreen.${methodName} is not implemented`));
      return;
    }
    if (methodName === 'hide') {
      const contentNode = this.splashDialogContent;
      const uiContext = this.splashDialogUIContext;
      if (contentNode === null || uiContext === null) {
        callback(this.success(callbackId, 'SplashScreen', methodName));
        return;
      }
      uiContext.getPromptAction().closeCustomDialog(contentNode).then((): void => {
        this.owner.checkActive();
        if (this.splashDialogContent === contentNode) {
          this.splashDialogContent = null;
          this.splashDialogUIContext = null;
        }
        callback(this.success(callbackId, 'SplashScreen', methodName));
      }).catch((error: Object): void => {
        callback(this.failure(callbackId, 'SplashScreen', methodName, 'UNAVAILABLE', `Unable to hide splash screen: ${String(error)}`));
      });
      return;
    }

    const backgroundColor = String(options['backgroundColor'] ?? '#FFFFFF').trim();
    if (!/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/.test(backgroundColor)) {
      callback(this.failure(callbackId, 'SplashScreen', methodName, 'INVALID_ARGUMENT', 'backgroundColor must be #RRGGBB or #RRGGBBAA'));
      return;
    }
    if (this.splashDialogContent !== null) {
      callback(this.success(callbackId, 'SplashScreen', methodName));
      return;
    }
    try {
      this.currentWindow().then((lastWindow: window.Window): void => {
        this.owner.checkActive();
        const uiContext: UIContext = this.requireHost().uiContext;
        const params: LynxCapacitorSplashDialogParams = { backgroundColor: backgroundColor };
        const contentNode = new ComponentContent(uiContext, wrapBuilder(LynxCapacitorSplashDialogBuilder), params);
        this.splashDialogContent = contentNode;
        this.splashDialogUIContext = uiContext;
        const dialogOptions: promptAction.BaseDialogOptions = {
          alignment: DialogAlignment.Center,
          autoCancel: false,
          isModal: true,
          maskColor: backgroundColor,
          onDidDisappear: (): void => {
            if (this.splashDialogContent !== contentNode) return;
            this.splashDialogContent = null;
            this.splashDialogUIContext = null;
          },
        };
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).then(async (): Promise<void> => {
          if (!this.owner.isActive) { await uiContext.getPromptAction().closeCustomDialog(contentNode); this.owner.checkActive(); }
          callback(this.success(callbackId, 'SplashScreen', methodName));
        }).catch((error: Object): void => {
          if (this.splashDialogContent === contentNode) {
            this.splashDialogContent = null;
            this.splashDialogUIContext = null;
          }
          callback(this.failure(callbackId, 'SplashScreen', methodName, 'UNAVAILABLE', `Unable to show splash screen: ${String(error)}`));
        });
      }).catch((error: Object): void => {
        callback(this.failure(callbackId, 'SplashScreen', methodName, 'UNAVAILABLE', `Unable to show splash screen: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'SplashScreen', methodName, 'UNAVAILABLE', `Unable to show splash screen: ${String(error)}`));
    }
  }

  private handleFileViewer(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.media.dispatch(callbackId, 'FileViewer', methodName, options, callback);
  }

  private handleDevice(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    const model = JSON.stringify(String(deviceInfo.productModel));
    const manufacturer = JSON.stringify(String(deviceInfo.manufacture));
    const name = JSON.stringify(String(deviceInfo.productModelAlias).length > 0 ? String(deviceInfo.productModelAlias) : String(deviceInfo.productModel));
    const osVersion = JSON.stringify(String(deviceInfo.osFullName));
    switch (methodName) {
      case 'getInfo':
        callback(this.success(callbackId, 'Device', methodName, `{"model":${model},"platform":"harmony","operatingSystem":"harmony","osVersion":${osVersion},"manufacturer":${manufacturer},"name":${name},"isVirtual":null,"isVirtualKnown":false,"webViewVersion":""}`));
        break;
      case 'getId':
        try {
          this.completeAsync(callbackId, 'Device', methodName, this.preferenceAdapter.deviceIdentifier(), callback);
        } catch (error) {
          callback(this.failure(callbackId, 'Device', methodName, 'UNAVAILABLE', 'Device identifier storage failed: ' + String(error)));
        }
        break;
      case 'getBatteryInfo':
        try {
          const level = Number(batteryInfo.batterySOC) / 100;
          const isCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
          callback(this.success(callbackId, 'Device', methodName, JSON.stringify({
            batteryLevel: Number.isFinite(level) ? Math.max(0, Math.min(1, level)) : null,
            isCharging: isCharging,
          })));
        } catch (error) {
          callback(this.failure(callbackId, 'Device', methodName, 'UNAVAILABLE', 'Battery information query failed: ' + String(error)));
        }
        break;
      case 'getLanguageCode':
        try {
          callback(this.success(callbackId, 'Device', methodName, JSON.stringify({ value: this.systemLanguageCode() })));
        } catch (error) {
          callback(this.failure(callbackId, 'Device', methodName, 'UNAVAILABLE', 'System language query failed: ' + String(error)));
        }
        break;
      case 'getLanguageTag':
        try {
          callback(this.success(callbackId, 'Device', methodName, JSON.stringify({ value: this.systemLanguageTag() })));
        } catch (error) {
          callback(this.failure(callbackId, 'Device', methodName, 'UNAVAILABLE', 'System language query failed: ' + String(error)));
        }
        break;
      default:
      callback(this.failure(callbackId, 'Device', methodName, 'UNIMPLEMENTED', `Device.${methodName} is not implemented`));
    }
  }

  /** 真实 UserAuthenticationKit 认证，与无硬件/未登记的运行条件区分。 */
  private handleBiometrics(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'Biometrics', methodName, this.biometrics.dispatch(methodName, options), callback);
  }

  private handleAudio(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      if (methodName === 'requestPermissions') {
        this.ensureHarmonyPermissions(callbackId, 'Audio', methodName, ['ohos.permission.MICROPHONE'], callback, (): void => {
          LynxHarmonyAudioCapabilities.dispatch(this.abilityContext(), this.owner, 'checkPermissions', options, (result: LynxHarmonyAudioResult): void => {
            if (result.error !== undefined) callback(this.failure(callbackId, 'Audio', methodName, result.error.code, result.error.message));
            else callback(this.success(callbackId, 'Audio', methodName, JSON.stringify(result.data ?? {})));
          });
        });
        return;
      }
      const claimed = LynxHarmonyAudioCapabilities.dispatch(
        this.abilityContext() as common.UIAbilityContext,
        this.owner,
        methodName,
        options,
        (result: LynxHarmonyAudioResult): void => {
          if (result.error !== undefined) {
            callback(this.failure(callbackId, 'Audio', methodName, result.error.code, result.error.message));
            return;
          }
          callback(this.success(callbackId, 'Audio', methodName, result.data === undefined ? '{}' : JSON.stringify(result.data)));
        },
      );
      if (!claimed) callback(this.failure(callbackId, 'Audio', methodName, 'UNIMPLEMENTED', `Audio.${methodName} is not implemented`));
    } catch (error) {
      callback(this.failure(callbackId, 'Audio', methodName, 'UNAVAILABLE', `Audio.${methodName} failed: ${String(error)}`));
    }
  }

  private systemLanguageTag(): string {
    return String(i18n.getSystemLanguage()).trim().replace(/_/g, '-');
  }

  private systemLanguageCode(): string {
    const tag = this.systemLanguageTag();
    const separator = tag.indexOf('-');
    return (separator >= 0 ? tag.substring(0, separator) : tag).toLowerCase();
  }

  private handlePreferences(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'Preferences', methodName, this.preferenceAdapter.dispatch(methodName, options), callback);
  }

  private handleClipboard(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      switch (methodName) {
        case 'write': {
          const value = String(options['string'] ?? options['text'] ?? '');
          systemPasteboard.setDataSync(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
          callback(this.success(callbackId, 'Clipboard', methodName));
          break;
        }
        case 'read': {
          const rawValue = systemPasteboard.getDataSync().getPrimaryText() as Object;
          const value = typeof rawValue === 'string' ? rawValue : (rawValue === null || rawValue === undefined ? '' : String(rawValue));
          const encoded = JSON.stringify(value);
          callback(this.success(callbackId, 'Clipboard', methodName, `{"type":"text/plain","value":${encoded === undefined ? '""' : encoded}}`));
          break;
        }
        default:
          callback(this.failure(callbackId, 'Clipboard', methodName, 'UNIMPLEMENTED', `Clipboard.${methodName} is not implemented`));
      }
    } catch (error) {
      callback(this.failure(callbackId, 'Clipboard', methodName, 'UNAVAILABLE', `Clipboard operation failed: ${error}`));
    }
  }

  /** 使用 ArkWeb WebCookieManager 对齐 CapacitorCookies；HTTP 请求 cookie jar 仍由 NetworkKit 管理。 */
  private handleCookies(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const url = String(options['url'] ?? '');
    if (!(url.startsWith('https://') || url.startsWith('http://'))) {
      callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
      return;
    }
    try {
      if (methodName === 'getCookies') {
        webview.WebCookieManager.fetchCookie(url).then((raw: string) => {
        this.owner.checkActive();
          callback(this.success(callbackId, 'CapacitorCookies', methodName, this.cookieMapJSON(raw)));
        }).catch((error: Object) => callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNAVAILABLE', 'Cookie read failed: ' + String(error))));
        return;
      }
      if (methodName === 'setCookie' || methodName === 'deleteCookie') {
        const key = String(options['key'] ?? '');
        if (key.length === 0) {
          callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'INVALID_ARGUMENT', 'key is required'));
          return;
        }
        const value = methodName === 'deleteCookie' ? '' : String(options['value'] ?? '');
        let cookie = key + '=' + value;
        const path = String(options['path'] ?? '/');
        if (path.length > 0) cookie += '; Path=' + path;
        const domain = String(options['domain'] ?? '');
        if (domain.length > 0) cookie += '; Domain=' + domain;
        if (methodName === 'deleteCookie') cookie += '; Expires=Thu, 01 Jan 1970 00:00:00 GMT';
        webview.WebCookieManager.configCookie(url, cookie).then(() => callback(this.success(callbackId, 'CapacitorCookies', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNAVAILABLE', 'Cookie write failed: ' + String(error))));
        return;
      }
      if (methodName === 'clearCookies') {
        webview.WebCookieManager.fetchCookie(url).then((raw: string) => {
        this.owner.checkActive();
          const expired = this.cookieNames(raw).map((key: string) => webview.WebCookieManager.configCookie(url, key + '=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Path=/'));
          return Promise.all(expired);
        }).then(() => callback(this.success(callbackId, 'CapacitorCookies', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNAVAILABLE', 'Cookie clear failed: ' + String(error))));
        return;
      }
      if (methodName === 'clearAllCookies') {
        webview.WebCookieManager.clearAllCookies().then(() => callback(this.success(callbackId, 'CapacitorCookies', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNAVAILABLE', 'Cookie clear failed: ' + String(error))));
        return;
      }
      callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNIMPLEMENTED', 'CapacitorCookies.' + methodName + ' is not implemented'));
    } catch (error) {
      callback(this.failure(callbackId, 'CapacitorCookies', methodName, 'UNAVAILABLE', 'Cookie operation failed: ' + String(error)));
    }
  }

  private cookieMapJSON(raw: string): string {
    const entries: string[] = [];
    raw.split(';').forEach((part: string) => {
      const separator = part.indexOf('=');
      if (separator <= 0) return;
      const key = part.substring(0, separator).trim();
      const value = part.substring(separator + 1).trim();
      if (key.length > 0) entries.push(JSON.stringify(key) + ':' + JSON.stringify(value));
    });
    return '{' + entries.join(',') + '}';
  }

  /** 从当前 URL 可见的 Cookie header 中提取名称，供 URL 范围过期删除使用。 */
  private cookieNames(raw: string): Array<string> {
    const names: string[] = [];
    raw.split(';').forEach((part: string): void => {
      const separator = part.indexOf('=');
      if (separator <= 0) return;
      const key = part.substring(0, separator).trim();
      if (key.length > 0 && names.indexOf(key) < 0) names.push(key);
    });
    return names;
  }

  private handleNetwork(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    if (methodName !== 'getStatus') {
      callback(this.failure(callbackId, 'Network', methodName, 'CONTRACTED', 'Network listener lifecycle requires a host connection observer'));
      return;
    }
    try {
      if (!connection.hasDefaultNetSync()) {
        callback(this.success(callbackId, 'Network', methodName, '{"connected":false,"connectionType":"none"}'));
        return;
      }
      const network = connection.getDefaultNetSync();
      const capabilities = connection.getNetCapabilitiesSync(network);
      let connectionType: string = 'unknown';
      if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) connectionType = 'wifi';
      else if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) connectionType = 'cellular';
      else if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0) connectionType = 'ethernet';
      callback(this.success(callbackId, 'Network', methodName, `{"connected":true,"connectionType":${JSON.stringify(connectionType)}}`));
    } catch (error) {
      callback(this.failure(callbackId, 'Network', methodName, 'UNAVAILABLE', `Network status failed: ${String(error)}`));
    }
  }

  private handleHttp(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'CapacitorHttp', methodName, this.httpAdapter.request(methodName, options), callback);
  }

  private handleHaptics(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      if (methodName === 'getCapabilities') {
        const effects = ['haptic.effect.soft', 'haptic.effect.hard', 'haptic.effect.sharp', 'haptic.notice.success', 'haptic.notice.fail', 'haptic.notice.warning'];
        callback(this.success(callbackId, 'Haptics', methodName, JSON.stringify({
          supported: true,
          hasVibrator: true,
          permissionRequired: true,
          predefinedEffects: effects,
          composition: { available: true, mode: 'pattern', androidPrimitiveParity: false, reason: 'Harmony 以 VibratorPattern 复刻时间序列，未承诺 Android primitive 的硬件等价性' } as LynxCapacitorHapticsCompositionStatus,
          highDefinition: vibrator.isHdHapticSupported(),
        })));
        return;
      }
      if (methodName === 'cancel') {
        vibrator.stopVibration().then(() => callback(this.success(callbackId, 'Haptics', methodName, '{"cancelled":true}'))).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', methodName, this.hapticsErrorCode(error), `Haptics cancel failed: ${String(error)}`)));
        return;
      }
      if (methodName === 'vibrateWaveform') {
        this.handleHapticsWaveform(callbackId, options, callback);
        return;
      }
      if (methodName === 'vibrateComposition') {
        this.handleHapticsComposition(callbackId, options, callback);
        return;
      }
      if (methodName === 'vibratePredefined') {
        this.handleHapticsPredefined(callbackId, options, callback);
        return;
      }
      if (methodName === 'impact' || methodName === 'notification' || methodName === 'selection') {
        const effect = methodName === 'notification'
          ? this.harmonyNotificationEffect(String(options['type'] ?? 'SUCCESS'))
          : methodName === 'selection'
            ? 'haptic.effect.soft'
            : this.harmonyImpactEffect(String(options['style'] ?? 'MEDIUM'));
        this.startHapticsPreset(callbackId, methodName, effect, callback);
        return;
      }
      if (methodName === 'vibrate' || methodName === 'vibrateLong') {
        const defaultDuration = methodName === 'vibrateLong' ? 1500 : 40;
        const duration = Number(options['duration'] ?? defaultDuration);
        if (!Number.isFinite(duration) || duration <= 0 || duration > 30000) {
          callback(this.failure(callbackId, 'Haptics', methodName, 'INVALID_ARGUMENT', 'duration must be between 1 and 30000 milliseconds'));
          return;
        }
        const effect = { type: 'time', duration: Math.floor(duration) } as vibrator.VibrateEffect;
        vibrator.startVibration(effect, { usage: 'touch' }).then(() => callback(this.success(callbackId, 'Haptics', methodName, JSON.stringify({ fired: true, durationMs: Math.floor(duration) })))).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', methodName, this.hapticsErrorCode(error), `Haptics operation failed: ${String(error)}`)));
        return;
      }
      callback(this.failure(callbackId, 'Haptics', methodName, 'UNIMPLEMENTED', `Haptics.${methodName} is not implemented`));
    } catch (error) {
      callback(this.failure(callbackId, 'Haptics', methodName, this.hapticsErrorCode(error), `Haptics operation failed: ${String(error)}`));
    }
  }

  private harmonyImpactEffect(style: string): string {
    switch (style.toUpperCase()) {
      case 'LIGHT': return 'haptic.effect.soft';
      case 'HEAVY': return 'haptic.effect.sharp';
      case 'MEDIUM':
      case 'DEFAULT': return 'haptic.effect.hard';
      default: throw new Error('impact.style only supports LIGHT, MEDIUM, or HEAVY');
    }
  }

  private harmonyNotificationEffect(type: string): string {
    switch (type.toUpperCase()) {
      case 'SUCCESS': return 'haptic.notice.success';
      case 'ERROR':
      case 'FAILURE': return 'haptic.notice.fail';
      case 'WARNING': return 'haptic.notice.warning';
      default: throw new Error('notification.type only supports SUCCESS, WARNING, ERROR, or FAILURE');
    }
  }

  private startHapticsPreset(callbackId: string, methodName: string, effectId: string, callback: (resultJSON: string) => void): void {
    const effect = { type: 'preset', effectId: effectId } as vibrator.VibrateEffect;
    vibrator.startVibration(effect, { usage: 'touch' }).then(() => callback(this.success(callbackId, 'Haptics', methodName, JSON.stringify({ fired: true, effectId: effectId })))).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', methodName, this.hapticsErrorCode(error), `Haptics operation failed: ${String(error)}`)));
  }

  private handleHapticsPredefined(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const requested = String(options['effectId'] ?? 'CLICK').trim().toUpperCase();
    const effectId = requested === 'SUCCESS' ? 'haptic.notice.success'
      : requested === 'WARNING' ? 'haptic.notice.warning'
        : requested === 'ERROR' || requested === 'FAILURE' ? 'haptic.notice.fail'
          : requested === 'TICK' || requested === 'CLICK' ? 'haptic.effect.soft'
            : requested === 'HEAVY_CLICK' ? 'haptic.effect.hard'
              : requested === 'DOUBLE_CLICK' ? 'haptic.effect.sharp' : '';
    if (effectId.length === 0) {
      callback(this.failure(callbackId, 'Haptics', 'vibratePredefined', 'INVALID_ARGUMENT', 'effectId is not a supported Harmony preset'));
      return;
    }
    try {
      vibrator.isSupportEffect(effectId).then((supported: boolean) => {
        this.owner.checkActive();
        if (!supported) {
          callback(this.failure(callbackId, 'Haptics', 'vibratePredefined', 'UNSUPPORTED', `Harmony preset ${effectId} is not supported`));
          return;
        }
        this.startHapticsPreset(callbackId, 'vibratePredefined', effectId, callback);
      }).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', 'vibratePredefined', this.hapticsErrorCode(error), `Haptics preset query failed: ${String(error)}`)));
    } catch (error) {
      callback(this.failure(callbackId, 'Haptics', 'vibratePredefined', this.hapticsErrorCode(error), `Haptics preset failed: ${String(error)}`));
    }
  }

  private handleHapticsComposition(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const rawPrimitives = options['primitives'];
    if (!Array.isArray(rawPrimitives)) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateComposition', 'INVALID_ARGUMENT', 'primitives must be an array'));
      return;
    }
    const primitives = rawPrimitives as Array<Object>;
    if (primitives.length === 0 || primitives.length > 32) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateComposition', 'INVALID_ARGUMENT', 'primitives length must be between 1 and 32'));
      return;
    }
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      let cursor = 0;
      const names: string[] = [];
      primitives.forEach((raw: Object, index: number): void => {
        if (raw === null || typeof raw !== 'object') throw new Error(`primitives[${index}] must be an object`);
        const item = raw as Record<string, Object>;
        const name = String(item['id'] ?? '').trim().toUpperCase();
        const duration = this.hapticsPrimitiveDuration(name);
        if (duration <= 0) throw new Error(`primitives[${index}].id is not supported`);
        const scale = Number(item['scale'] ?? 1);
        const delay = Number(item['delay'] ?? 0);
        if (!Number.isFinite(scale) || scale < 0 || scale > 1 || !Number.isInteger(delay) || delay < 0 || delay > 10000) {
          throw new Error(`primitives[${index}] scale/delay is invalid`);
        }
        cursor += delay;
        const parameters: vibrator.TransientParam = { intensity: scale };
        builder.addTransientEvent(cursor, parameters);
        cursor += duration;
        names.push(name);
      });
      const effect = { type: 'pattern', pattern: builder.build() } as vibrator.VibrateEffect;
      const data: Record<string, Object> = {};
      data['fired'] = true;
      data['primitiveCount'] = primitives.length;
      data['primitives'] = names;
      data['durationMs'] = cursor;
      data['androidPrimitiveParity'] = false;
      vibrator.startVibration(effect, { usage: 'touch' }).then(() => callback(this.success(callbackId, 'Haptics', 'vibrateComposition', JSON.stringify(data)))).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', 'vibrateComposition', this.hapticsErrorCode(error), `Haptics composition failed: ${String(error)}`)));
    } catch (error) {
      const message = String(error);
      callback(this.failure(callbackId, 'Haptics', 'vibrateComposition', message.indexOf('not supported') >= 0 ? 'UNSUPPORTED' : 'INVALID_ARGUMENT', message));
    }
  }

  private hapticsPrimitiveDuration(name: string): number {
    switch (name) {
      case 'CLICK':
      case 'TICK':
      case 'QUICK_RISE':
      case 'QUICK_FALL': return 35;
      case 'THUD':
      case 'SLOW_RISE': return 80;
      case 'SPIN': return 120;
      default: return 0;
    }
  }

  private handleHapticsWaveform(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const rawTimings = options['timings'];
    const timings: number[] = Array.isArray(rawTimings) ? (rawTimings as Array<Object>).map((value: Object) => Number(value)) : [0, 250, 150, 250];
    if (timings.length === 0 || timings.length > 64 || timings.some((value: number) => !Number.isFinite(value) || value < 0)) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', 'INVALID_ARGUMENT', 'timings must contain 0..64 non-negative numbers'));
      return;
    }
    const total = timings.reduce((sum: number, value: number) => sum + value, 0);
    if (total > 30000) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', 'INVALID_ARGUMENT', 'waveform duration must not exceed 30000 milliseconds'));
      return;
    }
    const rawAmplitudes = options['amplitudes'];
    let amplitudes: number[] | null = null;
    if (rawAmplitudes !== undefined && rawAmplitudes !== null) {
      if (!Array.isArray(rawAmplitudes) || (rawAmplitudes as Array<Object>).length !== timings.length) {
        callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', 'INVALID_ARGUMENT', 'amplitudes length must match timings length'));
        return;
      }
      amplitudes = (rawAmplitudes as Array<Object>).map((value: Object) => Number(value));
      if (amplitudes.some((value: number) => !Number.isFinite(value) || value < 0 || value > 255)) {
        callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', 'INVALID_ARGUMENT', 'amplitudes must be between 0 and 255'));
        return;
      }
    }
    const repeat = Number(options['repeat'] ?? -1);
    if (!Number.isInteger(repeat) || repeat >= 0) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', 'UNSUPPORTED', 'Harmony pattern adapter currently supports one-shot waveforms only'));
      return;
    }
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      let cursor = 0;
      timings.forEach((timing: number, index: number): void => {
        if (index % 2 === 1 && timing > 0) {
          if (amplitudes === null) {
            builder.addContinuousEvent(cursor, timing);
          } else {
            const intensity = Math.max(0, Math.min(1, (amplitudes[index] ?? 255) / 255));
            const parameters: vibrator.ContinuousParam = { intensity: intensity };
            builder.addContinuousEvent(cursor, timing, parameters);
          }
        }
        cursor += timing;
      });
      const effect = { type: 'pattern', pattern: builder.build() } as vibrator.VibrateEffect;
      const data: Record<string, Object> = {};
      data['fired'] = true;
      data['timings'] = timings;
      data['repeat'] = -1;
      data['durationMs'] = total;
      if (amplitudes !== null) data['amplitudes'] = amplitudes;
      vibrator.startVibration(effect, { usage: 'touch' }).then(() => callback(this.success(callbackId, 'Haptics', 'vibrateWaveform', JSON.stringify(data)))).catch((error: Object) => callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', this.hapticsErrorCode(error), `Haptics waveform failed: ${String(error)}`)));
    } catch (error) {
      callback(this.failure(callbackId, 'Haptics', 'vibrateWaveform', this.hapticsErrorCode(error), `Haptics waveform failed: ${String(error)}`));
    }
  }

  private hapticsErrorCode(error: Object): string {
    const value = String(error).toLowerCase();
    if (value.indexOf('201') >= 0 || value.indexOf('permission') >= 0) return 'PERMISSION_DENIED';
    if (value.indexOf('401') >= 0 || value.indexOf('invalid') >= 0) return 'INVALID_ARGUMENT';
    if (value.indexOf('801') >= 0 || value.indexOf('support') >= 0) return 'UNSUPPORTED';
    return 'UNAVAILABLE';
  }

  private handleToast(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'getCapabilities') {
      callback(this.success(callbackId, 'Toast', methodName, JSON.stringify({
        supported: true,
        durations: ['short', 'long'],
        positions: ['bottom'],
        supportsCustomPosition: false,
        supportsCancel: true,
      })));
      return;
    }
    if (methodName === 'cancel') {
      this.toastGeneration += 1;
      const cancelled = this.closeActiveToast();
      callback(this.success(callbackId, 'Toast', methodName, JSON.stringify({ cancelled: cancelled })));
      return;
    }
    if (methodName !== 'show') {
      callback(this.failure(callbackId, 'Toast', methodName, 'UNIMPLEMENTED', `Toast.${methodName} is not implemented`));
      return;
    }
    const rawText = options['text'];
    if (rawText === undefined || rawText === null || typeof rawText !== 'string' || String(rawText).length === 0) {
      callback(this.failure(callbackId, 'Toast', methodName, 'INVALID_ARGUMENT', 'text must be a non-empty string'));
      return;
    }
    const durationName = String(options['duration'] ?? 'short').toLowerCase();
    if (durationName !== 'short' && durationName !== 'long') {
      callback(this.failure(callbackId, 'Toast', methodName, 'INVALID_ARGUMENT', 'duration only supports short or long'));
      return;
    }
    const position = String(options['position'] ?? 'bottom').toLowerCase();
    if (position !== 'bottom' && position !== 'top' && position !== 'center') {
      callback(this.failure(callbackId, 'Toast', methodName, 'INVALID_ARGUMENT', 'position only supports top, center, or bottom'));
      return;
    }
    const generation = this.toastGeneration + 1;
    this.toastGeneration = generation;
    this.closeActiveToast();
    try {
      this.currentWindow().then((lastWindow: window.Window): void => {
        this.owner.checkActive();
        if (generation !== this.toastGeneration) return;
        const uiContext = lastWindow.getUIContext();
        const toastOptions: promptAction.ShowToastOptions = {
          message: String(rawText),
          duration: durationName === 'long' ? 10000 : 3000,
          // Harmony 原生 Toast 只提供 bottom 偏移；top/center 明确降级为 bottom，
          // 与 Android 12+ 文本 Toast 的系统位置规则一致。
          bottom: 80
        };
        uiContext.getPromptAction().openToast(toastOptions).then((id: number): void => {
        this.owner.checkActive();
          if (generation !== this.toastGeneration) {
            try { uiContext.getPromptAction().closeToast(id); } catch (_) {}
            return;
          }
          this.toastUIContext = uiContext;
          this.toastId = id;
          callback(this.success(callbackId, 'Toast', methodName, JSON.stringify({
            shown: true,
            text: String(rawText),
            duration: durationName,
            requestedPosition: position,
            effectivePosition: 'bottom',
            positionApplied: position === 'bottom',
          })));
        }).catch((error: Object) => callback(this.failure(callbackId, 'Toast', methodName, this.toastErrorCode(error), `Toast operation failed: ${String(error)}`)));
      }).catch((error: Object) => callback(this.failure(callbackId, 'Toast', methodName, 'UNAVAILABLE', `Toast operation failed: ${String(error)}`)));
    } catch (error) {
      callback(this.failure(callbackId, 'Toast', methodName, 'UNAVAILABLE', `Toast operation failed: ${String(error)}`));
    }
  }

  private closeActiveToast(): boolean {
    const uiContext = this.toastUIContext;
    const id = this.toastId;
    this.toastUIContext = null;
    this.toastId = null;
    if (uiContext === null || id === null) return false;
    try {
      uiContext.getPromptAction().closeToast(id);
      return true;
    } catch (error) {
      console.error('LynxHarmonyCapabilityRuntime', `Toast close failed: ${String(error)}`);
      return false;
    }
  }

  private toastErrorCode(error: Object): string {
    const value = String(error).toLowerCase();
    if (value.indexOf('401') >= 0 || value.indexOf('invalid') >= 0) return 'INVALID_ARGUMENT';
    return 'UNAVAILABLE';
  }

  private handleKeepAwake(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    if (methodName === 'isKeptAwake') {
      callback(this.success(callbackId, 'KeepAwake', methodName, `{"isKeptAwake":${String(this.keepAwake)}}`));
      return;
    }
    if (methodName === 'isSupported') {
      try {
        this.currentWindow().then(() => {
        this.owner.checkActive();
          callback(this.success(callbackId, 'KeepAwake', methodName, '{"isSupported":true}'));
        }).catch((error: Object) => {
          callback(this.success(callbackId, 'KeepAwake', methodName, `{"isSupported":false,"reason":${JSON.stringify(String(error))}}`));
        });
      } catch (error) {
        callback(this.success(callbackId, 'KeepAwake', methodName, `{"isSupported":false,"reason":${JSON.stringify(String(error))}}`));
      }
      return;
    }
    if (methodName !== 'keepAwake' && methodName !== 'allowSleep') {
      callback(this.failure(callbackId, 'KeepAwake', methodName, 'UNIMPLEMENTED', `KeepAwake.${methodName} is not implemented`));
      return;
    }
    try {
      const value = methodName === 'keepAwake';
      this.currentWindow().then((lastWindow: window.Window) => {
        this.owner.checkActive();
        return LynxCapacitorWindowLeases.set(lastWindow, this.owner.id, false, value);
      }).then(() => {
        this.owner.checkActive();
        this.keepAwake = value;
        callback(this.success(callbackId, 'KeepAwake', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'KeepAwake', methodName, 'UNAVAILABLE', `KeepAwake operation failed: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'KeepAwake', methodName, 'UNAVAILABLE', `KeepAwake operation failed: ${String(error)}`));
    }
  }

  private handleSafeArea(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    let names: Array<'status' | 'navigation'> = ['status', 'navigation'];
    const type = String(options['type'] ?? '').toUpperCase();
    if (type === 'STATUS_BAR') names = ['status'];
    else if (type === 'NAVIGATION_BAR') names = ['navigation'];
    try {
      this.currentWindow().then((lastWindow: window.Window) => {
        this.owner.checkActive();
        if (methodName === 'showSystemBars' || methodName === 'hideSystemBars') {
          if (methodName === 'showSystemBars') return lastWindow.setWindowSystemBarEnable(names);
          return Promise.all(names.map((name: 'status' | 'navigation') => lastWindow.setSpecificSystemBarEnabled(name, false))).then(() => undefined);
        }
        if (methodName === 'setSystemBarsStyle') {
          const style = String(options['style'] ?? 'DEFAULT').toUpperCase();
          const lightIcons = style === 'LIGHT';
          const properties: window.SystemBarProperties = {};
          if (names.indexOf('status') >= 0) properties.isStatusBarLightIcon = lightIcons;
          if (names.indexOf('navigation') >= 0) properties.isNavigationBarLightIcon = lightIcons;
          return lastWindow.setWindowSystemBarProperties(properties);
        }
        throw new Error(`SafeArea.${methodName} is not implemented`);
      }).then(() => {
        this.owner.checkActive();
        callback(this.success(callbackId, 'SafeArea', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'SafeArea', methodName, 'UNAVAILABLE', `SafeArea operation failed: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'SafeArea', methodName, 'UNAVAILABLE', `SafeArea operation failed: ${String(error)}`));
    }
  }

  private handleFilesystem(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'Filesystem', methodName, LynxHarmonyFilesystem.dispatch(this.owner, this.abilityContext(), methodName, options), callback);
  }

  private handleFileTransfer(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.completeAsync(callbackId, 'FileTransfer', methodName, this.transfer.dispatch(methodName, options), callback);
  }

  private completeAsync(callbackId: string, plugin: string, method: string, operation: Promise<Object>, callback: (json: string) => void): void {
    operation.then(async (data: Object): Promise<void> => {
      this.owner.checkActive();
      const json = String(await LynxHarmonyNativeIO.task(this.owner, 'stringify', [data]));
      this.owner.checkActive();
      callback(this.success(callbackId, plugin, method, json));
    }).catch((error: Object): void => callback(this.failure(callbackId, plugin, method, lynxNativeErrorCode(error), String(error))));
  }

  private initializePreferences(): Promise<void> {
    if (this.notificationInitialization !== null) return this.notificationInitialization;
    this.notificationInitialization = LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      const store = await preferences.getPreferences(this.abilityContext(), { name: 'lynx_capacitor_preferences' });
      this.owner.checkActive();
      const ids = await store.get(LynxHarmonyCapabilityRuntime.localNotificationIdsKey, null);
      const channels = await store.get(LynxHarmonyCapabilityRuntime.localNotificationChannelsKey, null);
      this.owner.checkActive();
      if (typeof ids === 'string' && ids.length > 0) {
        const values = await LynxHarmonyNativeIO.directTask('parseJSON', [ids]);
        this.owner.checkActive();
        if (!Array.isArray(values)) throw new Error('INVALID_RESPONSE: 通知索引不是数组');
        for (const value of values as Array<Object>) {
          const id = Number(value);
          if (!Number.isSafeInteger(id) || id < 0) throw new Error('INVALID_RESPONSE: 通知索引包含无效 ID');
          this.localNotificationIds.set(id, { id: id, title: '', body: '' });
        }
      }
      if (typeof channels === 'string' && channels.length > 0) {
        const values = await LynxHarmonyNativeIO.directTask('parseJSON', [channels]);
        this.owner.checkActive();
        if (!Array.isArray(values)) throw new Error('INVALID_RESPONSE: 通知 channel 索引不是数组');
        for (const value of values as Array<Object>) {
          const entry = value as Record<string, Object>;
          const id = String(entry['id'] ?? '');
          if (id.length === 0) throw new Error('INVALID_RESPONSE: 通知 channel ID 为空');
          const importance = String(entry['importance'] ?? 'default');
          this.localNotificationChannels.set(id, { id: id, name: String(entry['name'] ?? id), description: String(entry['description'] ?? ''), importance: importance, slotType: this.notificationSlotType(importance) });
        }
      }
      this.owner.checkActive();
      this.dataPreferences = store;
      return {};
    }).then((): void => {}).catch((error: Object): void => {
      this.notificationInitialization = null;
      this.localNotificationIds.clear();
      this.localNotificationChannels.clear();
      throw error;
    });
    return this.notificationInitialization;
  }

  private persistLocalNotificationIds(): Promise<void> {
    const ids: Array<number> = [];
    this.localNotificationIds.forEach((_value: LynxCapacitorLocalNotification, id: number): void => { ids.push(id); });
    return this.persistNotificationIndex(LynxHarmonyCapabilityRuntime.localNotificationIdsKey, ids);
  }

  private persistLocalNotificationChannels(): Promise<void> {
    const channels: Array<Object> = [];
    this.localNotificationChannels.forEach((channel: LynxCapacitorNotificationChannel): void => { channels.push({ id: channel.id, name: channel.name, description: channel.description, importance: channel.importance }); });
    return this.persistNotificationIndex(LynxHarmonyCapabilityRuntime.localNotificationChannelsKey, channels);
  }

  private persistNotificationIndex(key: string, value: Object): Promise<void> {
    return LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      const store = this.dataPreferences;
      if (store === null) throw new Error('UNAVAILABLE: 通知存储尚未初始化');
      const json = String(await LynxHarmonyNativeIO.directTask('stringify', [value]));
      this.owner.checkActive();
      await store.put(key, json);
      this.owner.checkActive();
      await store.flush();
      return {};
    }).then((): void => {});
  }

  private success(callbackId: string, pluginId: string, methodName: string, dataJSON: string = '{}', save: boolean = false): string {
    if (lynxUTF8Bytes(dataJSON) > LYNX_RESULT_BYTES - 4096) return this.failure(callbackId, pluginId, methodName, 'RESULT_TOO_LARGE', '结果超过 2 MiB');
    return LynxCapacitorEnvelope.successJSON(callbackId, pluginId, methodName, dataJSON, save);
  }

  private failure(callbackId: string, pluginId: string, methodName: string, code: string, message: string): string {
    return LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, code, message);
  }
}
