import { BusinessError, batteryInfo, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { connection, http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import Want from '@ohos.app.ability.Want';
import vibrator from '@ohos.vibrator';
import { ComponentContent, display, promptAction, uiAppearance, window } from '@kit.ArkUI';
import { UIContext } from '@ohos.arkui.UIContext';
import { i18n } from '@kit.LocalizationKit';
import { sensor } from '@kit.SensorServiceKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { contact } from '@kit.ContactsKit';
import { calendarManager } from '@kit.CalendarKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { accessibility } from '@kit.AccessibilityKit';
import { inputMethod } from '@kit.IMEKit';
import { webview } from '@kit.ArkWeb';
import { LynxContext, LynxModule } from '@lynx/lynx';
import LynxCapacitorCatalog from './LynxCapacitorCatalog';
import LynxCapacitorEnvelope from './LynxCapacitorEnvelope';
import LynxHarmonyAudioCapabilities, { LynxHarmonyAudioResult } from './LynxHarmonyAudioCapabilities';

interface LynxCapacitorListener {
  pluginId: string;
  eventName: string;
}

interface LynxCapacitorSQLiteSpecification {
  readonly: boolean;
  encrypted: boolean;
  version: number;
}

interface LynxCapacitorSQLiteJsonColumn {
  column: string;
  value: string;
}

interface LynxCapacitorSQLiteJsonTable {
  name: string;
  schema: Array<LynxCapacitorSQLiteJsonColumn>;
  indexes?: Array<LynxCapacitorSQLiteJsonIndex>;
  triggers?: Array<LynxCapacitorSQLiteJsonTrigger>;
  values: Array<Array<relationalStore.ValueType>>;
}

interface LynxCapacitorSQLiteJsonView {
  name: string;
  value: string;
}

interface LynxCapacitorSQLiteJsonIndex {
  name: string;
  value: string;
  mode?: string;
  sql?: string;
}

interface LynxCapacitorSQLiteJsonTrigger {
  name: string;
  timeevent: string;
  condition?: string;
  logic: string;
  sql?: string;
}

interface LynxCapacitorHttpMultipartBody {
  body: ArrayBuffer;
  contentType: string;
}

interface LynxCapacitorSQLiteJsonExport {
  database: string;
  version: number;
  encrypted: boolean;
  mode: string;
  tables: Array<LynxCapacitorSQLiteJsonTable>;
  views?: Array<LynxCapacitorSQLiteJsonView>;
  overwrite?: boolean;
}

interface LynxCapacitorSQLiteTableInfo {
  columns: Array<string>;
  primaryKeyIndex: number;
  sqlDeletedIndex: number;
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

interface LynxCapacitorFileTransferTask {
  operationId: string;
  callbackId: string;
  request: http.HttpRequest;
  callback: (resultJSON: string) => void;
  status: LynxCapacitorFileTransferStatus;
  completed: boolean;
  cancelled: boolean;
}

interface LynxCapacitorFileTransferStatus {
  operationId: string;
  state: string;
  bytes?: number;
  total?: number | null;
  path?: string;
  uri?: string;
  responseCode?: number;
  cancelled?: boolean;
  code?: string;
  message?: string;
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

interface LynxCapacitorCameraResult {
  format: string;
  path: string;
  webPath: string;
  saved?: boolean;
  base64String?: string;
  dataUrl?: string;
}

interface LynxCapacitorMediaMetadata {
  format: string;
  size?: number;
}

interface LynxCapacitorMediaResult {
  type: number;
  uri: string;
  saved: boolean;
  webPath: string;
  thumbnail?: string;
  metadata?: LynxCapacitorMediaMetadata;
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

interface LynxCapacitorActionMenuOptions {
  title: string;
  buttons: [promptAction.Button, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?];
}

interface LynxCapacitorPromptDialogParams {
  title: string;
  message: string;
  placeholder: string;
  initialValue: string;
  cancelText: string;
  confirmText: string;
  onConfirm: (value: string) => void;
  onCancel: () => void;
}

@CustomDialog
struct LynxCapacitorPromptDialog {
  controller: CustomDialogController;
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop placeholder: string = '';
  @Prop initialValue: string = '';
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
      TextInput({ placeholder: this.placeholder, text: this.inputValue })
        .width('100%')
        .height(44)
        .margin({ top: 20 })
        .onChange((value: string): void => {
          this.inputValue = value;
        });
      Row() {
        Text(this.cancelText)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .height(48)
          .onClick((): void => {
            this.onCancel();
            this.controller.close();
          });
        Text(this.confirmText)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .height(48)
          .onClick((): void => {
            this.onConfirm(this.inputValue);
            this.controller.close();
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
 * Web 仍然是 ArkUI 原生 Web 组件，Lynx 页面只通过 LynxCapacitorModule 调用；
 * 不把 Web 注册成 Lynx UI 元素，也不依赖 Autolink 或 WebView transport。
 */
@CustomDialog
struct LynxCapacitorWebViewDialog {
  controller: CustomDialogController;
  @Prop url: string = '';
  @Prop headers: Array<webview.WebHeader> = [];
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
          .onClick((): void => this.controller.close());
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
    onPageLoaded: params.onPageLoaded,
    onTitle: params.onTitle,
    onError: params.onError,
  });
}

interface LynxCapacitorSplashDialogParams {
  backgroundColor: string;
}

/** Harmony SplashScreen 的显式内容层 overlay；冷启动系统 splash 仍由 Ability 管理。 */
@CustomDialog
struct LynxCapacitorSplashDialog {
  controller: CustomDialogController;
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
export class LynxCapacitorModule extends LynxModule {
  /** Lynx 4.0 NativeModules 对这三个无副作用查询使用同步返回语义。 */
  public static syncMethods: Array<string> = ['getPlatform', 'getPluginHeaders', 'getCapabilityStatus'];
  private static readonly deviceIdentifierKey: string = '__lynx_capacitor_device_identifier';
  private static readonly preferenceKeysKey: string = '__lynx_capacitor_preference_keys';
  private static readonly localNotificationIdsKey: string = '__lynx_capacitor_local_notification_ids';
  private static readonly localNotificationChannelsKey: string = '__lynx_capacitor_local_notification_channels';
  private static instances: Array<LynxCapacitorModule> = [];
  private static contextInstances: Map<LynxContext, LynxCapacitorModule> = new Map();
  private static launchUrl: string = '';
  private static appIsActive: boolean = true;
  private static hostContext: common.UIAbilityContext | null = null;
  private dataPreferences: preferences.Preferences | null = null;
  private preferenceKeys: string[] = [];
  private keepAwake: boolean = false;
  private privacyScreen: boolean = false;
  private statusBarVisible: boolean = true;
  private statusBarOverlays: boolean = false;
  private statusBarStyle: string = 'DEFAULT';
  private statusBarColor: string = '';
  private listeners: Map<string, LynxCapacitorListener> = new Map();
  private networkConnection: connection.NetConnection | null = null;
  private networkCallback: ((info: connection.NetCapabilityInfo) => void) | null = null;
  private motionAccelerationCallback: ((event: sensor.AccelerometerResponse) => void) | null = null;
  private motionGyroscopeCallback: ((event: sensor.GyroscopeResponse) => void) | null = null;
  private motionListening: boolean = false;
  private lastMotionTimestamp: number = 0;
  private rotationRate: LynxCapacitorRotationRate = { alpha: 0, beta: 0, gamma: 0 };
  private geolocationWatchCallbacks: Map<string, (resultJSON: string) => void> = new Map();
  private geolocationLocationCallback: ((location: geoLocationManager.Location) => void) | null = null;
  private localNotificationIds: Map<number, LynxCapacitorLocalNotification> = new Map();
  private localNotificationChannels: Map<string, LynxCapacitorNotificationChannel> = new Map();
  private reminderStateCallback: ((states: Array<reminderAgentManager.ReminderState>) => void) | null = null;
  private fileTransferTasks: Map<string, LynxCapacitorFileTransferTask> = new Map();
  private sqliteStores: Map<string, relationalStore.RdbStore> = new Map();
  private sqliteSpecifications: Map<string, LynxCapacitorSQLiteSpecification> = new Map();
  private sqliteTransactions: Set<string> = new Set();
  private sqliteUpgradeStatements: Map<string, Map<number, Array<string>>> = new Map();
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

  constructor(context: LynxContext, param?: Object) {
    super(context, param);
    LynxCapacitorModule.instances.push(this);
    LynxCapacitorModule.contextInstances.set(context, this);
    this.initializePreferences();
  }

  /** 页面销毁时释放系统 observer、传感器和位置 watcher，避免残留回调持有 LynxContext。 */
  public destroy(): void {
    const instanceIndex = LynxCapacitorModule.instances.indexOf(this);
    if (instanceIndex >= 0) LynxCapacitorModule.instances.splice(instanceIndex, 1);
    LynxCapacitorModule.contextInstances.delete(this.context);
    const browserContent = this.browserDialogContent;
    const browserUIContext = this.browserDialogUIContext;
    this.browserDialogContent = null;
    this.browserDialogUIContext = null;
    if (browserContent !== null && browserUIContext !== null) {
      try {
        browserUIContext.getPromptAction().closeCustomDialog(browserContent).catch((error: Object): void => {
          console.error('LynxCapacitorModule', `InAppBrowser close during destroy failed: ${String(error)}`);
        });
      } catch (error) {
        console.error('LynxCapacitorModule', `InAppBrowser close during destroy failed: ${String(error)}`);
      }
    }
    const splashContent = this.splashDialogContent;
    const splashUIContext = this.splashDialogUIContext;
    this.splashDialogContent = null;
    this.splashDialogUIContext = null;
    if (splashContent !== null && splashUIContext !== null) {
      try {
        splashUIContext.getPromptAction().closeCustomDialog(splashContent).catch((error: Object): void => {
          console.error('LynxCapacitorModule', `SplashScreen close during destroy failed: ${String(error)}`);
        });
      } catch (error) {
        console.error('LynxCapacitorModule', `SplashScreen close during destroy failed: ${String(error)}`);
      }
    }
    this.stopNetworkListener();
    this.stopMotionListeners();
    this.stopReminderStateListener();
    this.stopScreenReaderListener();
    this.stopScreenOrientationListener();
    this.toastGeneration += 1;
    this.closeActiveToast();
    // Audio session 以 Ability 为生命周期边界；只有最后一个 Lynx Module 离开时才释放，
    // 避免一个被覆盖的页面销毁另一个仍在前台页面的录音/播放。
    if (LynxCapacitorModule.instances.length === 0) LynxHarmonyAudioCapabilities.release();
    this.geolocationWatchCallbacks.clear();
    this.stopGeolocationWatch('');
    this.fileTransferTasks.forEach((task: LynxCapacitorFileTransferTask): void => {
      if (task.completed) return;
      task.cancelled = true;
      task.status = { operationId: task.operationId, state: 'failed', code: 'ACTIVITY_DESTROYED' } as LynxCapacitorFileTransferStatus;
      try { task.request.destroy(); } catch (error) { console.error('LynxCapacitorModule', `FileTransfer destroy failed: ${String(error)}`); }
      task.completed = true;
      task.callback(this.failure(task.callbackId, 'FileTransfer', 'downloadFile', 'ACTIVITY_DESTROYED', 'File transfer was cancelled because the Module was destroyed'));
    });
    this.fileTransferTasks.clear();
    this.sqliteStores.forEach((store: relationalStore.RdbStore) => {
      try { store.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite close failed: ${String(error)}`); }
    });
    this.sqliteStores.clear();
    this.sqliteTransactions.clear();
    this.listeners.clear();
  }

  /** Shell 在真正移除 LynxView 时显式释放对应 Module，避免依赖运行时的隐式销毁回调。 */
  public static destroyForContext(context: LynxContext | null): void {
    if (context === null) return;
    LynxCapacitorModule.contextInstances.get(context)?.destroy();
  }

  /** Ability 在创建 LynxView 前注入真实 UIAbilityContext，供系统 Picker/Provider 使用。 */
  public static setHostContext(context: common.UIAbilityContext): void {
    LynxCapacitorModule.hostContext = context;
  }

  public static clearHostContext(context: common.UIAbilityContext): void {
    if (LynxCapacitorModule.hostContext === context) LynxCapacitorModule.hostContext = null;
  }

  /**
   * Host push providers call these explicit entry points after receiving a token or payload.
   * The Module never discovers or initializes a vendor push provider by itself.
   */
  public static emitPushRegistration(token: string): void {
    if (token.length === 0) return;
    LynxCapacitorModule.emitPushEvent('registration', JSON.stringify({ value: token }));
  }

  public static emitPushRegistrationError(message: string): void {
    LynxCapacitorModule.emitPushEvent('registrationError', JSON.stringify({ error: message }));
  }

  public static emitPushNotification(data: Record<string, Object>): void {
    LynxCapacitorModule.emitPushEvent('pushNotificationReceived', JSON.stringify(data));
  }

  private static emitPushEvent(eventName: string, dataJSON: string): void {
    LynxCapacitorModule.instances.slice().forEach((module: LynxCapacitorModule) => {
      module.emitEvent('PushNotifications', eventName, dataJSON);
    });
  }

  /** Host Ability forwards the initial deep link and subsequent Want URL events explicitly. */
  public static setLaunchUrl(url: string): void {
    LynxCapacitorModule.launchUrl = url;
  }

  public static emitAppUrlOpen(url: string): void {
    const value = url.trim();
    if (value.length === 0) return;
    LynxCapacitorModule.emitAppEvent('appUrlOpen', JSON.stringify({ url: value }));
  }

  public static emitAppState(isActive: boolean): void {
    LynxCapacitorModule.appIsActive = isActive;
    LynxCapacitorModule.emitAppEvent('appStateChange', JSON.stringify({ isActive: isActive }));
    LynxCapacitorModule.emitAppEvent(isActive ? 'resume' : 'pause', '{}');
  }

  /** LynxContainer 在系统返回回调中调用；只有页面显式订阅且 handler enabled 才消费返回。 */
  public static dispatchBackButton(): boolean {
    for (let index = LynxCapacitorModule.instances.length - 1; index >= 0; index -= 1) {
      const module = LynxCapacitorModule.instances[index];
      if (module !== undefined && module.backButtonHandlerEnabled && module.hasPluginListeners('App', 'backButton')) {
        module.emitEvent('App', 'backButton', '{"canGoBack":false}');
        return true;
      }
    }
    return false;
  }

  private static emitAppEvent(eventName: string, dataJSON: string): void {
    LynxCapacitorModule.instances.slice().forEach((module: LynxCapacitorModule) => {
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
    return LynxCapacitorCatalog.status();
  }

  public handleCall(payload: string, callback: (resultJSON: string) => void): void {
    let root: Record<string, Object>;
    try {
      const parsed = JSON.parse(payload) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('payload must be a JSON object');
      root = parsed as Record<string, Object>;
    } catch (error) {
      callback(this.failure('-1', '', '', 'INVALID_PAYLOAD', `Invalid Capacitor call payload: ${error}`));
      return;
    }
    const callbackId = String(root['callbackId'] ?? '-1');
    const pluginId = String(root['pluginId'] ?? '');
    const methodName = String(root['methodName'] ?? '');
    let options: Record<string, Object>;
    if (root['options'] === null || root['options'] === undefined) {
      options = JSON.parse('{}') as Record<string, Object>;
    } else if (typeof root['options'] !== 'object' || Array.isArray(root['options'])) {
      callback(this.failure(callbackId, pluginId, methodName, 'INVALID_ARGUMENT', 'options must be a JSON object'));
      return;
    } else {
      options = root['options'] as Record<string, Object>;
    }

    // 先做 Android 核心目录 gate。这样目录外的 Harmony 扩展、旧别名和通用
    // listener 都不能绕过协议直接得到假成功。
    if (!LynxCapacitorCatalog.has(pluginId, methodName)) {
      callback(this.failure(callbackId, pluginId, methodName, 'UNIMPLEMENTED', `${pluginId}.${methodName} is not declared by the Android NativeModule contract`));
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
    if (pluginId === 'Geolocation' && methodName === 'watchPosition') {
      this.startGeolocationWatch(callbackId, options, callback);
      return;
    }
    if (pluginId === 'Geolocation' && methodName === 'clearWatch') {
      this.stopGeolocationWatch(String(options['id'] ?? ''));
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
        this.handleBiometrics(callbackId, methodName, callback);
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
        this.handleLocalNotifications(callbackId, methodName, options, callback);
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
        this.handleGeolocation(callbackId, methodName, callback);
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
    this.listeners.forEach((listener: LynxCapacitorListener, callbackId: string) => {
      if (listener.pluginId !== pluginId || listener.eventName !== eventName) return;
      this.context.sendGlobalEvent('lynx-capacitor-result', [this.success(callbackId, pluginId, 'addListener', dataJSON, true)]);
    });
  }

  /** NetworkKit 的文件传输进度统一转换为 Capacitor 风格的插件级 retained event。 */
  private emitTransferProgress(pluginId: string, type: string, url: string, bytes: number, contentLength: number, operationId: string = ''): void {
    const total = Number(contentLength);
    const progress: Record<string, Object> = {};
    progress['type'] = type;
    progress['url'] = url;
    progress['bytes'] = Number(bytes);
    progress['contentLength'] = total;
    progress['lengthComputable'] = total >= 0;
    if (operationId.length > 0) progress['operationId'] = operationId;
    const dataJSON = JSON.stringify(progress);
    // FileTransfer 的 Android 基线通过 runtime eventSender 发送插件级 retained progress，
    // 不依赖目录外的 addListener；Harmony 同时保留 Module listener 路径供内部宿主使用。
    this.context.sendGlobalEvent('lynx-capacitor-result', [JSON.stringify({
      pluginId: pluginId,
      methodName: 'progress',
      eventName: 'progress',
      save: true,
      data: progress,
    })]);
    this.emitEvent(pluginId, 'progress', dataJSON);
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
          console.error('LynxCapacitorModule', `Network capability query after netAvailable failed: ${String(error)}`);
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
        if (error) console.error('LynxCapacitorModule', `Network listener registration failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxCapacitorModule', `Network listener setup failed: ${String(error)}`);
      this.networkConnection = null;
      this.networkCallback = null;
    }
  }

  private stopNetworkListener(): void {
    const monitor = this.networkConnection;
    if (monitor === null) return;
    try {
      monitor.unregister((error: BusinessError<void>, _data: void): void => {
        if (error) console.error('LynxCapacitorModule', `Network listener removal failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxCapacitorModule', `Network listener removal failed: ${String(error)}`);
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
      console.error('LynxCapacitorModule', `Motion listener setup failed: ${String(error)}`);
      this.stopMotionListeners();
    }
  }

  private stopMotionListeners(): void {
    try {
      if (this.motionAccelerationCallback !== null) sensor.off(sensor.SensorId.ACCELEROMETER, this.motionAccelerationCallback);
      if (this.motionGyroscopeCallback !== null) sensor.off(sensor.SensorId.GYROSCOPE, this.motionGyroscopeCallback);
    } catch (error) {
      console.error('LynxCapacitorModule', `Motion listener removal failed: ${String(error)}`);
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
        console.error('LynxCapacitorModule', `Reminder state listener setup failed: ${String(error)}`);
        this.reminderStateCallback = null;
      });
    } catch (error) {
      console.error('LynxCapacitorModule', `Reminder state listener setup failed: ${String(error)}`);
      this.reminderStateCallback = null;
    }
  }

  private stopReminderStateListener(): void {
    const callback = this.reminderStateCallback;
    if (callback === null) return;
    this.reminderStateCallback = null;
    try {
      reminderAgentManager.unsubscribeReminderState(callback).catch((error: Object) => {
        console.error('LynxCapacitorModule', `Reminder state listener removal failed: ${String(error)}`);
      });
    } catch (error) {
      console.error('LynxCapacitorModule', `Reminder state listener removal failed: ${String(error)}`);
    }
  }

  private handleActionSheet(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName !== 'showActions') {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'UNIMPLEMENTED', 'ActionSheet.' + methodName + ' is not implemented'));
      return;
    }
    const rawOptions = options['options'];
    const values: Array<Object> = Array.isArray(rawOptions) ? rawOptions : [];
    const buttons: Array<promptAction.Button> = [];
    values.forEach((value: Object) => {
      const item = value as Record<string, Object>;
      buttons.push({
        text: String(item['title'] ?? ''),
        color: String(item['color'] ?? '#000000'),
      });
    });
    if (buttons.length === 0) {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'INVALID_ARGUMENT', 'options must contain at least one action'));
      return;
    }
    if (buttons.length > 6) {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'INVALID_ARGUMENT', 'Harmony ActionSheet supports at most six actions'));
      return;
    }
    try {
      const first = buttons[0];
      const menuOptions: LynxCapacitorActionMenuOptions = {
        title: String(options['title'] ?? ''),
        buttons: [first, buttons[1], buttons[2], buttons[3], buttons[4], buttons[5]] as [promptAction.Button, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?],
      };
      promptAction.showActionMenu(menuOptions).then((result: promptAction.ActionMenuSuccessResponse) => {
        callback(this.success(callbackId, 'ActionSheet', methodName, '{"index":' + String(result.index) + '}'));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'ActionSheet', methodName, 'UNAVAILABLE', 'ActionSheet operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'ActionSheet', methodName, 'UNAVAILABLE', 'ActionSheet operation failed: ' + String(error)));
    }
  }

  private handleDialog(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'prompt') {
      this.handleDialogPrompt(callbackId, options, callback);
      return;
    }
    if (methodName !== 'alert' && methodName !== 'confirm') {
      callback(this.failure(callbackId, 'Dialog', methodName, 'UNIMPLEMENTED', 'Dialog.' + methodName + ' is not implemented'));
      return;
    }
    const buttons: Array<promptAction.Button> = methodName === 'confirm' ? [
      { text: String(options['cancelButtonTitle'] ?? 'Cancel'), color: '#000000' },
      { text: String(options['okButtonTitle'] ?? 'OK'), color: '#000000', primary: true },
    ] : [{ text: String(options['buttonTitle'] ?? 'OK'), color: '#000000', primary: true }];
    try {
      promptAction.showDialog({
        title: String(options['title'] ?? ''),
        message: String(options['message'] ?? ''),
        buttons: buttons,
      }).then((result: promptAction.ShowDialogSuccessResponse) => {
        const data = methodName === 'confirm' ? '{"value":' + String(result.index === 1) + '}' : '{}';
        callback(this.success(callbackId, 'Dialog', methodName, data));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'Dialog', methodName, 'UNAVAILABLE', 'Dialog operation failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'Dialog', methodName, 'UNAVAILABLE', 'Dialog operation failed: ' + String(error)));
    }
  }

  /** 使用宿主 UIContext 创建真正的文本输入 Dialog；所有退出路径只完成一次 callback。 */
  private handleDialogPrompt(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    let completed = false;
    const complete = (value: string, cancelled: boolean): void => {
      if (completed) return;
      completed = true;
      callback(this.success(callbackId, 'Dialog', 'prompt', JSON.stringify({ value: value, cancelled: cancelled })));
    };
    const fail = (error: Object): void => {
      if (completed) return;
      completed = true;
      callback(this.failure(callbackId, 'Dialog', 'prompt', 'UNAVAILABLE', 'Dialog.prompt failed: ' + String(error)));
    };
    try {
      window.getLastWindow(getContext()).then((lastWindow: window.Window): void => {
        const uiContext: UIContext = lastWindow.getUIContext();
        const params: LynxCapacitorPromptDialogParams = {
          title: String(options['title'] ?? ''),
          message: String(options['message'] ?? ''),
          placeholder: String(options['placeholder'] ?? ''),
          initialValue: String(options['value'] ?? options['input'] ?? ''),
          cancelText: String(options['cancelButtonTitle'] ?? 'Cancel'),
          confirmText: String(options['okButtonTitle'] ?? 'OK'),
          onConfirm: (value: string): void => complete(value, false),
          onCancel: (): void => complete('', true),
        };
        const contentNode = new ComponentContent(uiContext, wrapBuilder(LynxCapacitorPromptDialogBuilder), params);
        const dialogOptions: promptAction.BaseDialogOptions = {
          alignment: DialogAlignment.Center,
          autoCancel: true,
          maskColor: 'rgba(0, 0, 0, 0.6)',
          onDidDisappear: (): void => complete('', true),
        };
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).catch((error: Object): void => fail(error));
      }).catch((error: Object): void => fail(error));
    } catch (error) {
      fail(error);
    }
  }

  private handleShare(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'canShare') {
      const text = String(options['text'] ?? '');
      const url = String(options['url'] ?? '');
      callback(this.success(callbackId, 'Share', methodName, '{"value":' + String(text.length > 0 || url.length > 0) + '}'));
      return;
    }
    if (methodName !== 'share') {
      callback(this.failure(callbackId, 'Share', methodName, 'UNIMPLEMENTED', 'Share.' + methodName + ' is not implemented'));
      return;
    }
    const text = String(options['text'] ?? '');
    const url = String(options['url'] ?? '');
    if (text.length === 0 && url.length === 0) {
      callback(this.failure(callbackId, 'Share', methodName, 'INVALID_ARGUMENT', 'text or url is required'));
      return;
    }
    try {
      const context = getContext() as common.UIAbilityContext;
      const parameters: Record<string, Object> = {};
      if (String(options['title'] ?? '').length > 0) parameters['ohos.extra.param.key.contentTitle'] = String(options['title']);
      if (text.length > 0) parameters['ohos.extra.param.key.shareAbstract'] = text;
      if (url.length > 0) parameters['ohos.extra.param.key.shareUrl'] = url;
      const want: Want = {
        action: 'ohos.want.action.sendData',
        type: 'text/plain',
        parameters: parameters,
      };
      context.startAbility(want).then(() => {
        callback(this.success(callbackId, 'Share', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'Share', methodName, 'UNAVAILABLE', 'Unable to share content: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'Share', methodName, 'UNAVAILABLE', 'Unable to share content: ' + String(error)));
    }
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => lastWindow.setWindowPrivacyMode(value)).then(() => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => {
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
      const context = getContext() as common.UIAbilityContext;
      scanBarcode.startScanForResult(context, scanOptions).then((result: scanBarcode.ScanResult): void => {
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

  private handleCamera(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    if (methodName === 'pickLimitedLibraryPhotos' || methodName === 'getLimitedLibraryPhotos') {
      callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Camera.' + methodName + ' is not supported on HarmonyOS'));
      return;
    }
    if (methodName === 'checkPermissions') {
      callback(this.success(callbackId, 'Camera', methodName, '{"camera":' + JSON.stringify(this.cameraPermissionState()) + ',"photos":"prompt"}'));
      return;
    }
    if (methodName === 'requestPermissions') {
      try {
        const context = this.cameraContext();
        abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.CAMERA']).then(() => {
          callback(this.success(callbackId, 'Camera', methodName, '{"camera":' + JSON.stringify(this.cameraPermissionState()) + ',"photos":"prompt"}'));
        }).catch((error: Object) => callback(this.failure(callbackId, 'Camera', methodName, 'PERMISSION_DENIED', 'Camera permission request failed: ' + String(error))));
      } catch (error) {
        callback(this.failure(callbackId, 'Camera', methodName, 'PERMISSION_DENIED', 'Camera permission request failed: ' + String(error)));
      }
      return;
    }
    const cameraSource = methodName === 'getPhoto' ? String(options['source'] ?? 'PROMPT').trim().toUpperCase() : '';
    if (methodName === 'getPhoto' && cameraSource !== 'CAMERA' && cameraSource !== 'PHOTOS') {
      this.handleCameraPrompt(callbackId, options, callback);
      return;
    }
    if (methodName === 'takePhoto' || methodName === 'recordVideo' || (methodName === 'getPhoto' && cameraSource === 'CAMERA')) {
      if (!permissionsAlreadyGranted && this.cameraPermissionState() !== 'granted') {
        this.ensureHarmonyPermissions(callbackId, 'Camera', methodName, ['ohos.permission.CAMERA'], callback, (): void => {
          this.handleCamera(callbackId, methodName, options, callback, true);
        });
        return;
      }
      const context = this.cameraContext();
      const isFront = String(options['cameraDirection'] ?? options['direction'] ?? '').toLowerCase().indexOf('front') >= 0;
      const cameraPosition = isFront ? camera.CameraPosition.CAMERA_POSITION_FRONT : camera.CameraPosition.CAMERA_POSITION_BACK;
      // HarmonyOS 6.1 的 CameraPicker 运行时会把 new PickerProfile() 返回对象的
      // 属性视为只读；按官方 CameraPicker 示例直接传 object literal，避免
      // profile.cameraPosition/profile.videoDuration 赋值触发未捕获 TypeError 并杀掉 ArkTS 进程。
      let profile: cameraPicker.PickerProfile;
      if (methodName === 'recordVideo') {
        const duration = Number(options['videoDuration'] ?? options['duration'] ?? 60);
        profile = Number.isFinite(duration) && duration > 0
          ? { cameraPosition: cameraPosition, videoDuration: Math.floor(duration) }
          : { cameraPosition: cameraPosition };
      } else {
        profile = { cameraPosition: cameraPosition };
      }
      const mediaType = methodName === 'recordVideo' ? cameraPicker.PickerMediaType.VIDEO : cameraPicker.PickerMediaType.PHOTO;
      this.launchCameraPicker(context, mediaType, profile, callbackId, methodName, options, callback);
      return;
    }
    if (methodName === 'playVideo' || methodName === 'editPhoto' || methodName === 'editURIPhoto') {
      if (methodName === 'playVideo') {
        const uri = String(options['uri'] ?? options['path'] ?? '');
        if (uri.length === 0) {
          callback(this.failure(callbackId, 'Camera', methodName, 'INVALID_ARGUMENT', 'uri is required'));
          return;
        }
        try {
          const context = this.cameraContext();
          const want: Want = { action: 'ohos.want.action.viewData', uri: uri, type: 'video/*' };
          context.startAbility(want).then(() => callback(this.success(callbackId, 'Camera', methodName))).catch((error: Object) => callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Unable to play video: ' + String(error))));
        } catch (error) {
          callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Unable to play video: ' + String(error)));
        }
        return;
      }
      callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Camera playback/editor requires a host-owned media surface'));
      return;
    }
    if (methodName !== 'getPhoto' && methodName !== 'chooseFromGallery' && methodName !== 'pickImages') {
      callback(this.failure(callbackId, 'Camera', methodName, 'UNIMPLEMENTED', 'Camera.' + methodName + ' is not implemented'));
      return;
    }
    const mediaTypeSelection = this.cameraMediaTypeSelection(options);
    const multiple = methodName === 'pickImages' || (methodName === 'chooseFromGallery' && Boolean(options['allowMultipleSelection'] ?? false));
    const selectedType = mediaTypeSelection === 1
      ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE
      : mediaTypeSelection === 2
        ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE
        : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    const requestedLimit = Number(options['limit'] ?? 0);
    const maxSelectNumber = multiple
      ? (Number.isFinite(requestedLimit) && requestedLimit > 0 ? Math.max(1, Math.min(Math.floor(requestedLimit), 50)) : 50)
      : 1;
    const selectOptions: photoAccessHelper.PhotoSelectOptions = {
      MIMEType: selectedType,
      maxSelectNumber: maxSelectNumber,
    };
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      picker.select(selectOptions).then((result: photoAccessHelper.PhotoSelectResult) => {
        const photos: Array<string> = result.photoUris.map((uri: string) => uri);
        const deliver = (photoData: Array<string>): void => {
          if (methodName === 'chooseFromGallery') {
            this.finishCameraGalleryResult(callbackId, methodName, options, photos, photoData, selectedType, callback);
          } else if (multiple) {
            this.finishCameraGalleryResult(callbackId, methodName, options, photos, photoData, selectedType, callback);
          } else if (photoData.length === 0) {
            callback(this.success(callbackId, 'Camera', methodName, '{}'));
          } else if (Boolean(options['saveToGallery'] ?? false)) {
            const isVideo = selectedType === photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE || (selectedType === photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE && this.cameraUriLooksVideo(photos[0]));
            this.saveHarmonyMedia(photos[0], isVideo).then((saved: boolean): void => {
              callback(this.success(callbackId, 'Camera', methodName, this.cameraResultWithSaved(photoData[0], saved)));
            });
          } else {
            callback(this.success(callbackId, 'Camera', methodName, photoData[0]));
          }
        };
        if (methodName === 'chooseFromGallery') {
          Promise.all(photos.map((uri: string): Promise<string> => {
            const isVideo = selectedType === photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE || (selectedType === photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE && this.cameraUriLooksVideo(uri));
            return this.cameraMediaResultJSON(uri, options, isVideo);
          })).then((photoData: Array<string>): void => deliver(photoData)).catch((error: Object) => {
            callback(this.failure(callbackId, 'Camera', methodName, 'IO', 'Camera media result could not be read: ' + String(error)));
          });
        } else {
          deliver(photos.map((uri: string): string => {
            const isVideo = selectedType === photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE || (selectedType === photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE && this.cameraUriLooksVideo(uri));
            return this.cameraMediaJSON(uri, options, isVideo, methodName === 'getPhoto');
          }));
        }
      }).catch((error: Object) => {
        const message = String(error);
        const code = message.toLowerCase().indexOf('cancel') >= 0 ? 'CANCELLED' : 'IO';
        callback(this.failure(callbackId, 'Camera', methodName, code, 'Camera picker failed: ' + message));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Camera picker failed: ' + String(error)));
    }
  }

  /** CameraPicker 是 Promise API；统一用 await 接住运行时的 undefined/异常，禁止裸调用 .then。 */
  private async launchCameraPicker(
    context: common.UIAbilityContext,
    mediaType: cameraPicker.PickerMediaType,
    profile: cameraPicker.PickerProfile,
    callbackId: string,
    methodName: string,
    options: Record<string, Object>,
    callback: (resultJSON: string) => void,
  ): Promise<void> {
    try {
      const result = await cameraPicker.pick(context, [mediaType], profile);
      if (result === undefined || result === null) {
        callback(this.failure(callbackId, 'Camera', methodName, 'UNAVAILABLE', 'Camera picker returned no result; the system camera picker is unavailable on this device'));
        return;
      }
      if (result.resultCode !== 0 || typeof result.resultUri !== 'string' || result.resultUri.length === 0) {
        callback(this.failure(callbackId, 'Camera', methodName, 'CANCELLED', 'Camera picker was cancelled'));
        return;
      }
      const uri = result.resultUri;
      try {
        const isVideo = methodName === 'recordVideo';
        if (methodName === 'getPhoto') {
          const mediaResult = this.cameraMediaJSON(uri, options, isVideo, true);
          if (Boolean(options['saveToGallery'] ?? false)) {
            this.saveHarmonyMedia(uri, isVideo).then((saved: boolean): void => {
              callback(this.success(callbackId, 'Camera', methodName, this.cameraResultWithSaved(mediaResult, saved)));
            });
          } else {
            callback(this.success(callbackId, 'Camera', methodName, mediaResult));
          }
        } else {
          this.cameraMediaResultJSON(uri, options, isVideo).then((mediaResult: string): void => {
            if (Boolean(options['saveToGallery'] ?? false)) {
              this.saveHarmonyMedia(uri, isVideo).then((saved: boolean): void => {
                callback(this.success(callbackId, 'Camera', methodName, this.cameraResultWithSaved(mediaResult, saved)));
              });
            } else {
              callback(this.success(callbackId, 'Camera', methodName, mediaResult));
            }
          }).catch((error: Object) => {
            callback(this.failure(callbackId, 'Camera', methodName, 'IO', 'Camera media result could not be read: ' + String(error)));
          });
        }
      } catch (error) {
        callback(this.failure(callbackId, 'Camera', methodName, 'IO', 'Camera media result could not be read: ' + String(error)));
      }
    } catch (error) {
      const message = String(error);
      callback(this.failure(callbackId, 'Camera', methodName, message.toLowerCase().indexOf('cancel') >= 0 ? 'CANCELLED' : 'UNAVAILABLE', 'Camera picker failed: ' + message));
    }
  }

  /** 复用系统 promptAction，在旧版 getPhoto 的默认来源选择和显式 source 之间保持一致。 */
  private handleCameraPrompt(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const menuOptions: LynxCapacitorActionMenuOptions = {
        title: String(options['promptLabelHeader'] ?? 'Photo'),
        buttons: [
          { text: String(options['promptLabelPhoto'] ?? 'From Photos'), color: '#000000' },
          { text: String(options['promptLabelPicture'] ?? 'Take Picture'), color: '#000000' },
        ] as [promptAction.Button, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?],
      };
      promptAction.showActionMenu(menuOptions).then((result: promptAction.ActionMenuSuccessResponse) => {
        const nextOptions: Record<string, Object> = {};
        Object.keys(options).forEach((key: string): void => { nextOptions[key] = options[key]; });
        nextOptions['source'] = result.index === 0 ? 'PHOTOS' : 'CAMERA';
        this.handleCamera(callbackId, 'getPhoto', nextOptions, callback);
      }).catch((error: Object) => {
        const message = String(error);
        const code = message.toLowerCase().indexOf('cancel') >= 0 ? 'CANCELLED' : 'UNAVAILABLE';
        callback(this.failure(callbackId, 'Camera', 'getPhoto', code, 'Camera prompt failed: ' + message));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'Camera', 'getPhoto', 'UNAVAILABLE', 'Camera prompt failed: ' + String(error)));
    }
  }

  private cameraPermissionState(): string {
    try {
      const status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus('ohos.permission.CAMERA');
      return status === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : status === abilityAccessCtrl.PermissionStatus.DENIED ? 'denied' : 'prompt';
    } catch (error) {
      console.error('LynxCapacitorModule', 'Camera permission status failed: ' + String(error));
      return 'prompt';
    }
  }

  /** NativeModule 内的全局 getContext 不保证是 UIAbilityContext；优先使用 Ability 注入值。 */
  private cameraContext(): common.UIAbilityContext {
    if (LynxCapacitorModule.hostContext !== null) return LynxCapacitorModule.hostContext;
    return getContext(this) as common.UIAbilityContext;
  }

  /** 将 Camera 8.2 的数字枚举兼容为 Harmony PhotoViewPicker 的媒体类型。 */
  private cameraMediaTypeSelection(options: Record<string, Object>): number {
    const rawValue = options['mediaType'];
    const numericValue = Number(rawValue);
    if (Number.isFinite(numericValue) && Math.floor(numericValue) === numericValue && numericValue >= 0 && numericValue <= 2) {
      return numericValue;
    }
    switch (String(rawValue ?? '').trim().toLowerCase()) {
      case 'video':
      case 'videos':
        return 1;
      case 'all':
      case 'image_video':
      case 'image-video':
      case 'photo_video':
      case 'photo-video':
        return 2;
      default:
        return 0;
    }
  }

  private cameraUriLooksVideo(uri: string): boolean {
    const format = uri.substring(uri.lastIndexOf('/') + 1).toLowerCase().split('?')[0];
    return format.endsWith('.3gp') || format.endsWith('.avi') || format.endsWith('.m4v') || format.endsWith('.mkv') || format.endsWith('.mov') || format.endsWith('.mp4') || format.endsWith('.webm');
  }

  private finishCameraGalleryResult(callbackId: string, methodName: string, options: Record<string, Object>, photos: Array<string>, photoData: Array<string>, selectedType: string, callback: (resultJSON: string) => void): void {
    const finish = (values: Array<string>): void => {
      if (methodName === 'chooseFromGallery') {
        callback(this.success(callbackId, 'Camera', methodName, '{"results":[' + values.join(',') + ']}'));
      } else {
        callback(this.success(callbackId, 'Camera', methodName, '{"photos":[' + values.join(',') + ']}'));
      }
    };
    if (!Boolean(options['saveToGallery'] ?? false)) {
      finish(photoData);
      return;
    }
    const isVideos: Array<boolean> = photos.map((uri: string): boolean => selectedType === photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE || (selectedType === photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE && this.cameraUriLooksVideo(uri)));
    this.saveHarmonyMediaList(photos, isVideos).then((saved: Array<boolean>): void => {
      const values = photoData.map((value: string, index: number): string => this.cameraResultWithSaved(value, saved[index] ?? false));
      finish(values);
    });
  }

  private async saveHarmonyMediaList(uris: Array<string>, isVideos: Array<boolean>): Promise<Array<boolean>> {
    const saved: Array<boolean> = [];
    for (let index = 0; index < uris.length; index++) {
      saved.push(await this.saveHarmonyMedia(uris[index], isVideos[index] ?? false));
    }
    return saved;
  }

  /** 通过 PhotoAccessHelper 的系统保存面板写入媒体库；用户取消或 provider 失败只返回 false。 */
  private async saveHarmonyMedia(uri: string, isVideo: boolean): Promise<boolean> {
    try {
      const context = this.cameraContext();
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: 'LynxCapacitor',
        fileNameExtension: isVideo ? 'mp4' : 'jpg',
        photoType: isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
      };
      const savedUris: Array<string> = await helper.showAssetsCreationDialog([uri], [config]);
      return savedUris.length > 0;
    } catch (error) {
      console.error('LynxCapacitorModule', 'Camera saveToGallery failed: ' + String(error));
      return false;
    }
  }

  private cameraResultWithSaved(resultJSON: string, saved: boolean): string {
    const result = JSON.parse(resultJSON) as Record<string, Object>;
    result['saved'] = saved;
    return JSON.stringify(result);
  }

  /** 新版 chooseFromGallery 的固定 MediaResult 外壳；旧版 Photo 结果继续走 cameraMediaJSON。 */
  private async cameraMediaResultJSON(uri: string, options: Record<string, Object>, isVideo: boolean): Promise<string> {
    const name = uri.substring(uri.lastIndexOf('/') + 1);
    const format = name.indexOf('.') >= 0 ? name.substring(name.lastIndexOf('.') + 1).split('?')[0] : (isVideo ? 'mp4' : 'jpeg');
    const result: LynxCapacitorMediaResult = {
      type: isVideo ? 1 : 0,
      uri: uri,
      saved: false,
      webPath: uri,
    };
    if (!isVideo) {
      const thumbnail = await this.cameraThumbnail(uri);
      if (thumbnail !== undefined) result.thumbnail = thumbnail;
    }
    if (Boolean(options['includeMetadata'] ?? false)) {
      const metadata: LynxCapacitorMediaMetadata = { format: format };
      try {
        metadata.size = Number(fileIo.statSync(uri).size);
      } catch (_) {
        // Provider 不一定允许 stat；按官方约定保留可用的空 metadata 字段。
      }
      result.metadata = metadata;
    }
    return JSON.stringify(result);
  }

  private async cameraThumbnail(uri: string): Promise<string | undefined> {
    if (this.cameraUriLooksVideo(uri)) return undefined;
    try {
      const source = image.createImageSource(uri);
      try {
        const info = await source.getImageInfo();
        const width = Number(info.size.width);
        const height = Number(info.size.height);
        if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return undefined;
        const ratio = Math.min(1, 256 / Math.max(width, height));
        const pixelMap = await source.createPixelMap({
          desiredSize: { width: Math.max(1, Math.floor(width * ratio)), height: Math.max(1, Math.floor(height * ratio)) },
        });
        try {
          const packer = image.createImagePacker();
          try {
            const buffer = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 80 });
            return new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
          } finally {
            try { await packer.release(); } catch (_) {}
          }
        } finally {
          try { await pixelMap.release(); } catch (_) {}
        }
      } finally {
        try { await source.release(); } catch (_) {}
      }
    } catch (error) {
      console.error('LynxCapacitorModule', 'Camera thumbnail failed: ' + String(error));
      return undefined;
    }
  }

  /** 将 Harmony 媒体 URI 转换为 Capacitor Camera 的 resultType 结果。 */
  private cameraMediaJSON(uri: string, options: Record<string, Object>, isVideo: boolean, defaultBase64: boolean = false): string {
    const name = uri.substring(uri.lastIndexOf('/') + 1);
    const format = name.indexOf('.') >= 0 ? name.substring(name.lastIndexOf('.') + 1).split('?')[0] : (isVideo ? 'mp4' : 'jpeg');
    const result: LynxCapacitorCameraResult = { format: format, path: uri, webPath: uri, saved: false };
    const resultType = String(options['resultType'] ?? (defaultBase64 ? 'base64' : '')).toLowerCase().replace(/_/g, '');
    if (resultType === 'base64' || resultType === 'dataurl') {
      const stat = fileIo.statSync(uri);
      if (Number(stat.size) > 20 * 1024 * 1024) throw new Error('Camera media result exceeds 20 MB');
      const binary = this.readBinaryFile(uri);
      const encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(binary));
      if (resultType === 'base64') result.base64String = encoded;
      else result.dataUrl = `data:${isVideo ? 'video' : 'image'}/${format};base64,${encoded}`;
    }
    return JSON.stringify(result);
  }

  /**
   * Harmony provider 的方法级隐式权限 gate。
   * 只有系统回调确认所有缺失权限已授予后，才继续执行 Contacts/Calendar 操作。
   */
  private ensureHarmonyPermissions(
    callbackId: string,
    pluginId: string,
    methodName: string,
    permissions: Array<Permissions>,
    callback: (resultJSON: string) => void,
    continuation: () => void
  ): void {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const missing = permissions.filter((permission: Permissions) => {
        return manager.getSelfPermissionStatus(permission) !== abilityAccessCtrl.PermissionStatus.GRANTED;
      });
      if (missing.length === 0) {
        continuation();
        return;
      }
      manager.requestPermissionsFromUser(this.cameraContext(), missing).then(() => {
        const denied = missing.filter((permission: Permissions) => {
          return manager.getSelfPermissionStatus(permission) !== abilityAccessCtrl.PermissionStatus.GRANTED;
        });
        if (denied.length > 0) {
          callback(this.failure(callbackId, pluginId, methodName, 'PERMISSION_DENIED', `${pluginId}.${methodName} permission denied: ${denied.join(',')}`));
          return;
        }
        continuation();
      }).catch((error: Object) => {
        callback(this.failure(callbackId, pluginId, methodName, 'PERMISSION_DENIED', `${pluginId}.${methodName} permission request failed: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', `${pluginId}.${methodName} permission check failed: ${String(error)}`));
    }
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
      console.error('LynxCapacitorModule', `Contacts permission status failed: ${String(error)}`);
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
    const context = getContext() as common.UIAbilityContext;
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
        abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, requested).then(() => {
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
            callback(this.success(callbackId, 'Contacts', methodName, this.contactJSON(value, id)));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        }
        case 'find': {
          const filter = String(options['filter'] ?? '');
          contact.queryContacts(context).then((values: Array<contact.Contact>) => {
            const filtered = filter.length === 0 ? values : values.filter((value: contact.Contact) => {
              return String(value.id ?? '') === filter || this.contactDisplayName(value).indexOf(filter) >= 0;
            });
            callback(this.success(callbackId, 'Contacts', methodName, '{"contacts":[' + filtered.map((value: contact.Contact) => this.contactJSON(value)).join(',') + ']}'));
          }).catch((error: Object) => callback(this.contactsFailure(callbackId, methodName, error)));
          return;
        }
        case 'pickContact':
          contact.selectContacts({ isMultiSelect: false }).then((values: Array<contact.Contact>) => {
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
          keyPromise.then((key: string) => contact.deleteContact(context, key)).then(() => {
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
      phoneNumbers: value.phoneNumbers ?? [],
      emails: value.emails ?? [],
    });
  }

  private contactsFailure(callbackId: string, methodName: string, error: Object): string {
    const message = 'Contacts.' + methodName + ' failed: ' + String(error);
    const code = String(error).indexOf('201') >= 0 ? 'PERMISSION_DENIED' : 'UNAVAILABLE';
    return this.failure(callbackId, 'Contacts', methodName, code, message);
  }

  /** 使用 Harmony CalendarKit 对齐 Capacitor Calendar 的账户、事件和权限操作。 */
  private handleCalendar(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    const context = getContext() as common.UIAbilityContext;
    try {
      if (methodName === 'checkPermissions') {
        callback(this.success(callbackId, 'Calendar', methodName, this.calendarPermissionJSON()));
        return;
      }
      if (methodName === 'requestPermissions') {
        abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']).then(() => {
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
            const target = values.find((value: calendarManager.Calendar) => value.id === requestedId || (requestedName.length > 0 && this.calendarName(value) === requestedName)) ?? values[0];
            if (target === undefined) throw new Error('No calendar is available');
            return target.addEvent(event);
          }).then((id: number) => callback(this.success(callbackId, 'Calendar', methodName, '{"id":' + JSON.stringify(String(id)) + '}'))).catch((error: Object) => callback(this.calendarFailure(callbackId, methodName, error)));
          return;
        }
        case 'findEvents': {
          this.matchingCalendarEvents(calendar, options).then((matches: Array<LynxCapacitorCalendarEventMatch>) => {
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
            if (rawId.length > 0) {
              const id = Number(rawId);
              return Promise.all(values.map((value: calendarManager.Calendar) => value.getEvents().then((events: Array<calendarManager.Event>) => ({ calendar: value, events: events.filter((event: calendarManager.Event) => event.id === id) } as LynxCapacitorCalendarEventGroup)))).then((groups: Array<LynxCapacitorCalendarEventGroup>) => {
                const match = groups.find((group: LynxCapacitorCalendarEventGroup) => group.events.length > 0);
                if (match === undefined || match.events[0] === undefined) throw new Error('Calendar event was not found');
                return match.calendar.deleteEvent(id);
              }).then((): void => {});
            }
            return this.matchingCalendarEvents(calendar, options).then((matches: Array<LynxCapacitorCalendarEventMatch>) => {
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
      if (calendarName.length > 0 && this.calendarName(value) !== calendarName) return Promise.resolve([] as Array<LynxCapacitorCalendarEventMatch>);
      return value.getEvents().then((events: Array<calendarManager.Event>) => events.filter((event: calendarManager.Event) => {
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
      const result: Array<LynxCapacitorCalendarEventMatch> = [];
      groups.forEach((group: Array<LynxCapacitorCalendarEventMatch>) => group.forEach((match: LynxCapacitorCalendarEventMatch) => result.push(match)));
      return result;
    });
  }

  private calendarFailure(callbackId: string, methodName: string, error: Object): string {
    const message = 'Calendar.' + methodName + ' failed: ' + String(error);
    const code = String(error).indexOf('201') >= 0 ? 'PERMISSION_DENIED' : 'UNAVAILABLE';
    return this.failure(callbackId, 'Calendar', methodName, code, message);
  }

  /** 使用 BackgroundTasksKit reminderAgentManager 支持可排程的本地通知基础闭环。 */
  private handleLocalNotifications(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (this.handleNotificationHistory(callbackId, 'LocalNotifications', methodName, options, callback)) return;
    if (methodName === 'checkPermissions' || methodName === 'areEnabled') {
      try {
        notificationManager.isNotificationEnabled().then((enabled: boolean) => {
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
        notificationManager.requestEnableNotification(getContext() as common.UIAbilityContext).then(() => {
          notificationManager.isNotificationEnabled().then((enabled: boolean) => {
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
        return reminderAgentManager.publishReminder(request).then((reminderId: number) => {
          this.localNotificationIds.set(reminderId, { id: reminderId, title: request.title ?? '', body: request.content ?? '' });
          this.persistLocalNotificationIds();
          return reminderId;
        });
      })).then((ids: Array<number>) => callback(this.success(callbackId, 'LocalNotifications', methodName, '{"notifications":[' + ids.map((id: number) => '{"id":' + JSON.stringify(String(id)) + '}').join(',') + ']}'))).catch((error: Object) => callback(this.notificationsFailure(callbackId, methodName, error)));
      return;
    }
    if (methodName === 'getPending') {
      try {
        reminderAgentManager.getAllValidReminders().then((values: Array<reminderAgentManager.ReminderInfo>) => {
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
        return reminderAgentManager.cancelReminder(id).then(() => {
          this.localNotificationIds.delete(id);
          this.persistLocalNotificationIds();
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
        reminderAgentManager.addNotificationSlot(slot).then(() => {
          const record: LynxCapacitorNotificationChannel = {
            id: id,
            name: name,
            description: description,
            importance: importance,
            slotType: slotType,
          };
          this.localNotificationChannels.set(id, record);
          this.persistLocalNotificationChannels();
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
        notificationManager.requestEnableNotification(getContext() as common.UIAbilityContext).then(() => {
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
          : manager.requestPermissionsFromUser(getContext() as common.UIAbilityContext, ['ohos.permission.APPROXIMATELY_LOCATION']);
        requestLocation.then(() => notificationManager.requestEnableNotification(getContext() as common.UIAbilityContext)).then(() => {
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
        return operation.then((): void => {
          if (pluginId === 'LocalNotifications') {
            this.localNotificationIds.delete(id);
            this.persistLocalNotificationIds();
          }
        });
      })).then(() => callback(this.success(callbackId, pluginId, methodName))).catch((error: Object) => callback(this.failure(callbackId, pluginId, methodName, 'UNAVAILABLE', pluginId + '.' + methodName + ' failed: ' + String(error))));
      return true;
    }
    if (methodName === 'removeAllDeliveredNotifications') {
      try {
        notificationManager.getActiveNotifications().then((values: Array<notificationManager.NotificationRequest>) => {
          const ownedValues = values.filter((value: notificationManager.NotificationRequest): boolean => {
            const isLocal = this.localNotificationIds.has(Number(value.id ?? -1));
            return pluginId === 'LocalNotifications' ? isLocal : pluginId === 'PushNotifications' ? !isLocal : true;
          });
          return Promise.all(ownedValues.map((value: notificationManager.NotificationRequest) => {
            const id = Number(value.id ?? -1);
            const label = value.label === undefined ? '' : String(value.label);
            return label.length > 0 ? notificationManager.cancel(id, label) : notificationManager.cancel(id);
          })).then((): void => {
            if (pluginId === 'LocalNotifications') {
              ownedValues.forEach((value: notificationManager.NotificationRequest): void => {
                this.localNotificationIds.delete(Number(value.id ?? -1));
              });
              this.persistLocalNotificationIds();
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
    try {
      if (methodName === 'isAvailable') {
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, '{"result":true}'));
        return;
      }
      if (methodName === 'createConnection') {
        const name = this.sqliteName(options);
        this.sqliteSpecifications.set(name, {
          readonly: Boolean(options['readonly'] ?? false),
          encrypted: Boolean(options['encrypted'] ?? false),
          version: Number(options['version'] ?? 0),
        });
        callback(this.success(callbackId, 'CapacitorSQLite', methodName));
        return;
      }
      if (methodName === 'addUpgradeStatement') {
        this.addUpgradeStatementSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'open') {
        this.openSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'close' || methodName === 'closeConnection') {
        this.closeSQLite(callbackId, methodName, options, callback);
        return;
      }
      if (methodName === 'beginTransaction' || methodName === 'commitTransaction' || methodName === 'rollbackTransaction') {
        this.transactionSQLite(callbackId, methodName, options, callback);
        return;
      }
      if (methodName === 'isTransactionActive') {
        const name = this.sqliteName(options);
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(this.sqliteTransactions.has(name))}}`));
        return;
      }
      if (methodName === 'echo') {
        const value = options['value'];
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"value":${value === undefined ? 'null' : JSON.stringify(value)}}`));
        return;
      }
      if (methodName === 'getUrl') {
        const name = this.sqliteName(options);
        this.sqliteStore(options);
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, JSON.stringify({ url: `file://${this.sqliteDatabasePath(name)}` })));
        return;
      }
      if (methodName === 'getVersion') {
        const store = this.sqliteStore(options);
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"version":${String(store.version)}}`));
        return;
      }
      if (methodName === 'execute') {
        this.executeSQLite(callbackId, methodName, options, callback);
        return;
      }
      if (methodName === 'executeSet') {
        this.executeSetSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'run') {
        this.runSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'query') {
        this.querySQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'isDBOpen') {
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(this.sqliteStores.has(this.sqliteName(options)))}}`));
        return;
      }
      if (methodName === 'isDBExists') {
        const name = this.sqliteName(options);
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(this.sqliteStores.has(name) && this.sqliteDatabaseExists(name))}}`));
        return;
      }
      if (methodName === 'isDatabase') {
        const name = this.sqliteName(options);
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(this.sqliteDatabaseExists(name))}}`));
        return;
      }
      if (methodName === 'isDatabaseEncrypted' || methodName === 'isInConfigEncryption' || methodName === 'isInConfigBiometricAuth') {
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, '{"result":false}'));
        return;
      }
      if (methodName === 'isTableExists') {
        this.tableExistsSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'deleteDatabase') {
        this.deleteSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'isJsonValid') {
        const value = String(options['jsonstring'] ?? '');
        let valid = false;
        try { JSON.parse(value); valid = true; } catch (error) { valid = false; }
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(valid)}}`));
        return;
      }
      if (methodName === 'createSyncTable') {
        const store = this.sqliteStore(options);
        store.executeSql('CREATE TABLE IF NOT EXISTS sync_table (id INTEGER PRIMARY KEY, sql_deleted INTEGER DEFAULT 0, last_modified INTEGER)').then(() => {
          callback(this.success(callbackId, 'CapacitorSQLite', methodName, '{"changes":{"changes":0}}'));
        }).catch((error: Object) => callback(this.sqliteFailure(callbackId, methodName, error)));
        return;
      }
      if (methodName === 'setSyncDate') {
        const name = this.sqliteName(options);
        const value = this.sqliteSyncDateValue(options['syncDate']);
        this.dataPreferences?.putSync(`sqlite_sync_date.${name}`, String(value));
        this.dataPreferences?.flushSync();
        callback(this.success(callbackId, 'CapacitorSQLite', methodName));
        return;
      }
      if (methodName === 'getSyncDate') {
        const name = this.sqliteName(options);
        const value = Number(this.dataPreferences?.getSync(`sqlite_sync_date.${name}`, '0') ?? '0');
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"syncDate":${String(Number.isFinite(value) ? value : 0)}}`));
        return;
      }
      if (methodName === 'getDatabaseList') {
        const context = getContext() as common.UIAbilityContext;
        let files: Array<string> = [];
        try { files = fileIo.listFileSync(context.databaseDir); } catch (error) { files = []; }
        const values = files.filter((file: string) => file.endsWith('SQLite.db')).map((file: string) => file.substring(0, file.length - 'SQLite.db'.length)).sort();
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"values":${JSON.stringify(values)}}`));
        return;
      }
      if (methodName === 'copyFromAssets') {
        this.copyFromAssetsSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'getFromHTTPRequest') {
        this.getFromHTTPRequestSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'getMigratableDbList') {
        this.getMigratableDbListSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'addSQLiteSuffix') {
        this.addSQLiteSuffixSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'deleteOldDatabases') {
        this.deleteOldDatabasesSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'moveDatabasesAndAddSuffix') {
        this.moveDatabasesAndAddSuffixSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'getTableList') {
        this.tableListSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'deleteExportedRows') {
        this.deleteExportedRowsSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'exportToJson') {
        this.exportSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'importFromJson') {
        this.importSQLite(callbackId, options, callback);
        return;
      }
      if (methodName === 'checkConnectionsConsistency') {
        const rawNames = options['dbNames'];
        const names = Array.isArray(rawNames) ? rawNames as Array<Object> : [];
        const consistent = names.every((value: Object) => this.sqliteStores.has(String(value)));
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"result":${String(consistent)}}`));
        return;
      }
      if (methodName === 'closeAllConnections') {
        this.sqliteStores.forEach((store: relationalStore.RdbStore) => {
          try { store.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite close failed: ${String(error)}`); }
        });
        this.sqliteStores.clear();
        this.sqliteTransactions.clear();
        callback(this.success(callbackId, 'CapacitorSQLite', methodName));
        return;
      }
      if (methodName === 'isSecretStored' || methodName === 'checkEncryptionSecret') {
        callback(this.success(callbackId, 'CapacitorSQLite', methodName, '{"result":false}'));
        return;
      }
      callback(this.failure(callbackId, 'CapacitorSQLite', methodName, 'UNAVAILABLE', `SQLite.${methodName} requires SQLCipher, web-store, NC database or Community provider integration`));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, methodName, error));
    }
  }

  private openSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const specification = this.sqliteSpecifications.get(name) ?? {
      readonly: Boolean(options['readonly'] ?? false),
      encrypted: Boolean(options['encrypted'] ?? false),
      version: Number(options['version'] ?? 0),
    };
    if (specification.encrypted || Boolean(options['encrypted'] ?? false)) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'open', 'UNAVAILABLE', 'Harmony relationalStore encryption is not exposed as SQLCipher-compatible Community SQLite'));
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: `${name}SQLite.db`,
      securityLevel: relationalStore.SecurityLevel.S1,
      encrypt: false,
    };
    try {
      relationalStore.getRdbStore(getContext() as common.UIAbilityContext, config).then((store: relationalStore.RdbStore) => {
        const old = this.sqliteStores.get(name);
        if (old !== undefined) {
          try { old.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite old store close failed: ${String(error)}`); }
        }
        this.sqliteStores.set(name, store);
        this.sqliteSpecifications.set(name, specification);
        this.sqliteTransactions.delete(name);
        this.applySQLiteUpgrades(name, store, specification).then(() => {
          callback(this.success(callbackId, 'CapacitorSQLite', 'open'));
        }).catch((error: Object) => {
          this.sqliteStores.delete(name);
          this.sqliteSpecifications.delete(name);
          try { store.close(); } catch (closeError) { console.error('LynxCapacitorModule', `SQLite upgrade close failed: ${String(closeError)}`); }
          callback(this.sqliteFailure(callbackId, 'open', error));
        });
      }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'open', error)));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'open', error));
    }
  }

  /** 保存 Community SQLite 的版本升级语句，打开 ArkData store 时按版本顺序执行。 */
  private addUpgradeStatementSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const name = this.sqliteName(options);
      const rawUpgrade = options['upgrade'];
      if (!Array.isArray(rawUpgrade) || rawUpgrade.length === 0) {
        callback(this.failure(callbackId, 'CapacitorSQLite', 'addUpgradeStatement', 'INVALID_ARGUMENT', 'upgrade is required'));
        return;
      }
      const versions = this.sqliteUpgradeStatements.get(name) ?? new Map<number, Array<string>>();
      (rawUpgrade as Array<Object>).forEach((rawValue: Object, index: number): void => {
        const value = rawValue as Record<string, Object>;
        const toVersion = Number(value['toVersion'] ?? NaN);
        const rawStatements = value['statements'];
        if (!Number.isInteger(toVersion) || toVersion <= 0 || !Array.isArray(rawStatements) || rawStatements.length === 0) {
          throw new Error(`upgrade[${String(index)}] must contain a positive toVersion and statements`);
        }
        const statements = (rawStatements as Array<Object>).map((statement: Object, statementIndex: number): string => {
          const sql = String(statement ?? '').trim();
          if (sql.length === 0) throw new Error(`upgrade[${String(index)}].statements[${String(statementIndex)}] is required`);
          return sql;
        });
        versions.set(toVersion, statements);
      });
      this.sqliteUpgradeStatements.set(name, versions);
      callback(this.success(callbackId, 'CapacitorSQLite', 'addUpgradeStatement'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'addUpgradeStatement', error));
    }
  }

  private async applySQLiteUpgrades(name: string, store: relationalStore.RdbStore, specification: LynxCapacitorSQLiteSpecification): Promise<void> {
    if (specification.readonly || specification.version <= 0 || specification.version <= store.version) return;
    const versions = this.sqliteUpgradeStatements.get(name);
    if (versions === undefined || versions.size === 0) {
      store.version = specification.version;
      return;
    }
    store.beginTransaction();
    try {
      const currentVersion = store.version;
      const orderedVersions = Array.from(versions.keys()).sort((left: number, right: number) => left - right);
      for (const version of orderedVersions) {
        if (version <= currentVersion || version > specification.version) continue;
        const statements = versions.get(version) ?? [];
        for (const statement of statements) await store.executeSql(statement);
        store.version = version;
      }
      store.version = specification.version;
      store.commit();
    } catch (error) {
      try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitorModule', `SQLite upgrade rollback failed: ${String(rollbackError)}`); }
      throw new Error(String(error));
    }
  }

  /** 从 HAR/宿主 rawfile 的 databases 目录复制非压缩 .db 文件。 */
  private copyFromAssetsSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const overwrite = Boolean(options['overwrite'] ?? true);
      const context = getContext() as common.UIAbilityContext;
      const rawFiles = context.resourceManager.getRawFileListSync('databases');
      if (rawFiles.some((file: string) => file.toLowerCase().endsWith('.zip'))) {
        callback(this.failure(callbackId, 'CapacitorSQLite', 'copyFromAssets', 'UNAVAILABLE', 'zip assets require a dedicated archive provider'));
        return;
      }
      const databaseFiles = rawFiles.filter((file: string) => file.toLowerCase().endsWith('.db'));
      let copied = 0;
      databaseFiles.forEach((file: string): void => {
        const source = file.indexOf('/') >= 0 ? file.substring(file.lastIndexOf('/') + 1) : file;
        const target = `${context.databaseDir}/${this.sqliteFileName(source)}`;
        const bytes = context.resourceManager.getRawFileContentSync(`databases/${file}`);
        if (this.writeSQLiteBytes(target, bytes.buffer as ArrayBuffer, overwrite)) copied += 1;
      });
      if (copied === 0) {
        callback(this.failure(callbackId, 'CapacitorSQLite', 'copyFromAssets', 'UNAVAILABLE', 'databases rawfile contains no SQLite database'));
        return;
      }
      callback(this.success(callbackId, 'CapacitorSQLite', 'copyFromAssets'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'copyFromAssets', error));
    }
  }

  /** 通过 NetworkKit 下载非压缩 .db 文件并写入 Harmony 数据库目录。 */
  private getFromHTTPRequestSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const url = String(options['url'] ?? '').trim();
    if (!(url.startsWith('https://') || url.startsWith('http://'))) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest', 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
      return;
    }
    const fileName = url.substring(url.lastIndexOf('/') + 1).split('?')[0];
    if (fileName.toLowerCase().endsWith('.zip')) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest', 'UNAVAILABLE', 'zip downloads require a dedicated archive provider'));
      return;
    }
    if (!fileName.toLowerCase().endsWith('.db')) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest', 'INVALID_ARGUMENT', 'url must end with .db or .zip'));
      return;
    }
    const context = getContext() as common.UIAbilityContext;
    const target = `${context.databaseDir}/${this.sqliteFileName(fileName)}`;
    const overwrite = Boolean(options['overwrite'] ?? true);
    if (this.sqlitePathExists(target) && !overwrite) {
      callback(this.success(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest'));
      return;
    }
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      request.request(url, requestOptions).then((response: http.HttpResponse) => {
        try {
          if (Number(response.responseCode) < 200 || Number(response.responseCode) >= 300 || !(response.result instanceof ArrayBuffer)) {
            callback(this.failure(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest', 'NETWORK', `Download failed with HTTP ${String(response.responseCode)}`));
            return;
          }
          this.writeSQLiteBytes(target, response.result as ArrayBuffer, true);
          callback(this.success(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest'));
        } catch (error) {
          callback(this.sqliteFailure(callbackId, 'getFromHTTPRequest', error));
        } finally {
          request?.destroy();
        }
      }).catch((error: Object) => {
        request?.destroy();
        callback(this.failure(callbackId, 'CapacitorSQLite', 'getFromHTTPRequest', 'NETWORK', `Download failed: ${String(error)}`));
      });
    } catch (error) {
      request?.destroy();
      callback(this.sqliteFailure(callbackId, 'getFromHTTPRequest', error));
    }
  }

  private getMigratableDbListSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const folder = this.sqliteMigrationFolder(String(options['folderPath'] ?? 'default'));
      const values = this.sqliteMigrationFiles(folder, []).map((file: string) => file.substring(file.lastIndexOf('/') + 1)).sort();
      callback(this.success(callbackId, 'CapacitorSQLite', 'getMigratableDbList', `{"values":${JSON.stringify(values)}}`));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'getMigratableDbList', error));
    }
  }

  private addSQLiteSuffixSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const folder = this.sqliteMigrationFolder(String(options['folderPath'] ?? 'default'));
      const requested = this.sqliteStringList(options['dbNameList']);
      const context = getContext() as common.UIAbilityContext;
      const targetRoot = context.databaseDir;
      this.sqliteMigrationFiles(folder, requested).forEach((source: string): void => {
        const target = `${targetRoot}/${this.sqliteFileName(source.substring(source.lastIndexOf('/') + 1))}`;
        this.writeSQLiteFile(target, source, true);
      });
      callback(this.success(callbackId, 'CapacitorSQLite', 'addSQLiteSuffix'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'addSQLiteSuffix', error));
    }
  }

  private deleteOldDatabasesSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const folder = this.sqliteMigrationFolder(String(options['folderPath'] ?? 'default'));
      const requested = this.sqliteStringList(options['dbNameList']);
      this.sqliteMigrationFiles(folder, requested).forEach((file: string): void => fileIo.unlinkSync(file));
      callback(this.success(callbackId, 'CapacitorSQLite', 'deleteOldDatabases'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'deleteOldDatabases', error));
    }
  }

  private moveDatabasesAndAddSuffixSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const folder = this.sqliteMigrationFolder(String(options['folderPath'] ?? 'default'));
      const requested = this.sqliteStringList(options['dbNameList']);
      const context = getContext() as common.UIAbilityContext;
      const targetRoot = context.databaseDir;
      this.sqliteMigrationFiles(folder, requested).forEach((source: string): void => {
        const target = `${targetRoot}/${this.sqliteFileName(source.substring(source.lastIndexOf('/') + 1))}`;
        this.sqliteCloseByName(target.substring(targetRoot.length + 1));
        if (this.sqlitePathExists(target)) fileIo.unlinkSync(target);
        fileIo.moveFileSync(source, target);
      });
      callback(this.success(callbackId, 'CapacitorSQLite', 'moveDatabasesAndAddSuffix'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'moveDatabasesAndAddSuffix', error));
    }
  }

  private sqliteMigrationFolder(rawPath: string): string {
    const path = rawPath.trim().length === 0 ? 'default' : rawPath.trim();
    if (path.startsWith('/') || path.indexOf('..') >= 0) throw new Error('folderPath traversal is not allowed');
    const context = getContext() as common.UIAbilityContext;
    let root = context.databaseDir;
    let relative = '';
    if (path.toLowerCase() === 'cache') root = context.cacheDir;
    else if (path.toLowerCase() === 'files') root = context.filesDir;
    else if (path.toLowerCase() === 'databases') root = context.databaseDir;
    else if (path.toLowerCase().startsWith('files/')) {
      root = context.filesDir;
      relative = path.substring(6);
    } else if (path.toLowerCase().startsWith('databases/')) {
      root = context.databaseDir;
      relative = path.substring(10);
    } else if (path.toLowerCase() !== 'default') {
      throw new Error('folderPath must be default, cache, files[/subpath], or databases[/subpath]');
    }
    const folder = relative.length > 0 ? `${root}/${relative}` : root;
    if (!this.sqlitePathExists(folder)) throw new Error(`Folder ${folder} does not exist`);
    return folder;
  }

  private sqliteMigrationFiles(folder: string, requested: Array<string>): Array<string> {
    const files = fileIo.listFileSync(folder).map((name: string) => `${folder}/${name}`).filter((path: string): boolean => {
      const name = path.substring(path.lastIndexOf('/') + 1);
      if (name.startsWith('.') || name.toLowerCase().indexOf('sqlite.db') >= 0) return false;
      try { return (fileIo.statSync(path).mode & fileIo.OpenMode.DIR) === 0; } catch (error) { return false; }
    });
    if (requested.length > 0) return files.filter((path: string) => requested.indexOf(path.substring(path.lastIndexOf('/') + 1)) >= 0);
    return files.filter((path: string) => path.toLowerCase().endsWith('.db'));
  }

  private sqliteStringList(raw: Object | undefined): Array<string> {
    return Array.isArray(raw) ? (raw as Array<Object>).map((value: Object) => String(value)).filter((value: string) => value.length > 0) : [];
  }

  private sqliteFileName(rawName: string): string {
    const name = rawName.substring(rawName.lastIndexOf('/') + 1);
    if (name.toLowerCase().endsWith('sqlite.db')) return name;
    if (name.toLowerCase().endsWith('.db')) return name.substring(0, name.length - 3) + 'SQLite.db';
    return name + 'SQLite.db';
  }

  private sqlitePathExists(path: string): boolean {
    try { return fileIo.accessSync(path); } catch (error) { return false; }
  }

  private sqliteCloseByName(fileName: string): void {
    const name = fileName.endsWith('SQLite.db') ? fileName.substring(0, fileName.length - 'SQLite.db'.length) : fileName;
    const store = this.sqliteStores.get(name);
    if (store !== undefined) {
      try { store.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite migration close failed: ${String(error)}`); }
      this.sqliteStores.delete(name);
    }
    this.sqliteTransactions.delete(name);
  }

  private writeSQLiteBytes(target: string, bytes: ArrayBuffer, overwrite: boolean): boolean {
    if (this.sqlitePathExists(target) && !overwrite) return false;
    this.sqliteCloseByName(target.substring(target.lastIndexOf('/') + 1));
    const parent = target.substring(0, target.lastIndexOf('/'));
    if (parent.length > 0 && !this.sqlitePathExists(parent)) fileIo.mkdirSync(parent, true);
    const file = fileIo.openSync(target, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, bytes); } finally { fileIo.closeSync(file); }
    return true;
  }

  private writeSQLiteFile(target: string, source: string, overwrite: boolean): boolean {
    if (this.sqlitePathExists(target) && !overwrite) return false;
    this.sqliteCloseByName(target.substring(target.lastIndexOf('/') + 1));
    if (this.sqlitePathExists(target)) fileIo.unlinkSync(target);
    fileIo.copyFileSync(source, target);
    return true;
  }

  private closeSQLite(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const store = this.sqliteStores.get(name);
    if (store !== undefined) {
      try { store.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite close failed: ${String(error)}`); }
      this.sqliteStores.delete(name);
    }
    this.sqliteTransactions.delete(name);
    callback(this.success(callbackId, 'CapacitorSQLite', methodName));
  }

  private transactionSQLite(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const store = this.sqliteStore(options);
    try {
      if (methodName === 'beginTransaction') {
        if (this.sqliteTransactions.has(name)) throw new Error('SQLite transaction is already active');
        if (this.sqliteSpecifications.get(name)?.readonly === true) throw new Error('SQLite transaction requires a writable database');
        store.beginTransaction();
        this.sqliteTransactions.add(name);
      } else {
        if (!this.sqliteTransactions.has(name)) throw new Error('SQLite transaction is not active');
        if (methodName === 'commitTransaction') store.commit();
        else store.rollBack();
        this.sqliteTransactions.delete(name);
      }
      callback(this.success(callbackId, 'CapacitorSQLite', methodName, '{"changes":{"changes":0}}'));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, methodName, error));
    }
  }

  private executeSQLite(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const store = this.sqliteStore(options);
    const statements = String(options['statements'] ?? '').split(';').map((value: string) => value.trim()).filter((value: string) => value.length > 0);
    if (statements.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', methodName, 'INVALID_ARGUMENT', 'statements is required'));
      return;
    }
    const autoTransaction = Boolean(options['transaction'] ?? true) && !this.sqliteTransactions.has(name);
    try { if (autoTransaction) store.beginTransaction(); } catch (error) { callback(this.sqliteFailure(callbackId, methodName, error)); return; }
    const execute = async (): Promise<void> => {
      for (const statement of statements) await this.executeSqlWithSync(options, store, statement, []);
    };
    execute().then(() => {
      try { if (autoTransaction) store.commit(); } catch (error) { callback(this.sqliteFailure(callbackId, methodName, error)); return; }
      callback(this.success(callbackId, 'CapacitorSQLite', methodName, `{"changes":{"changes":${String(statements.length)}}}`));
    }).catch((error: Object) => {
      if (autoTransaction) {
        try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitorModule', `SQLite rollback failed: ${String(rollbackError)}`); }
      }
      callback(this.sqliteFailure(callbackId, methodName, error));
    });
  }

  private executeSetSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const store = this.sqliteStore(options);
    const rawSet = options['set'];
    if (!Array.isArray(rawSet) || rawSet.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'executeSet', 'INVALID_ARGUMENT', 'set is required'));
      return;
    }
    const autoTransaction = Boolean(options['transaction'] ?? true) && !this.sqliteTransactions.has(name);
    try { if (autoTransaction) store.beginTransaction(); } catch (error) { callback(this.sqliteFailure(callbackId, 'executeSet', error)); return; }
    const execute = async (): Promise<void> => {
      for (const rawValue of rawSet as Array<Object>) {
        const value = rawValue as Record<string, Object>;
        const statement = String(value['statement'] ?? '').trim();
        if (statement.length === 0) throw new Error('statement is required');
        await this.executeSqlWithSync(options, store, statement, this.sqliteValues(value));
      }
    };
    execute().then(() => {
      try { if (autoTransaction) store.commit(); } catch (error) { callback(this.sqliteFailure(callbackId, 'executeSet', error)); return; }
      callback(this.success(callbackId, 'CapacitorSQLite', 'executeSet', `{"changes":{"changes":${String(rawSet.length)}}}`));
    }).catch((error: Object) => {
      if (autoTransaction) {
        try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitorModule', `SQLite rollback failed: ${String(rollbackError)}`); }
      }
      callback(this.sqliteFailure(callbackId, 'executeSet', error));
    });
  }

  private runSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const store = this.sqliteStore(options);
    const statement = String(options['statement'] ?? '').trim();
    if (statement.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'run', 'INVALID_ARGUMENT', 'statement is required'));
      return;
    }
    const name = this.sqliteName(options);
    const autoTransaction = Boolean(options['transaction'] ?? true) && !this.sqliteTransactions.has(name);
    try { if (autoTransaction) store.beginTransaction(); } catch (error) { callback(this.sqliteFailure(callbackId, 'run', error)); return; }
    this.executeSqlWithSync(options, store, statement, this.sqliteValues(options)).then(() => {
      try { if (autoTransaction) store.commit(); } catch (error) { callback(this.sqliteFailure(callbackId, 'run', error)); return; }
      callback(this.success(callbackId, 'CapacitorSQLite', 'run', '{"changes":{"changes":0}}'));
    }).catch((error: Object) => {
      if (autoTransaction) {
        try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitorModule', `SQLite rollback failed: ${String(rollbackError)}`); }
      }
      callback(this.sqliteFailure(callbackId, 'run', error));
    });
  }

  private async executeSqlWithSync(options: Record<string, Object>, store: relationalStore.RdbStore, statement: string, values: Array<relationalStore.ValueType>): Promise<void> {
    const rewritten = await this.sqliteRewriteDelete(options, statement);
    await store.executeSql(rewritten ?? statement, values);
  }

  /** 仅改写无 alias/RETURNING 的标准 DELETE；复杂 SQL 保留调用方原始语义。 */
  private async sqliteRewriteDelete(options: Record<string, Object>, statement: string): Promise<string | undefined> {
    const normalized = statement.trim();
    const upper = normalized.toUpperCase();
    if (!upper.startsWith('DELETE FROM ')) return undefined;
    const whereMarker = upper.indexOf(' WHERE ', 12);
    let tableToken = whereMarker >= 0 ? normalized.substring(12, whereMarker).trim() : normalized.substring(12).trim();
    let where = whereMarker >= 0 ? normalized.substring(whereMarker + 7).trim() : '';
    if (tableToken.endsWith(';')) tableToken = tableToken.substring(0, tableToken.length - 1).trim();
    if (where.endsWith(';')) where = where.substring(0, where.length - 1).trim();
    if (tableToken.length >= 2 && tableToken.startsWith('"') && tableToken.endsWith('"')) tableToken = tableToken.substring(1, tableToken.length - 1);
    if (tableToken.length === 0 || where.indexOf(';') >= 0 || where.indexOf('--') >= 0 || where.indexOf('/*') >= 0) return undefined;
    const table = this.sqliteIdentifier(tableToken, 'table');
    const info = await this.sqliteTableInfo(options, table);
    if (info.sqlDeletedIndex < 0 || !info.columns.includes('last_modified')) return undefined;
    const whereClause = where.length === 0 ? '' : ` WHERE ${where}`;
    return `UPDATE ${this.sqliteQuote(table)} SET ${this.sqliteQuote('sql_deleted')} = 1, ${this.sqliteQuote('last_modified')} = strftime('%s','now')${whereClause}`;
  }

  private querySQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const statement = String(options['statement'] ?? '').trim();
    if (statement.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'query', 'INVALID_ARGUMENT', 'statement is required'));
      return;
    }
    this.sqliteQueryRows(options, statement, this.sqliteValues(options)).then((rows: Array<Array<relationalStore.ValueType>>) => {
      callback(this.success(callbackId, 'CapacitorSQLite', 'query', `{"values":${JSON.stringify(rows)}}`));
    }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'query', error)));
  }

  private tableExistsSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const table = String(options['table'] ?? '');
    if (table.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'isTableExists', 'INVALID_ARGUMENT', 'table is required'));
      return;
    }
    this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table] as Array<relationalStore.ValueType>).then((rows: Array<Array<relationalStore.ValueType>>) => {
      callback(this.success(callbackId, 'CapacitorSQLite', 'isTableExists', `{"result":${String(rows.length > 1)}}`));
    }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'isTableExists', error)));
  }

  private tableListSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", []).then((rows: Array<Array<relationalStore.ValueType>>) => {
      const values: string[] = [];
      rows.slice(1).forEach((row: Array<relationalStore.ValueType>) => { if (row.length > 0) values.push(String(row[0])); });
      callback(this.success(callbackId, 'CapacitorSQLite', 'getTableList', `{"values":${JSON.stringify(values)}}`));
    }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'getTableList', error)));
  }

  private deleteExportedRowsSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", []).then(async (rows: Array<Array<relationalStore.ValueType>>) => {
      const store = this.sqliteStore(options);
      for (const row of rows.slice(1)) {
        const table = String(row[0] ?? '');
        if (table.length === 0) continue;
        const schema = await this.sqliteQueryRows(options, `PRAGMA table_info(${this.sqliteQuote(table)})`, []);
        const hasDeleted = schema.slice(1).some((schemaRow: Array<relationalStore.ValueType>) => String(schemaRow[1] ?? '') === 'sql_deleted');
        if (hasDeleted) await store.executeSql(`DELETE FROM ${this.sqliteQuote(table)} WHERE sql_deleted = 1`);
      }
      callback(this.success(callbackId, 'CapacitorSQLite', 'deleteExportedRows', '{"changes":{"changes":0}}'));
    }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'deleteExportedRows', error)));
  }

  private exportSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const store = this.sqliteStore(options);
    const mode = this.sqliteJsonMode(String(options['jsonexportmode'] ?? 'full'));
    const syncDate = this.sqliteSyncDate(name);
    this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", []).then(async (rows: Array<Array<relationalStore.ValueType>>) => {
      const tables: Array<LynxCapacitorSQLiteJsonTable> = [];
      for (const row of rows.slice(1)) {
        const table = String(row[0] ?? '');
        if (table.length === 0) continue;
        const schemaRows = await this.sqliteQueryRows(options, `PRAGMA table_info(${this.sqliteQuote(table)})`, []);
        const schema: Array<LynxCapacitorSQLiteJsonColumn> = [];
        for (const schemaRow of schemaRows.slice(1)) {
          const column = String(schemaRow[1] ?? '');
          let definition = String(schemaRow[2] ?? 'TEXT');
          if (Number(schemaRow[5] ?? 0) > 0) definition += ' PRIMARY KEY';
          if (Number(schemaRow[3] ?? 0) > 0) definition += ' NOT NULL';
          if (schemaRow[4] !== null && schemaRow[4] !== undefined) definition += ' DEFAULT ' + String(schemaRow[4]);
          const schemaColumn: LynxCapacitorSQLiteJsonColumn = { column: column, value: definition };
          schema.push(schemaColumn);
        }
        const hasLastModified = schema.some((schemaRow: LynxCapacitorSQLiteJsonColumn) => schemaRow.column === 'last_modified');
        if (mode === 'partial' && !hasLastModified) throw new Error(`partial export requires last_modified on table ${table}`);
        const hasDeleted = schema.some((schemaRow: LynxCapacitorSQLiteJsonColumn) => schemaRow.column === 'sql_deleted');
        const predicate = hasDeleted ? 'last_modified > ? OR sql_deleted = 1' : 'last_modified > ?';
        const valueRows = await this.sqliteQueryRows(
          options,
          mode === 'partial' ? `SELECT * FROM ${this.sqliteQuote(table)} WHERE ${predicate}` : `SELECT * FROM ${this.sqliteQuote(table)}`,
          mode === 'partial' ? [syncDate] as Array<relationalStore.ValueType> : [],
        );
        if (mode === 'partial' && valueRows.length <= 1) continue;
        const indexes = await this.exportIndexesSQLite(options, table);
        const triggers = await this.exportTriggersSQLite(options, table);
        const jsonTable: LynxCapacitorSQLiteJsonTable = { name: table, schema: schema, indexes: indexes, triggers: triggers, values: valueRows.slice(1) };
        tables.push(jsonTable);
      }
      const views = await this.exportViewsSQLite(options);
      const exported: LynxCapacitorSQLiteJsonExport = {
        database: name,
        version: store.version,
        encrypted: false,
        mode: mode,
        tables: tables,
        views: views,
      };
      callback(this.success(callbackId, 'CapacitorSQLite', 'exportToJson', `{"export":${JSON.stringify(exported)}}`));
    }).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'exportToJson', error)));
  }

  private async exportViewsSQLite(options: Record<string, Object>): Promise<Array<LynxCapacitorSQLiteJsonView>> {
    const rows = await this.sqliteQueryRows(options, "SELECT name, sql FROM sqlite_master WHERE type='view' AND sql IS NOT NULL ORDER BY name", []);
    const views: Array<LynxCapacitorSQLiteJsonView> = [];
    rows.slice(1).forEach((row: Array<relationalStore.ValueType>) => {
      const name = String(row[0] ?? '');
      const sql = String(row[1] ?? '');
      const value = this.stripViewDefinition(sql);
      if (name.length > 0 && value.length > 0) views.push({ name: name, value: value });
    });
    return views;
  }

  private async exportIndexesSQLite(options: Record<string, Object>, table: string): Promise<Array<LynxCapacitorSQLiteJsonIndex>> {
    const rows = await this.sqliteQueryRows(options, "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL ORDER BY name", [table] as Array<relationalStore.ValueType>);
    const indexes: Array<LynxCapacitorSQLiteJsonIndex> = [];
    rows.slice(1).forEach((row: Array<relationalStore.ValueType>) => {
      const name = String(row[0] ?? '');
      const sql = String(row[1] ?? '');
      const open = sql.indexOf('(');
      const close = sql.lastIndexOf(')');
      if (name.length === 0 || open < 0 || close <= open) return;
      const item: LynxCapacitorSQLiteJsonIndex = { name: name, value: sql.substring(open + 1, close).trim(), sql: sql };
      if (sql.toUpperCase().indexOf('CREATE UNIQUE INDEX') === 0) item.mode = 'UNIQUE';
      indexes.push(item);
    });
    return indexes;
  }

  private async exportTriggersSQLite(options: Record<string, Object>, table: string): Promise<Array<LynxCapacitorSQLiteJsonTrigger>> {
    const rows = await this.sqliteQueryRows(options, "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND tbl_name=? AND sql IS NOT NULL ORDER BY name", [table] as Array<relationalStore.ValueType>);
    const triggers: Array<LynxCapacitorSQLiteJsonTrigger> = [];
    rows.slice(1).forEach((row: Array<relationalStore.ValueType>) => {
      const name = String(row[0] ?? '');
      const sql = String(row[1] ?? '');
      if (name.length > 0 && sql.length > 0) triggers.push({ name: name, timeevent: this.triggerTimeEventSQLite(sql), logic: this.triggerLogicSQLite(sql), sql: sql });
    });
    return triggers;
  }

  private triggerTimeEventSQLite(sql: string): string {
    const upper = sql.toUpperCase();
    const triggerIndex = upper.indexOf('TRIGGER');
    const onIndex = upper.indexOf(' ON ', triggerIndex + 7);
    if (triggerIndex < 0 || onIndex < 0) return '';
    const header = sql.substring(triggerIndex + 7, onIndex).replace(/IF\s+NOT\s+EXISTS/ig, '').trim();
    const parts = header.split(/\s+/);
    if (parts.length < 2) return '';
    return parts.slice(1).join(' ');
  }

  private triggerLogicSQLite(sql: string): string {
    const upper = sql.toUpperCase();
    const begin = upper.indexOf('BEGIN');
    const end = upper.lastIndexOf('END');
    return begin >= 0 && end >= begin ? sql.substring(begin, end + 3).trim() : sql.trim();
  }

  private importSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    let root: Record<string, Object>;
    try { root = JSON.parse(String(options['jsonstring'] ?? '')) as Record<string, Object>; } catch (error) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'importFromJson', 'INVALID_ARGUMENT', 'jsonstring must be a JSON object'));
      return;
    }
    const exported = (root['export'] ?? root) as Record<string, Object>;
    if (Boolean(exported['encrypted'] ?? false)) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'importFromJson', 'UNAVAILABLE', 'Encrypted SQLite JSON requires SQLCipher'));
      return;
    }
    const name = this.sqliteNameValue(String(exported['database'] ?? ''));
    const store = this.sqliteStores.get(name);
    if (store === undefined) throw new Error(`SQLite database ${name} is not open`);
    // importFromJson 的外层 options 只有 jsonstring；后续表/视图/索引/触发器操作
    // 仍需通过 database 选择同一个已打开的 RdbStore。
    const databaseOptions: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    databaseOptions['database'] = name;
    const rawTables: Array<Object> = Array.isArray(exported['tables']) ? exported['tables'] as Array<Object> : [];
    const rawViews: Array<Object> = Array.isArray(exported['views']) ? exported['views'] as Array<Object> : [];
    if (rawTables.length === 0 && rawViews.length === 0) {
      callback(this.failure(callbackId, 'CapacitorSQLite', 'importFromJson', 'INVALID_ARGUMENT', 'JSON export contains no tables or views'));
      return;
    }
    const mode = this.sqliteJsonMode(String(exported['mode'] ?? 'full'));
    const overwrite = Boolean(exported['overwrite'] ?? false) || Boolean(options['overwrite'] ?? false);
    try { store.beginTransaction(); } catch (error) { callback(this.sqliteFailure(callbackId, 'importFromJson', error)); return; }
    const importRows = async (): Promise<number> => {
      let changes = 0;
      if (overwrite) await this.dropViewsSQLite(databaseOptions, store);
      for (const rawTable of rawTables) {
        const table = rawTable as Record<string, Object>;
        const tableName = this.sqliteNameValue(String(table['name'] ?? 'table'));
        const quotedTable = this.sqliteQuote(tableName);
        const exists = await this.sqliteTableExists(databaseOptions, tableName);
        if (overwrite) await store.executeSql(`DROP TABLE IF EXISTS ${quotedTable}`);
        const rawSchema = table['schema'];
        if (mode === 'partial' && !overwrite && exists) {
          const existingInfo = await this.sqliteTableInfo(databaseOptions, tableName);
          if (existingInfo.columns.length === 0) throw new Error(`table ${tableName} has no columns`);
        } else {
          if (!Array.isArray(rawSchema) || rawSchema.length === 0) throw new Error(`table ${tableName} has no schema`);
        const definitions: string[] = [];
        for (const rawColumn of rawSchema as Array<Object>) {
          const column = rawColumn as Record<string, Object>;
          const columnName = this.sqliteIdentifier(String(column['column'] ?? ''), 'column');
          const value = String(column['value'] ?? '');
          if (value.length === 0 || !/^[A-Za-z0-9_(),.\x27\x22\s+\-]+$/.test(value) || value.indexOf(';') >= 0 || value.indexOf('--') >= 0 || value.indexOf('/*') >= 0) throw new Error(`column definition for ${columnName} contains unsupported SQL`);
          definitions.push(`${this.sqliteQuote(columnName)} ${value}`);
        }
          await store.executeSql(`CREATE TABLE IF NOT EXISTS ${quotedTable} (${definitions.join(',')})`);
        }
        changes += await this.importIndexesSQLite(databaseOptions, store, tableName, Array.isArray(table['indexes']) ? table['indexes'] as Array<Object> : []);
        const rawValues = table['values'];
        if (!Array.isArray(rawValues)) continue;
        if (mode === 'partial' && !overwrite) {
          const info = await this.sqliteTableInfo(databaseOptions, tableName);
          if (info.primaryKeyIndex < 0) throw new Error(`partial table ${tableName} requires a primary key`);
          for (const rawRow of rawValues as Array<Object>) {
            const row = rawRow as Array<relationalStore.ValueType>;
            if (row.length !== info.columns.length) throw new Error(`partial row for ${tableName} does not match the table schema`);
            if (info.sqlDeletedIndex >= 0 && this.sqliteIsDeleted(row[info.sqlDeletedIndex])) {
              const primaryKey = row[info.primaryKeyIndex];
              if (primaryKey === null || primaryKey === undefined) throw new Error(`partial deleted row for ${tableName} requires a primary key`);
              await store.executeSql(`DELETE FROM ${quotedTable} WHERE ${this.sqliteQuote(info.columns[info.primaryKeyIndex])} = ?`, [primaryKey]);
            } else {
              const placeholders = row.map(() => '?').join(',');
              await store.executeSql(`INSERT OR REPLACE INTO ${quotedTable} VALUES (${placeholders})`, row);
            }
            changes += 1;
          }
        } else {
          for (const rawRow of rawValues as Array<Object>) {
            const row = rawRow as Array<relationalStore.ValueType>;
            const placeholders = row.map(() => '?').join(',');
            await store.executeSql(`INSERT INTO ${quotedTable} VALUES (${placeholders})`, row);
            changes += 1;
          }
        }
        changes += await this.importTriggersSQLite(databaseOptions, store, tableName, Array.isArray(table['triggers']) ? table['triggers'] as Array<Object> : []);
      }
      changes += await this.importViewsSQLite(databaseOptions, store, rawViews, overwrite);
      return changes;
    };
    importRows().then((changes: number) => {
      try { store.commit(); } catch (error) { callback(this.sqliteFailure(callbackId, 'importFromJson', error)); return; }
      callback(this.success(callbackId, 'CapacitorSQLite', 'importFromJson', `{"changes":{"changes":${String(changes)}}}`));
    }).catch((error: Object) => {
      try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitorModule', `SQLite import rollback failed: ${String(rollbackError)}`); }
      callback(this.sqliteFailure(callbackId, 'importFromJson', error));
    });
  }

  private async importViewsSQLite(options: Record<string, Object>, store: relationalStore.RdbStore, rawViews: Array<Object>, overwrite: boolean): Promise<number> {
    let changes = 0;
    for (const rawView of rawViews) {
      const view = rawView as Record<string, Object>;
      const name = this.sqliteIdentifier(String(view['name'] ?? ''), 'view');
      const value = this.safeViewDefinition(String(view['value'] ?? ''));
      if (overwrite) await store.executeSql(`DROP VIEW IF EXISTS ${this.sqliteQuote(name)}`);
      await store.executeSql(`CREATE VIEW IF NOT EXISTS ${this.sqliteQuote(name)} AS ${value}`);
      changes += 1;
    }
    return changes;
  }

  private async importIndexesSQLite(options: Record<string, Object>, store: relationalStore.RdbStore, table: string, rawIndexes: Array<Object>): Promise<number> {
    let changes = 0;
    for (const rawIndex of rawIndexes) {
      const item = rawIndex as Record<string, Object>;
      const name = this.sqliteIdentifier(String(item['name'] ?? ''), 'index');
      if (await this.sqliteObjectExists(options, 'index', name)) continue;
      const rawSQL = String(item['sql'] ?? '').trim();
      if (rawSQL.length > 0) {
        if (!this.isSafeIndexSQLSQLite(rawSQL, name, table)) throw new Error('index SQL contains unsupported SQL');
        await store.executeSql(rawSQL);
      } else {
        const value = this.safeIndexValueSQLite(String(item['value'] ?? ''));
        const mode = String(item['mode'] ?? '').trim();
        if (mode.length > 0 && mode.toUpperCase() !== 'UNIQUE') throw new Error('index mode is unsupported');
        const unique = mode.toUpperCase() === 'UNIQUE' ? 'UNIQUE ' : '';
        await store.executeSql(`CREATE ${unique}INDEX IF NOT EXISTS ${this.sqliteQuote(name)} ON ${this.sqliteQuote(table)} (${value})`);
      }
      changes += 1;
    }
    return changes;
  }

  private async importTriggersSQLite(options: Record<string, Object>, store: relationalStore.RdbStore, table: string, rawTriggers: Array<Object>): Promise<number> {
    let changes = 0;
    for (const rawTrigger of rawTriggers) {
      const item = rawTrigger as Record<string, Object>;
      const name = this.sqliteIdentifier(String(item['name'] ?? ''), 'trigger');
      if (await this.sqliteObjectExists(options, 'trigger', name)) continue;
      const rawSQL = String(item['sql'] ?? '').trim();
      if (rawSQL.length > 0) {
        if (!this.isSafeTriggerSQLSQLite(rawSQL, name)) throw new Error('trigger SQL contains unsupported SQL');
        await store.executeSql(rawSQL);
      } else {
        const timeevent = String(item['timeevent'] ?? '').trim();
        if (!/^(BEFORE|AFTER|INSTEAD\s+OF)\s+(INSERT|UPDATE|DELETE)(\s+OF\s+[A-Za-z0-9_, ]+)?$/i.test(timeevent)) throw new Error('trigger timeevent is unsupported');
        const condition = String(item['condition'] ?? '').trim();
        if (condition.length > 0 && !this.safeSQLFragmentSQLite(condition)) throw new Error('trigger condition contains unsupported SQL');
        const logic = String(item['logic'] ?? '').trim();
        if (!/^BEGIN\b.*\bEND\s*;?$/is.test(logic) || !this.safeTriggerBodySQLite(logic)) throw new Error('trigger logic is unsupported');
        const whenClause = condition.length === 0 ? '' : ` WHEN ${condition}`;
        await store.executeSql(`CREATE TRIGGER IF NOT EXISTS ${this.sqliteQuote(name)} ${timeevent} ON ${this.sqliteQuote(table)} FOR EACH ROW${whenClause} ${logic}`);
      }
      changes += 1;
    }
    return changes;
  }

  private safeIndexValueSQLite(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length === 0 || !this.safeSQLFragmentSQLite(trimmed)) throw new Error('index value contains unsupported SQL');
    return trimmed;
  }

  private safeSQLFragmentSQLite(value: string): boolean {
    if (value.indexOf('--') >= 0 || value.indexOf('/*') >= 0 || value.indexOf('*/') >= 0 || value.indexOf(';') >= 0) return false;
    return !/\b(ATTACH|DETACH|DROP|ALTER|VACUUM|PRAGMA|INSERT|UPDATE|DELETE)\b/i.test(value);
  }

  private safeTriggerBodySQLite(value: string): boolean {
    if (value.indexOf('--') >= 0 || value.indexOf('/*') >= 0 || value.indexOf('*/') >= 0) return false;
    return !/\b(ATTACH|DETACH|DROP\s+TABLE|ALTER\s+TABLE|VACUUM|PRAGMA)\b/i.test(value);
  }

  private isSafeIndexSQLSQLite(sql: string, name: string, table: string): boolean {
    if (!/^\s*CREATE\s+(UNIQUE\s+)?INDEX\s+(IF\s+NOT\s+EXISTS\s+)?[\x22A-Za-z0-9_.-]+\s+ON\s+[\x22A-Za-z0-9_.-]+\s*\(.+\)\s*;?\s*$/is.test(sql)) return false;
    return sql.indexOf(name) >= 0 && sql.indexOf(table) >= 0 && !/\b(ATTACH|DETACH|DROP|ALTER|VACUUM|PRAGMA)\b/i.test(sql);
  }

  private isSafeTriggerSQLSQLite(sql: string, name: string): boolean {
    if (!/^\s*CREATE\s+TRIGGER\s+(IF\s+NOT\s+EXISTS\s+)?[\x22A-Za-z0-9_.-]+\s+.*\bBEGIN\b.*\bEND\s*;?\s*$/is.test(sql)) return false;
    return sql.indexOf(name) >= 0 && !/\b(ATTACH|DETACH|DROP\s+TABLE|ALTER\s+TABLE|VACUUM|PRAGMA)\b/i.test(sql);
  }

  private async dropViewsSQLite(options: Record<string, Object>, store: relationalStore.RdbStore): Promise<void> {
    const rows = await this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name", []);
    for (const row of rows.slice(1)) {
      const name = String(row[0] ?? '');
      if (name.length > 0) await store.executeSql(`DROP VIEW IF EXISTS ${this.sqliteQuote(name)}`);
    }
  }

  private stripViewDefinition(sql: string): string {
    const marker = sql.toUpperCase().indexOf(' AS ');
    return marker >= 0 ? sql.substring(marker + 4).trim() : sql.trim();
  }

  private safeViewDefinition(value: string): string {
    const trimmed = value.trim();
    const upper = trimmed.toUpperCase();
    const startsWithQuery = upper.indexOf('SELECT') === 0 || upper.indexOf('WITH') === 0;
    const forbidden = ['ATTACH', 'DETACH', 'DROP', 'ALTER', 'VACUUM', 'PRAGMA', 'INSERT', 'UPDATE', 'DELETE'];
    if (trimmed.length === 0 || !startsWithQuery || trimmed.indexOf(';') >= 0 || trimmed.indexOf('--') >= 0 || trimmed.indexOf('/*') >= 0 || forbidden.some((word: string) => upper.indexOf(word) >= 0)) {
      throw new Error('view definition contains unsupported SQL');
    }
    return trimmed;
  }

  private sqliteIdentifier(value: string, label: string): string {
    if (value.length === 0 || !/^[A-Za-z0-9_.-]+$/.test(value)) throw new Error(`${label} contains unsupported characters`);
    return value;
  }

  private sqliteQuote(value: string): string {
    return `"${this.sqliteIdentifier(value, 'identifier').replace(/"/g, '""')}"`;
  }

  private async sqliteTableExists(options: Record<string, Object>, table: string): Promise<boolean> {
    const rows = await this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table] as Array<relationalStore.ValueType>);
    return rows.length > 1;
  }

  private async sqliteObjectExists(options: Record<string, Object>, type: string, name: string): Promise<boolean> {
    const rows = await this.sqliteQueryRows(options, "SELECT name FROM sqlite_master WHERE type=? AND name=?", [type, name] as Array<relationalStore.ValueType>);
    return rows.length > 1;
  }

  private async sqliteTableInfo(options: Record<string, Object>, table: string): Promise<LynxCapacitorSQLiteTableInfo> {
    const rows = await this.sqliteQueryRows(options, `PRAGMA table_info(${this.sqliteQuote(table)})`, []);
    const columns: string[] = [];
    let primaryKeyIndex = -1;
    let sqlDeletedIndex = -1;
    rows.slice(1).forEach((row: Array<relationalStore.ValueType>) => {
      const name = String(row[1] ?? '');
      const index = columns.length;
      columns.push(name);
      if (primaryKeyIndex < 0 && Number(row[5] ?? 0) > 0) primaryKeyIndex = index;
      if (name === 'sql_deleted') sqlDeletedIndex = index;
    });
    return { columns: columns, primaryKeyIndex: primaryKeyIndex, sqlDeletedIndex: sqlDeletedIndex };
  }

  private sqliteIsDeleted(value: relationalStore.ValueType): boolean {
    if (typeof value === 'boolean') return value;
    if (typeof value === 'number') return value === 1;
    const text = String(value ?? '').toLowerCase();
    return text === '1' || text === 'true';
  }

  private sqliteJsonMode(raw: string): string {
    const mode = raw.trim().toLowerCase();
    if (mode.length === 0 || mode === 'full') return 'full';
    if (mode === 'partial') return 'partial';
    throw new Error('SQLite JSON mode must be full or partial');
  }

  private sqliteSyncDate(name: string): number {
    const raw = this.dataPreferences?.getSync(`sqlite_sync_date.${name}`, '0') ?? '0';
    const numeric = Number(raw);
    return Number.isFinite(numeric) ? (numeric > 100000000000 ? Math.floor(numeric / 1000) : numeric) : 0;
  }

  private sqliteSyncDateValue(raw: Object | undefined): number {
    if (raw === undefined || raw === null) return Math.floor(Date.now() / 1000);
    const numeric = Number(raw);
    if (Number.isFinite(numeric)) return numeric > 100000000000 ? Math.floor(numeric / 1000) : numeric;
    const timestamp = new Date(String(raw)).getTime();
    return Number.isNaN(timestamp) ? 0 : Math.floor(timestamp / 1000);
  }

  private deleteSQLite(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const name = this.sqliteName(options);
    const old = this.sqliteStores.get(name);
    if (old !== undefined) {
      try { old.close(); } catch (error) { console.error('LynxCapacitorModule', `SQLite delete close failed: ${String(error)}`); }
      this.sqliteStores.delete(name);
    }
    this.sqliteTransactions.delete(name);
    try {
      relationalStore.deleteRdbStore(getContext() as common.UIAbilityContext, `${name}SQLite.db`).then(() => callback(this.success(callbackId, 'CapacitorSQLite', 'deleteDatabase'))).catch((error: Object) => callback(this.sqliteFailure(callbackId, 'deleteDatabase', error)));
    } catch (error) {
      callback(this.sqliteFailure(callbackId, 'deleteDatabase', error));
    }
  }

  private async sqliteQueryRows(options: Record<string, Object>, statement: string, values: Array<relationalStore.ValueType>): Promise<Array<Array<relationalStore.ValueType>>> {
    const resultSet = await this.sqliteStore(options).querySql(statement, values);
    const columns = resultSet.columnNames;
    const rows: Array<Array<relationalStore.ValueType>> = [columns as Array<relationalStore.ValueType>];
    if (resultSet.goToFirstRow()) {
      do {
        const row: Array<relationalStore.ValueType> = [];
        for (let index = 0; index < columns.length; index += 1) row.push(this.sqliteResultValue(resultSet, index));
        rows.push(row);
      } while (resultSet.goToNextRow());
    }
    resultSet.close();
    return rows;
  }

  private sqliteResultValue(resultSet: relationalStore.ResultSet, index: number): relationalStore.ValueType {
    const type = resultSet.getColumnTypeSync(index);
    if (type === relationalStore.ColumnType.NULL) return null;
    if (type === relationalStore.ColumnType.INTEGER) return resultSet.getLong(index);
    if (type === relationalStore.ColumnType.REAL) return resultSet.getDouble(index);
    if (type === relationalStore.ColumnType.BLOB) return resultSet.getBlob(index);
    return resultSet.getString(index);
  }

  private sqliteStore(options: Record<string, Object>): relationalStore.RdbStore {
    const name = this.sqliteName(options);
    const store = this.sqliteStores.get(name);
    if (store === undefined) throw new Error(`SQLite database ${name} is not open`);
    return store;
  }

  private sqliteName(options: Record<string, Object>): string {
    return this.sqliteNameValue(String(options['database'] ?? '').trim());
  }

  private sqliteNameValue(rawValue: string): string {
    const raw = rawValue.trim();
    const name = raw.endsWith('SQLite.db') ? raw.substring(0, raw.length - 'SQLite.db'.length) : raw;
    if (name.length === 0 || !/^[A-Za-z0-9_.-]+$/.test(name)) throw new Error('database contains unsupported characters');
    return name;
  }

  private sqliteDatabasePath(name: string): string {
    const context = getContext() as common.UIAbilityContext;
    return `${context.databaseDir}/${name}SQLite.db`;
  }

  private sqliteDatabaseExists(name: string): boolean {
    try {
      return fileIo.accessSync(this.sqliteDatabasePath(name));
    } catch (error) {
      return false;
    }
  }

  private sqliteValues(options: Record<string, Object>): Array<relationalStore.ValueType> {
    const values = options['values'];
    return Array.isArray(values) ? values as Array<relationalStore.ValueType> : [];
  }

  private sqliteFailure(callbackId: string, methodName: string, error: Object): string {
    return this.failure(callbackId, 'CapacitorSQLite', methodName, 'SQLITE', `SQLite.${methodName} failed: ${String(error)}`);
  }

  /** 使用 AccessibilityKit 对齐 ScreenReader 状态查询和播报能力。 */
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
      console.error('LynxCapacitorModule', `ScreenReader listener setup failed: ${String(error)}`);
    }
  }

  private stopScreenReaderListener(): void {
    const onStateChange = this.screenReaderStateCallback;
    if (onStateChange === null) return;
    this.screenReaderStateCallback = null;
    try {
      accessibility.off('screenReaderStateChange', onStateChange);
    } catch (error) {
      console.error('LynxCapacitorModule', `ScreenReader listener removal failed: ${String(error)}`);
    }
  }

  /** 使用 Window.windowSizeChange 承载 ScreenOrientation.screenOrientationChange。 */
  private startScreenOrientationListener(): void {
    if (this.screenOrientationCallback !== null || this.screenOrientationStarting) return;
    this.screenOrientationStarting = true;
    const generation = this.screenOrientationGeneration + 1;
    this.screenOrientationGeneration = generation;
    try {
      window.getLastWindow(getContext()).then((lastWindow: window.Window): void => {
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
        console.error('LynxCapacitorModule', `ScreenOrientation listener setup failed: ${String(error)}`);
      });
    } catch (error) {
      this.screenOrientationStarting = false;
      console.error('LynxCapacitorModule', `ScreenOrientation listener setup failed: ${String(error)}`);
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
      console.error('LynxCapacitorModule', `ScreenOrientation listener removal failed: ${String(error)}`);
    }
  }

  /** 使用 IMEKit 控制当前获得焦点的 Lynx 输入框；resize/style 仍由宿主容器负责。 */
  private handleKeyboard(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    try {
      const controller = inputMethod.getInputMethodController();
      if (methodName === 'getResizeMode') {
        callback(this.success(callbackId, 'Keyboard', methodName, '{"mode":"native"}'));
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
        getContext().getApplicationContext().setFontSizeScale(value);
        callback(this.success(callbackId, 'TextZoom', methodName, '{"value":' + String(value) + '}'));
        return;
      }
      callback(this.failure(callbackId, 'TextZoom', methodName, 'UNIMPLEMENTED', 'TextZoom.' + methodName + ' is not implemented'));
    } catch (error) {
      callback(this.failure(callbackId, 'TextZoom', methodName, 'UNAVAILABLE', 'TextZoom operation failed: ' + String(error)));
    }
  }

  private handleGeolocation(callbackId: string, methodName: string, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    const permission: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
    let permissionState = 'prompt';
    try {
      const status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus(permission);
      permissionState = status === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : status === abilityAccessCtrl.PermissionStatus.DENIED ? 'denied' : 'prompt';
    } catch (error) {
      console.error('LynxCapacitorModule', 'Location permission status failed: ' + String(error));
    }
    if (methodName === 'checkPermissions') {
      callback(this.success(callbackId, 'Geolocation', methodName, '{"location":' + JSON.stringify(permissionState) + ',"coarseLocation":' + JSON.stringify(permissionState) + '}'));
      return;
    }
    if (methodName === 'requestPermissions') {
      if (permissionState === 'granted') {
        callback(this.success(callbackId, 'Geolocation', methodName, '{"location":"granted","coarseLocation":"granted"}'));
        return;
      }
      try {
        const context = getContext() as common.UIAbilityContext;
        abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [permission]).then(() => {
          let state = 'prompt';
          try {
            const status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus(permission);
            state = status === abilityAccessCtrl.PermissionStatus.GRANTED ? 'granted' : status === abilityAccessCtrl.PermissionStatus.DENIED ? 'denied' : 'prompt';
          } catch (error) {
            console.error('LynxCapacitorModule', 'Location permission status failed: ' + String(error));
          }
          callback(this.success(callbackId, 'Geolocation', methodName, '{"location":' + JSON.stringify(state) + ',"coarseLocation":' + JSON.stringify(state) + '}'));
        }).catch((error: Object) => {
          callback(this.failure(callbackId, 'Geolocation', methodName, 'PERMISSION_DENIED', 'Location permission request failed: ' + String(error)));
        });
      } catch (error) {
        callback(this.failure(callbackId, 'Geolocation', methodName, 'PERMISSION_DENIED', 'Location permission request failed: ' + String(error)));
      }
      return;
    }
    if (methodName === 'watchPosition' || methodName === 'clearWatch') {
      callback(this.failure(callbackId, 'Geolocation', methodName, 'UNAVAILABLE', 'Geolocation watcher requires a lifecycle-owned location callback coordinator'));
      return;
    }
    if (methodName !== 'getCurrentPosition') {
      callback(this.failure(callbackId, 'Geolocation', methodName, 'UNIMPLEMENTED', 'Geolocation.' + methodName + ' is not implemented'));
      return;
    }
    if (permissionState !== 'granted') {
      if (!permissionsAlreadyGranted) {
        this.ensureHarmonyPermissions(callbackId, 'Geolocation', methodName, [permission], callback, (): void => {
          this.handleGeolocation(callbackId, methodName, callback, true);
        });
        return;
      }
      callback(this.failure(callbackId, 'Geolocation', methodName, 'PERMISSION_DENIED', 'Location permission is not granted'));
      return;
    }
    try {
      geoLocationManager.getCurrentLocation().then((location: geoLocationManager.Location) => {
        const data = '{"timestamp":' + String(location.timeStamp) + ',"coords":{"latitude":' + String(location.latitude) + ',"longitude":' + String(location.longitude) + ',"accuracy":' + String(location.accuracy) + ',"altitude":' + String(location.altitude) + ',"altitudeAccuracy":null,"speed":' + String(location.speed) + ',"heading":null,"magneticHeading":null,"trueHeading":null,"headingAccuracy":null,"course":null}}';
        callback(this.success(callbackId, 'Geolocation', methodName, data));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'Geolocation', methodName, 'POSITION_UNAVAILABLE', 'Location request failed: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'Geolocation', methodName, 'POSITION_UNAVAILABLE', 'Location request failed: ' + String(error)));
    }
  }

  private startGeolocationWatch(callbackId: string, options: Record<string, Object>, callback: (resultJSON: string) => void, permissionsAlreadyGranted: boolean = false): void {
    let granted = false;
    try {
      const permission: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
      granted = abilityAccessCtrl.createAtManager().getSelfPermissionStatus(permission) === abilityAccessCtrl.PermissionStatus.GRANTED;
    } catch (error) {
      console.error('LynxCapacitorModule', 'Location permission status failed: ' + String(error));
    }
    if (!granted) {
      if (!permissionsAlreadyGranted) {
        this.ensureHarmonyPermissions(callbackId, 'Geolocation', 'watchPosition', ['ohos.permission.APPROXIMATELY_LOCATION'], callback, (): void => {
          this.startGeolocationWatch(callbackId, options, callback, true);
        });
        return;
      }
      callback(this.failure(callbackId, 'Geolocation', 'watchPosition', 'PERMISSION_DENIED', 'Location permission is not granted'));
      return;
    }
    this.geolocationWatchCallbacks.set(callbackId, callback);
    if (this.geolocationLocationCallback !== null) return;
    const onLocation = (location: geoLocationManager.Location): void => {
      const data = '{"timestamp":' + String(location.timeStamp) + ',"coords":{"latitude":' + String(location.latitude) + ',"longitude":' + String(location.longitude) + ',"accuracy":' + String(location.accuracy) + ',"altitude":' + String(location.altitude) + ',"altitudeAccuracy":null,"speed":' + String(location.speed) + ',"heading":null,"magneticHeading":null,"trueHeading":null,"headingAccuracy":null,"course":null}}';
      this.geolocationWatchCallbacks.forEach((watchCallback: (resultJSON: string) => void, watchId: string) => {
        watchCallback(this.success(watchId, 'Geolocation', 'watchPosition', data, true));
      });
    };
    const request: geoLocationManager.LocationRequest = { timeInterval: Number(options['interval'] ?? 5) };
    try {
      this.geolocationLocationCallback = onLocation;
      geoLocationManager.on('locationChange', request, onLocation);
    } catch (error) {
      this.geolocationLocationCallback = null;
      this.geolocationWatchCallbacks.delete(callbackId);
      callback(this.failure(callbackId, 'Geolocation', 'watchPosition', 'POSITION_UNAVAILABLE', 'Unable to start location watcher: ' + String(error)));
    }
  }

  private stopGeolocationWatch(watchId: string): void {
    if (watchId.length > 0) this.geolocationWatchCallbacks.delete(watchId);
    if (this.geolocationWatchCallbacks.size > 0 || this.geolocationLocationCallback === null) return;
    try {
      geoLocationManager.off('locationChange', this.geolocationLocationCallback);
    } catch (error) {
      console.error('LynxCapacitorModule', 'Location watcher removal failed: ' + String(error));
    }
    this.geolocationLocationCallback = null;
  }

  private handleApp(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'exitApp' || methodName === 'minimizeApp') {
      try {
        const context = getContext() as common.UIAbilityContext;
        const operation = methodName === 'exitApp' ? context.terminateSelf() : context.moveAbilityToBackground();
        operation.then((): void => {
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
        callback(this.success(callbackId, 'App', methodName, `{"isActive":${String(LynxCapacitorModule.appIsActive)}}`));
        break;
      case 'getLaunchUrl':
        callback(this.success(callbackId, 'App', methodName, LynxCapacitorModule.launchUrl.length === 0 ? '{"url":null}' : `{"url":${JSON.stringify(LynxCapacitorModule.launchUrl)}}`));
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
      const context = getContext() as common.UIAbilityContext;
      context.openLink(url).then(() => {
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
      const context = getContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable'],
      };
      context.startAbility(want).then(() => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window): void => {
        const uiContext: UIContext = lastWindow.getUIContext();
        const params: LynxCapacitorWebViewDialogParams = {
          url: url,
          headers: this.browserHeaders(options),
          onPageBegin: (_pageUrl: string): void => {},
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
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).then((): void => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window): void => {
        const uiContext: UIContext = lastWindow.getUIContext();
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
        uiContext.getPromptAction().openCustomDialog(contentNode, dialogOptions).then((): void => {
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
    let uri = '';
    if (methodName.endsWith('FromUrl')) {
      uri = String(options['url'] ?? '');
      if (!(uri.startsWith('https://') || uri.startsWith('http://'))) {
        callback(this.failure(callbackId, 'FileViewer', methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
        return;
      }
    } else if (methodName.endsWith('FromLocalPath')) {
      const path = String(options['path'] ?? '');
      if (path.length === 0 || path.includes('..')) {
        callback(this.failure(callbackId, 'FileViewer', methodName, 'INVALID_ARGUMENT', 'path is invalid'));
        return;
      }
      uri = path.startsWith('file://') ? path : 'file://' + path;
    } else if (methodName.endsWith('FromResources')) {
      callback(this.failure(callbackId, 'FileViewer', methodName, 'UNAVAILABLE', 'Harmony rawfile resource export requires a host file provider'));
      return;
    } else {
      callback(this.failure(callbackId, 'FileViewer', methodName, 'UNIMPLEMENTED', 'FileViewer.' + methodName + ' is not implemented'));
      return;
    }
    try {
      const context = getContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: String(options['mimeType'] ?? '*/*'),
      };
      context.startAbility(want).then(() => {
        callback(this.success(callbackId, 'FileViewer', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'FileViewer', methodName, 'UNAVAILABLE', 'Unable to open file: ' + String(error)));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'FileViewer', methodName, 'UNAVAILABLE', 'Unable to open file: ' + String(error)));
    }
  }

  private handleDevice(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    const model = JSON.stringify(String(deviceInfo.productModel));
    const manufacturer = JSON.stringify(String(deviceInfo.manufacture));
    const name = JSON.stringify(String(deviceInfo.productModelAlias).length > 0 ? String(deviceInfo.productModelAlias) : String(deviceInfo.productModel));
    const osVersion = JSON.stringify(String(deviceInfo.osFullName));
    switch (methodName) {
      case 'getInfo':
        callback(this.success(callbackId, 'Device', methodName, `{"model":${model},"platform":"harmony","operatingSystem":"harmony","osVersion":${osVersion},"manufacturer":${manufacturer},"name":${name},"isVirtual":false,"webViewVersion":""}`));
        break;
      case 'getId':
        try {
          callback(this.success(callbackId, 'Device', methodName, JSON.stringify({ identifier: this.deviceIdentifier() })));
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

  /** Android 目录中可发现但当前 Harmony 不提供等价实现的生物识别能力。 */
  private handleBiometrics(callbackId: string, methodName: string, callback: (resultJSON: string) => void): void {
    callback(this.failure(callbackId, 'Biometrics', methodName, 'UNSUPPORTED', `Biometrics.${methodName} is not supported by the Harmony NativeModule`));
  }

  /**
   * Audio adapter 的 bridge 外壳。adapter 只返回业务 data/error，这里负责补齐和其它
   * Harmony 能力一致的 callbackId/pluginId/methodName/success/data/save envelope。
   */
  private handleAudio(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const claimed = LynxHarmonyAudioCapabilities.dispatch(
        getContext() as common.UIAbilityContext,
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

  private deviceIdentifier(): string {
    const store = this.dataPreferences;
    if (store === null) throw new Error('Preferences are unavailable');
    const stored = store.getSync(LynxCapacitorModule.deviceIdentifierKey, null);
    if (typeof stored === 'string' && stored.length > 0) return stored;
    const generated = 'harmony-' + util.generateRandomUUID(false);
    store.putSync(LynxCapacitorModule.deviceIdentifierKey, generated);
    store.flushSync();
    return generated;
  }

  private handlePreferences(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    const key = String(options['key'] ?? '');
    if (methodName === 'get' || methodName === 'set' || methodName === 'remove') {
      if (key.length === 0) {
        callback(this.failure(callbackId, 'Preferences', methodName, 'INVALID_ARGUMENT', 'key is required'));
        return;
      }
      if (this.isReservedPreferenceKey(key)) {
        callback(this.failure(callbackId, 'Preferences', methodName, 'INVALID_ARGUMENT', 'key is reserved by LynxCapacitorModule'));
        return;
      }
    }
    switch (methodName) {
      case 'configure':
      case 'migrate':
      case 'removeOld':
        callback(this.success(callbackId, 'Preferences', methodName));
        break;
      case 'get': {
        const value = this.dataPreferences?.getSync(key, null);
        const valueJSON = value === null || value === undefined ? 'null' : JSON.stringify(String(value));
        callback(this.success(callbackId, 'Preferences', methodName, `{"value":${valueJSON}}`));
        break;
      }
      case 'set':
        this.dataPreferences?.putSync(key, String(options['value'] ?? ''));
        this.dataPreferences?.flushSync();
        if (this.preferenceKeys.indexOf(key) < 0) this.preferenceKeys.push(key);
        this.persistPreferenceKeys();
        callback(this.success(callbackId, 'Preferences', methodName));
        break;
      case 'remove':
        this.dataPreferences?.deleteSync(key);
        this.dataPreferences?.flushSync();
        this.preferenceKeys = this.preferenceKeys.filter((item: string) => item !== key);
        this.persistPreferenceKeys();
        callback(this.success(callbackId, 'Preferences', methodName));
        break;
      case 'clear':
        this.preferenceKeys.slice().forEach((userKey: string): void => {
          this.dataPreferences?.deleteSync(userKey);
        });
        this.dataPreferences?.flushSync();
        this.preferenceKeys = [];
        this.persistPreferenceKeys();
        callback(this.success(callbackId, 'Preferences', methodName));
        break;
      case 'keys':
        callback(this.success(callbackId, 'Preferences', methodName, `{"keys":${JSON.stringify(this.preferenceKeys)}}`));
        break;
      default:
        callback(this.failure(callbackId, 'Preferences', methodName, 'UNIMPLEMENTED', `Preferences.${methodName} is not implemented`));
    }
  }

  private isReservedPreferenceKey(key: string): boolean {
    return key === LynxCapacitorModule.deviceIdentifierKey
      || key === LynxCapacitorModule.preferenceKeysKey
      || key === LynxCapacitorModule.localNotificationIdsKey
      || key === LynxCapacitorModule.localNotificationChannelsKey;
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
    const rawUrl = String(options['url'] ?? '');
    if (!(rawUrl.startsWith('https://') || rawUrl.startsWith('http://'))) {
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
      return;
    }
    const url = this.appendHttpParams(rawUrl, options);
    const requestedMethod = methodName === 'request' ? String(options['method'] ?? 'GET').toUpperCase() : methodName.toUpperCase();
    const supportedMethods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];
    if (supportedMethods.indexOf(requestedMethod) < 0) {
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', 'method must be GET, POST, PUT, PATCH, DELETE, HEAD, or OPTIONS'));
      return;
    }
    if (options['disableRedirects'] !== undefined && options['disableRedirects'] !== null && typeof options['disableRedirects'] !== 'boolean') {
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', 'disableRedirects must be boolean'));
      return;
    }
    if (options['disableRedirects'] === true) {
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'UNAVAILABLE', 'NetworkKit adapter has no verified disableRedirects equivalent'));
      return;
    }
    let readTimeout: number | null = null;
    let connectTimeout: number | null = null;
    try {
      readTimeout = this.httpTimeout(options, 'readTimeout');
      connectTimeout = this.httpTimeout(options, 'connectTimeout');
    } catch (error) {
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', String(error)));
      return;
    }
    const requestMethod: http.RequestMethod = this.httpMethod(requestedMethod);
    const requestOptions: http.HttpRequestOptions = {
      method: requestMethod,
      expectDataType: http.HttpDataType.STRING,
    };
    const responseType = String(options['responseType'] ?? 'text').toLowerCase();
    if (responseType === 'arraybuffer' || responseType === 'blob') requestOptions.expectDataType = http.HttpDataType.ARRAY_BUFFER;
    if (readTimeout !== null) requestOptions.readTimeout = readTimeout;
    if (connectTimeout !== null) requestOptions.connectTimeout = connectTimeout;
    if (requestedMethod === 'PATCH') requestOptions.customMethod = 'PATCH';
    const headerValue = options['headers'];
    if (headerValue !== null && headerValue !== undefined) requestOptions.header = headerValue;
    const bodyValue = options['data'];
    const dataType = String(options['dataType'] ?? '').toLowerCase();
    if (bodyValue !== null && bodyValue !== undefined && dataType === 'file') {
      try {
        requestOptions.extraData = new util.Base64Helper().decodeSync(String(bodyValue)).buffer as ArrayBuffer;
      } catch (error) {
        callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', `dataType=file requires valid base64: ${String(error)}`));
        return;
      }
    } else if (bodyValue !== null && bodyValue !== undefined && dataType === 'formdata') {
      try {
        const contentType = headerValue === undefined || headerValue === null ? '' : this.httpHeaderValue(headerValue, 'content-type');
        const multipart = this.httpMultipartBody(bodyValue, contentType);
        requestOptions.extraData = multipart.body;
        const headers = this.httpHeaders(headerValue);
        headers['Content-Type'] = multipart.contentType;
        requestOptions.header = headers;
      } catch (error) {
        callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'INVALID_ARGUMENT', `dataType=formData is invalid: ${String(error)}`));
        return;
      }
    } else if (bodyValue !== null && bodyValue !== undefined) {
      requestOptions.extraData = typeof bodyValue === 'string' ? bodyValue : JSON.stringify(bodyValue);
    }

    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      request.request(url, requestOptions).then((response: http.HttpResponse) => {
        const responseContentType = this.httpHeaderValue(response.header, 'content-type').toLowerCase();
        const isJSONResponse = responseContentType.indexOf('application/json') >= 0 ||
          (Number(response.responseCode) >= 200 && Number(response.responseCode) < 300 && responseType === 'json');
        let resultText: string = '';
        let dataJSON: string;
        if (response.result instanceof ArrayBuffer) {
          const binary = response.result as ArrayBuffer;
          if (isJSONResponse || responseType === 'text' || responseType === 'document') {
            resultText = new util.TextDecoder().decode(new Uint8Array(binary));
            dataJSON = isJSONResponse && this.looksLikeJSON(resultText) ? resultText : JSON.stringify(resultText);
          } else {
            dataJSON = JSON.stringify(new util.Base64Helper().encodeToStringSync(new Uint8Array(binary)));
          }
        } else {
          resultText = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
          dataJSON = isJSONResponse && this.looksLikeJSON(resultText) ? resultText : JSON.stringify(resultText);
        }
        callback(this.success(callbackId, 'CapacitorHttp', methodName, `{"status":${String(response.responseCode)},"headers":${JSON.stringify(response.header)},"url":${JSON.stringify(url)},"data":${dataJSON}}`));
        request?.destroy();
      }).catch((error: Object) => {
        request?.destroy();
        callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'NETWORK', `HTTP request failed: ${String(error)}`));
      });
    } catch (error) {
      request?.destroy();
      callback(this.failure(callbackId, 'CapacitorHttp', methodName, 'NETWORK', `HTTP request failed: ${String(error)}`));
    }
  }

  /** 与 CapacitorHttp 的 params 约定一致：数组展开为重复 query key，并保留 fragment。 */
  private appendHttpParams(url: string, options: Record<string, Object>): string {
    const rawParams = options['params'];
    if (rawParams === null || rawParams === undefined || typeof rawParams !== 'object' || Array.isArray(rawParams)) return url;
    const params = rawParams as Record<string, Object>;
    const shouldEncode = options['shouldEncodeUrlParams'] === undefined || options['shouldEncodeUrlParams'] === null
      ? true
      : Boolean(options['shouldEncodeUrlParams']);
    const pairs: string[] = [];
    Object.keys(params).forEach((key: string): void => {
      const rawKey = shouldEncode ? encodeURIComponent(key) : key;
      const rawValue = params[key];
      const values: Array<Object> = Array.isArray(rawValue) ? rawValue as Array<Object> : [rawValue];
      values.forEach((value: Object): void => {
        const text = String(value);
        pairs.push(rawKey + '=' + (shouldEncode ? encodeURIComponent(text) : text));
      });
    });
    if (pairs.length === 0) return url;
    const hashIndex = url.indexOf('#');
    const beforeFragment = hashIndex >= 0 ? url.substring(0, hashIndex) : url;
    const fragment = hashIndex >= 0 ? url.substring(hashIndex) : '';
    const separator = beforeFragment.indexOf('?') < 0
      ? '?'
      : beforeFragment.endsWith('?') || beforeFragment.endsWith('&') ? '' : '&';
    return beforeFragment + separator + pairs.join('&') + fragment;
  }

  private httpMethod(raw: string): http.RequestMethod {
    switch (raw) {
      case 'POST': return http.RequestMethod.POST;
      case 'PUT': return http.RequestMethod.PUT;
      case 'PATCH': return http.RequestMethod.POST;
      case 'DELETE': return http.RequestMethod.DELETE;
      case 'HEAD': return http.RequestMethod.HEAD;
      case 'OPTIONS': return http.RequestMethod.OPTIONS;
      default: return http.RequestMethod.GET;
    }
  }

  /** NetworkKit 的 timeout 单位也是毫秒；非法值不能静默退回 SDK 默认值。 */
  private httpTimeout(options: Record<string, Object>, key: string): number | null {
    const raw = options[key];
    if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim().length === 0)) return null;
    const value = Number(raw);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${key} must be a finite non-negative number`);
    return Math.floor(value);
  }

  /** NetworkKit header key 的大小写不固定，按 HTTP 的不区分大小写语义读取。 */
  private httpHeaderValue(headers: Object, key: string): string {
    const values = headers as Record<string, Object>;
    const actualKey = Object.keys(values).find((name: string): boolean => name.toLowerCase() === key.toLowerCase());
    return actualKey === undefined ? '' : String(values[actualKey]);
  }

  /** 复制 HTTP header，供 multipart 自动补齐 boundary。 */
  private httpHeaders(value: Object | undefined): Record<string, Object> {
    const output: Record<string, Object> = {};
    if (value !== undefined && value !== null && typeof value === 'object') {
      const source = value as Record<string, Object>;
      Object.keys(source).forEach((key: string): void => { output[key] = source[key]; });
    }
    return output;
  }

  /** 将 native bridge 序列化的 FormData entries 组装为 NetworkKit 可发送的 ArrayBuffer。 */
  private httpMultipartBody(data: Object, originalContentType: string): LynxCapacitorHttpMultipartBody {
    if (!Array.isArray(data)) throw new Error('data must be an entry array');
    const marker = 'boundary=';
    const markerIndex = originalContentType.toLowerCase().indexOf(marker);
    let boundary = markerIndex >= 0 ? originalContentType.substring(markerIndex + marker.length).split(';')[0].trim() : '';
    if (boundary.startsWith('"') && boundary.endsWith('"')) boundary = boundary.substring(1, boundary.length - 1);
    if (boundary.length === 0) boundary = `lynx-capacitor-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const encoder = new util.TextEncoder();
    const chunks: Uint8Array[] = [];
    (data as Array<Object>).forEach((rawEntry: Object): void => {
      if (rawEntry === null || typeof rawEntry !== 'object') throw new Error('entry must be an object');
      const entry = rawEntry as Record<string, Object>;
      const key = String(entry['key'] ?? '');
      const type = String(entry['type'] ?? '');
      const value = entry['value'];
      if (key.length === 0 || value === undefined || value === null) throw new Error('entry key and value are required');
      if (type === 'string') {
        chunks.push(encoder.encode(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${String(value)}\r\n`));
      } else if (type === 'base64File') {
        const fileName = String(entry['fileName'] ?? 'file');
        const fileContentType = String(entry['contentType'] ?? 'application/octet-stream');
        chunks.push(encoder.encode(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"; filename="${fileName}"\r\nContent-Type: ${fileContentType}\r\nContent-Transfer-Encoding: binary\r\n\r\n`));
        chunks.push(new util.Base64Helper().decodeSync(String(value)));
        chunks.push(encoder.encode('\r\n'));
      } else {
        throw new Error(`unsupported entry type: ${type}`);
      }
    });
    chunks.push(encoder.encode(`--${boundary}--\r\n`));
    let length = 0;
    chunks.forEach((chunk: Uint8Array): void => { length += chunk.byteLength; });
    const output = new Uint8Array(length);
    let offset = 0;
    chunks.forEach((chunk: Uint8Array): void => {
      output.set(chunk, offset);
      offset += chunk.byteLength;
    });
    const result: LynxCapacitorHttpMultipartBody = {
      body: output.buffer as ArrayBuffer,
      contentType: `multipart/form-data; boundary=${boundary}`,
    };
    return result;
  }

  private looksLikeJSON(value: string): boolean {
    const trimmed = value.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']')) || trimmed === 'null' || trimmed === 'true' || trimmed === 'false' || /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(trimmed);
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window): void => {
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
      console.error('LynxCapacitorModule', `Toast close failed: ${String(error)}`);
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
        window.getLastWindow(getContext()).then(() => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => {
        return lastWindow.setWindowKeepScreenOn(value);
      }).then(() => {
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
      window.getLastWindow(getContext()).then((lastWindow: window.Window) => {
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
        callback(this.success(callbackId, 'SafeArea', methodName));
      }).catch((error: Object) => {
        callback(this.failure(callbackId, 'SafeArea', methodName, 'UNAVAILABLE', `SafeArea operation failed: ${String(error)}`));
      });
    } catch (error) {
      callback(this.failure(callbackId, 'SafeArea', methodName, 'UNAVAILABLE', `SafeArea operation failed: ${String(error)}`));
    }
  }

  private handleFilesystem(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    try {
      const path = this.resolveFilesystemPath(options);
      switch (methodName) {
        case 'checkPermissions':
        case 'requestPermissions':
          callback(this.success(callbackId, 'Filesystem', methodName, '{"publicStorage":"granted"}'));
          return;
        case 'readFileInChunks': {
          const chunkSize = Math.max(1, Math.min(Number(options['chunkSize'] ?? 65536), 1048576));
          const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
          try {
            while (true) {
              const buffer = new ArrayBuffer(chunkSize);
              const count = fileIo.readSync(file.fd, buffer);
              if (count <= 0) break;
              const value = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer, 0, count));
              callback(this.success(callbackId, 'Filesystem', methodName, '{"data":' + JSON.stringify(value) + '}', true));
            }
            callback(this.success(callbackId, 'Filesystem', methodName, '{"data":""}', false));
          } finally {
            fileIo.closeSync(file);
          }
          return;
        }
        case 'writeFile':
          this.writeFile(path, String(options['data'] ?? ''), String(options['encoding'] ?? ''));
          callback(this.success(callbackId, 'Filesystem', methodName, `{"uri":${JSON.stringify(this.fileUri(path))}}`));
          return;
        case 'appendFile':
          this.writeFile(path, String(options['data'] ?? ''), String(options['encoding'] ?? ''), true);
          callback(this.success(callbackId, 'Filesystem', methodName));
          return;
        case 'readFile':
          callback(this.success(callbackId, 'Filesystem', methodName, `{"data":${JSON.stringify(this.readFile(path, String(options['encoding'] ?? '')))}}`));
          return;
        case 'deleteFile':
          fileIo.unlinkSync(path);
          callback(this.success(callbackId, 'Filesystem', methodName));
          return;
        case 'mkdir':
          fileIo.mkdirSync(path, true);
          callback(this.success(callbackId, 'Filesystem', methodName));
          return;
        case 'rmdir':
          fileIo.rmdirSync(path);
          callback(this.success(callbackId, 'Filesystem', methodName));
          return;
        case 'readdir':
          callback(this.success(callbackId, 'Filesystem', methodName, `{"files":${this.listFilesJSON(path)}}`));
          return;
        case 'getUri':
          callback(this.success(callbackId, 'Filesystem', methodName, `{"uri":${JSON.stringify(this.fileUri(path))}}`));
          return;
        case 'stat':
          callback(this.success(callbackId, 'Filesystem', methodName, this.statJSON(path)));
          return;
        case 'rename': {
          const target = this.resolveFilesystemPath(options, 'to');
          fileIo.renameSync(path, target);
          callback(this.success(callbackId, 'Filesystem', methodName, `{"uri":${JSON.stringify(this.fileUri(target))}}`));
          return;
        }
        case 'copy': {
          const target = this.resolveFilesystemPath(options, 'to');
          fileIo.copyFileSync(path, target);
          callback(this.success(callbackId, 'Filesystem', methodName, `{"uri":${JSON.stringify(this.fileUri(target))}}`));
          return;
        }
        case 'downloadFile': {
          const url = String(options['url'] ?? '');
          if (!(url.startsWith('https://') || url.startsWith('http://'))) {
            callback(this.failure(callbackId, 'Filesystem', methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
            return;
          }
          let request: http.HttpRequest | null = null;
          try {
            request = http.createHttp();
            const requestOptions: http.HttpRequestOptions = {
              method: http.RequestMethod.GET,
              expectDataType: http.HttpDataType.ARRAY_BUFFER,
            };
            const headerValue = options['headers'];
            if (headerValue !== null && headerValue !== undefined) requestOptions.header = headerValue;
            const onReceiveProgress = (info: http.DataReceiveProgressInfo): void => {
              this.emitTransferProgress('Filesystem', 'download', url, info.receiveSize, info.totalSize);
            };
            request.on('dataReceiveProgress', onReceiveProgress);
            const cleanup = (): void => {
              request?.off('dataReceiveProgress', onReceiveProgress);
              request?.destroy();
            };
            request.request(url, requestOptions).then((response: http.HttpResponse) => {
              if (Number(response.responseCode) < 200 || Number(response.responseCode) >= 300 || !(response.result instanceof ArrayBuffer)) {
                cleanup();
                callback(this.failure(callbackId, 'Filesystem', methodName, 'NETWORK', `Download failed with HTTP ${String(response.responseCode)}`));
                return;
              }
              try {
                const parent = path.substring(0, path.lastIndexOf('/'));
                if (parent.length > 0) fileIo.mkdirSync(parent, true);
                const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
                fileIo.writeSync(file.fd, response.result);
                fileIo.closeSync(file);
                cleanup();
                callback(this.success(callbackId, 'Filesystem', methodName, `{"path":${JSON.stringify(this.fileUri(path))},"bytes":${String(response.result.byteLength)},"statusCode":${String(response.responseCode)}}`));
              } catch (error) {
                cleanup();
                callback(this.failure(callbackId, 'Filesystem', methodName, 'IO', 'Unable to write downloaded file: ' + String(error)));
              }
            }).catch((error: Object) => {
              cleanup();
              callback(this.failure(callbackId, 'Filesystem', methodName, 'NETWORK', 'Download failed: ' + String(error)));
            });
          } catch (error) {
            request?.destroy();
            callback(this.failure(callbackId, 'Filesystem', methodName, 'NETWORK', 'Download failed: ' + String(error)));
          }
          return;
        }
        default:
          callback(this.failure(callbackId, 'Filesystem', methodName, 'UNAVAILABLE', `Filesystem.${methodName} requires an additional file adapter`));
      }
    } catch (error) {
      callback(this.failure(callbackId, 'Filesystem', methodName, 'IO', `Filesystem operation failed: ${String(error)}`));
    }
  }

  private handleFileTransfer(callbackId: string, methodName: string, options: Record<string, Object>, callback: (resultJSON: string) => void): void {
    if (methodName === 'getStatus') {
      const operationId = String(options['operationId'] ?? '').trim();
      if (operationId.length === 0) {
        callback(this.failure(callbackId, 'FileTransfer', methodName, 'INVALID_ARGUMENT', 'getStatus requires operationId'));
        return;
      }
      const task = this.fileTransferTasks.get(operationId);
      if (task === undefined) {
        callback(this.failure(callbackId, 'FileTransfer', methodName, 'NOT_FOUND', 'File transfer operation was not found'));
        return;
      }
      callback(this.success(callbackId, 'FileTransfer', methodName, JSON.stringify(task.status)));
      return;
    }
    if (methodName === 'cancel') {
      const operationId = String(options['operationId'] ?? '').trim();
      if (operationId.length === 0) {
        callback(this.failure(callbackId, 'FileTransfer', methodName, 'INVALID_ARGUMENT', 'cancel requires operationId'));
        return;
      }
      const task = this.fileTransferTasks.get(operationId);
      if (task === undefined) {
        callback(this.failure(callbackId, 'FileTransfer', methodName, 'NOT_FOUND', 'File transfer operation was not found'));
        return;
      }
      if (task.completed) {
        callback(this.success(callbackId, 'FileTransfer', methodName, JSON.stringify({ operationId: operationId, state: task.status.state, cancelled: false })));
        return;
      }
      task.cancelled = true;
      task.status = { operationId: operationId, state: 'cancelling', cancelled: true } as LynxCapacitorFileTransferStatus;
      try { task.request.destroy(); } catch (error) { console.error('LynxCapacitorModule', `FileTransfer cancel failed: ${String(error)}`); }
      this.finishFileTransferFailure(task, 'CANCELLED', 'File transfer was cancelled', 'cancelled');
      callback(this.success(callbackId, 'FileTransfer', methodName, JSON.stringify({ operationId: operationId, state: 'cancelling', cancelled: true })));
      return;
    }
    if (methodName !== 'downloadFile') {
      callback(this.failure(callbackId, 'FileTransfer', methodName, 'UNIMPLEMENTED', `FileTransfer.${methodName} is not implemented`));
      return;
    }
    const url = String(options['url'] ?? '');
    if (!(url.startsWith('https://') || url.startsWith('http://'))) {
      callback(this.failure(callbackId, 'FileTransfer', methodName, 'INVALID_ARGUMENT', 'url must be HTTP(S)'));
      return;
    }
    let path: string;
    try {
      path = this.resolveFileTransferPath(options);
    } catch (error) {
      callback(this.failure(callbackId, 'FileTransfer', methodName, 'INVALID_ARGUMENT', String(error)));
      return;
    }
    let request: http.HttpRequest | null = null;
    let task: LynxCapacitorFileTransferTask | null = null;
    try {
      const transferRequest = http.createHttp();
      request = transferRequest;
      const operationId = util.generateRandomUUID(false);
      task = {
        operationId: operationId,
        callbackId: callbackId,
        request: transferRequest,
        callback: callback,
        status: { operationId: operationId, state: 'pending' } as LynxCapacitorFileTransferStatus,
        completed: false,
        cancelled: false,
      };
      this.fileTransferTasks.set(operationId, task);
      this.trimFileTransferHistory();
      if (methodName === 'downloadFile') {
        const requestOptions: http.HttpRequestOptions = { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER };
        const headerValue = options['headers'];
        if (headerValue !== null && headerValue !== undefined) requestOptions.header = headerValue;
        const timeout = Number(options['timeout'] ?? 0);
        if (Number.isFinite(timeout) && timeout > 0) {
          requestOptions.connectTimeout = Math.floor(timeout);
          requestOptions.readTimeout = Math.floor(timeout);
        }
        const onReceiveProgress = (info: http.DataReceiveProgressInfo): void => {
          if (task === null || task.completed) return;
          task.status = { operationId: operationId, state: 'running', bytes: info.receiveSize, total: info.totalSize } as LynxCapacitorFileTransferStatus;
              this.emitTransferProgress('FileTransfer', 'download', url, info.receiveSize, info.totalSize, operationId);
        };
        transferRequest.on('dataReceiveProgress', onReceiveProgress);
        task.status = { operationId: operationId, state: 'running', bytes: 0, total: null } as LynxCapacitorFileTransferStatus;
        transferRequest.request(url, requestOptions).then((response: http.HttpResponse) => {
          if (task === null || task.completed) return;
          if (task.cancelled) {
            this.finishFileTransferFailure(task, 'CANCELLED', 'File transfer was cancelled', 'cancelled');
            return;
          }
          if (Number(response.responseCode) < 200 || Number(response.responseCode) >= 300 || !(response.result instanceof ArrayBuffer)) {
            this.finishFileTransferFailure(task, 'NETWORK', `Download failed with HTTP ${String(response.responseCode)}`, 'failed');
            return;
          }
          try {
            const parent = path.substring(0, path.lastIndexOf('/'));
            if (parent.length > 0) fileIo.mkdirSync(parent, true);
            const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
            fileIo.writeSync(file.fd, response.result);
            fileIo.closeSync(file);
            this.finishFileTransferSuccess(task, path, response.result.byteLength, Number(response.responseCode));
          } catch (error) {
            this.finishFileTransferFailure(task, 'IO', `Unable to write downloaded file: ${String(error)}`, 'failed');
          }
        }).catch((error: Object) => {
          if (task === null || task.completed) return;
          this.finishFileTransferFailure(task, task.cancelled ? 'CANCELLED' : 'NETWORK', task.cancelled ? 'File transfer was cancelled' : `Download failed: ${String(error)}`, task.cancelled ? 'cancelled' : 'failed');
        });
        return;
      }
    } catch (error) {
      if (task !== null) {
        this.finishFileTransferFailure(task, 'IO', `FileTransfer failed: ${String(error)}`, 'failed');
        return;
      }
      request?.destroy();
      callback(this.failure(callbackId, 'FileTransfer', methodName, 'IO', `FileTransfer failed: ${String(error)}`));
    }
  }

  private resolveFileTransferPath(options: Record<string, Object>): string {
    const raw = String(options['path'] ?? '').trim();
    if (raw.length === 0 || raw.includes('..') || raw.includes('\u0000')) throw new Error('path is required and must not contain traversal');
    const context = getContext();
    if (raw.startsWith('/')) {
      const roots = [String(context.cacheDir), String(context.filesDir), String(context.tempDir)];
      if (roots.some((root: string) => raw === root || raw.startsWith(root + '/'))) return raw;
      throw new Error('path must be inside the app sandbox');
    }
    const directory = String(options['directory'] ?? 'CACHE').toUpperCase();
    let root = String(context.cacheDir);
    if (directory === 'DATA' || directory === 'FILES' || directory === 'DOCUMENTS' || directory === 'LIBRARY' || directory === 'APPLICATION_SUPPORT') root = String(context.filesDir);
    else if (directory === 'TEMPORARY') root = String(context.tempDir);
    else if (directory !== 'CACHE') throw new Error('directory is not supported');
    return `${root}/${raw}`;
  }

  private finishFileTransferSuccess(task: LynxCapacitorFileTransferTask, path: string, bytes: number, responseCode: number): void {
    if (task.completed) return;
    task.status = { operationId: task.operationId, state: 'completed', path: path, uri: this.fileUri(path), bytes: bytes, responseCode: responseCode } as LynxCapacitorFileTransferStatus;
    task.completed = true;
    try { task.request.destroy(); } catch (error) { console.error('LynxCapacitorModule', `FileTransfer cleanup failed: ${String(error)}`); }
    task.callback(this.success(task.callbackId, 'FileTransfer', 'downloadFile', JSON.stringify(task.status)));
  }

  private finishFileTransferFailure(task: LynxCapacitorFileTransferTask, code: string, message: string, state: string): void {
    if (task.completed) return;
    task.status = { operationId: task.operationId, state: state, code: code, message: message } as LynxCapacitorFileTransferStatus;
    task.completed = true;
    try { task.request.destroy(); } catch (error) { console.error('LynxCapacitorModule', `FileTransfer cleanup failed: ${String(error)}`); }
    task.callback(this.failure(task.callbackId, 'FileTransfer', 'downloadFile', code, message));
  }

  private trimFileTransferHistory(): void {
    if (this.fileTransferTasks.size <= 32) return;
    const removeIds: string[] = [];
    this.fileTransferTasks.forEach((task: LynxCapacitorFileTransferTask): void => {
      if (this.fileTransferTasks.size - removeIds.length <= 32) return;
      if (task.completed) removeIds.push(task.operationId);
    });
    removeIds.forEach((operationId: string): void => { this.fileTransferTasks.delete(operationId); });
  }

  private resolveFilesystemPath(options: Record<string, Object>, pathKey: string = 'path'): string {
    const relativePath = String(options[pathKey] ?? '');
    if (relativePath.includes('..') || relativePath.startsWith('/')) throw new Error('path traversal is not allowed');
    const context = getContext();
    const directory = String(options['directory'] ?? 'DATA').toUpperCase();
    let root: string = context.filesDir;
    if (directory === 'CACHE') root = context.cacheDir;
    else if (directory === 'TEMPORARY') root = context.tempDir;
    else if (directory === 'DOCUMENTS') root = `${context.filesDir}/Documents`;
    if (relativePath.length === 0) return root;
    return `${root}/${relativePath}`;
  }

  private writeFile(path: string, value: string, encoding: string, append: boolean = false): void {
    const parent = path.substring(0, path.lastIndexOf('/'));
    if (parent.length > 0) fileIo.mkdirSync(parent, true);
    const mode = append ? fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND : fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
    const file = fileIo.openSync(path, mode);
    try {
      if (encoding.toUpperCase() === 'UTF8' || encoding.toLowerCase() === 'utf8') fileIo.writeSync(file.fd, value);
      else fileIo.writeSync(file.fd, new util.Base64Helper().decodeSync(value).buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private readFile(path: string, encoding: string): string {
    if (encoding.toUpperCase() === 'UTF8' || encoding.toLowerCase() === 'utf8') return fileIo.readTextSync(path);
    const stat = fileIo.statSync(path);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const count = fileIo.readSync(file.fd, buffer);
      return new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer, 0, count));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private readBinaryFile(path: string): ArrayBuffer {
    const stat = fileIo.statSync(path);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const count = fileIo.readSync(file.fd, buffer);
      return count === stat.size ? buffer : buffer.slice(0, count);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private listFilesJSON(path: string): string {
    const values = fileIo.listFileSync(path);
    const result: string[] = [];
    values.forEach((name: string) => {
      const child = `${path}/${name}`;
      const stat = fileIo.statSync(child);
      result.push(`{"name":${JSON.stringify(name)},"type":${JSON.stringify((stat.mode & fileIo.OpenMode.DIR) !== 0 ? 'directory' : 'file')},"size":${String(stat.size)},"mtime":${String(stat.mtime)}}`);
    });
    return `[${result.join(',')}]`;
  }

  private statJSON(path: string): string {
    const stat = fileIo.statSync(path);
    const type = (stat.mode & fileIo.OpenMode.DIR) !== 0 ? 'directory' : 'file';
    return `{"type":${JSON.stringify(type)},"size":${String(stat.size)},"mtime":${String(stat.mtime)},"uri":${JSON.stringify(this.fileUri(path))}}`;
  }

  private fileUri(path: string): string {
    return `file://${path}`;
  }

  private initializePreferences(): void {
    try {
      this.dataPreferences = preferences.getPreferencesSync(getContext(), { name: 'lynx_capacitor_preferences' });
      const store = this.dataPreferences;
      if (store !== null) {
        const rawKeys = store.getSync(LynxCapacitorModule.preferenceKeysKey, null);
        if (typeof rawKeys === 'string' && rawKeys.length > 0) {
          try {
            const parsed: Object = JSON.parse(rawKeys) as Object;
            if (Array.isArray(parsed)) {
              const keys: string[] = [];
              (parsed as Array<Object>).forEach((value: Object): void => {
                const key = String(value);
                if (key.length > 0 && !this.isReservedPreferenceKey(key) && keys.indexOf(key) < 0) keys.push(key);
              });
              this.preferenceKeys = keys;
            }
          } catch (error) {
            console.error('LynxCapacitorModule', `Preference key index decode failed: ${error}`);
          }
        }
        const rawNotificationIds = store.getSync(LynxCapacitorModule.localNotificationIdsKey, null);
        if (typeof rawNotificationIds === 'string' && rawNotificationIds.length > 0) {
          try {
            const parsed: Object = JSON.parse(rawNotificationIds) as Object;
            if (Array.isArray(parsed)) {
              (parsed as Array<Object>).forEach((value: Object): void => {
                const id = Number(value);
                if (Number.isInteger(id) && id >= 0 && !this.localNotificationIds.has(id)) {
                  this.localNotificationIds.set(id, { id: id, title: '', body: '' });
                }
              });
            }
          } catch (error) {
            console.error('LynxCapacitorModule', `Local notification ID index decode failed: ${error}`);
          }
        }
        const rawNotificationChannels = store.getSync(LynxCapacitorModule.localNotificationChannelsKey, null);
        if (typeof rawNotificationChannels === 'string' && rawNotificationChannels.length > 0) {
          try {
            const parsed = JSON.parse(rawNotificationChannels) as Object;
            if (Array.isArray(parsed)) {
              (parsed as Array<Object>).forEach((value: Object): void => {
                if (value === null || typeof value !== 'object') return;
                const entry = value as Record<string, Object>;
                const id = String(entry['id'] ?? '').trim();
                if (id.length === 0 || this.localNotificationChannels.has(id)) return;
                let slotType: notificationManager.SlotType = notificationManager.SlotType.SERVICE_INFORMATION;
                try { slotType = this.notificationSlotType(entry['importance']); } catch (_) {}
                this.localNotificationChannels.set(id, {
                  id: id,
                  name: String(entry['name'] ?? id),
                  description: String(entry['description'] ?? ''),
                  importance: String(entry['importance'] ?? 'default'),
                  slotType: slotType,
                });
              });
            }
          } catch (error) {
            console.error('LynxCapacitorModule', `Local notification channel index decode failed: ${String(error)}`);
          }
        }
      }
    } catch (error) {
      this.dataPreferences = null;
      console.error('LynxCapacitorModule', `Preferences initialization failed: ${error}`);
    }
  }

  private persistPreferenceKeys(): void {
    const store = this.dataPreferences;
    if (store === null) return;
    store.putSync(LynxCapacitorModule.preferenceKeysKey, JSON.stringify(this.preferenceKeys));
    store.flushSync();
  }

  private persistLocalNotificationIds(): void {
    const store = this.dataPreferences;
    if (store === null) return;
    const ids: number[] = [];
    this.localNotificationIds.forEach((_value: LynxCapacitorLocalNotification, id: number): void => {
      ids.push(id);
    });
    store.putSync(LynxCapacitorModule.localNotificationIdsKey, JSON.stringify(ids));
    store.flushSync();
  }

  private persistLocalNotificationChannels(): void {
    const store = this.dataPreferences;
    if (store === null) return;
    const channels: Array<Object> = [];
    this.localNotificationChannels.forEach((channel: LynxCapacitorNotificationChannel): void => {
      const item: Record<string, Object> = {};
      item['id'] = channel.id;
      item['name'] = channel.name;
      item['description'] = channel.description;
      item['importance'] = channel.importance;
      channels.push(item);
    });
    store.putSync(LynxCapacitorModule.localNotificationChannelsKey, JSON.stringify(channels));
    store.flushSync();
  }

  private success(callbackId: string, pluginId: string, methodName: string, dataJSON: string = '{}', save: boolean = false): string {
    return LynxCapacitorEnvelope.successJSON(callbackId, pluginId, methodName, dataJSON, save);
  }

  private failure(callbackId: string, pluginId: string, methodName: string, code: string, message: string): string {
    return LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, code, message);
  }
}
