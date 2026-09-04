import { describe, it, expect } from '@ohos/hypium';
import LynxCapacitorCatalog from '../main/ets/module/LynxCapacitorCatalog';
import LynxCapacitorEnvelope from '../main/ets/module/LynxCapacitorEnvelope';

interface ExpectedCapability {
  id: string;
  methods: Array<string>;
}

interface EnvelopeData {
  value: number;
}

const EXPECTED: Array<ExpectedCapability> = [
  { id: 'Device', methods: ['getInfo', 'getId', 'getBatteryInfo', 'getLanguageCode', 'getLanguageTag'] },
  { id: 'Biometrics', methods: ['isAvailable', 'getBiometryType', 'authenticate'] },
  { id: 'App', methods: ['getInfo', 'getState', 'getLaunchUrl'] },
  { id: 'AppLauncher', methods: ['canOpenUrl', 'openUrl'] },
  { id: 'Contacts', methods: ['checkPermissions', 'requestPermissions', 'save', 'find', 'remove'] },
  { id: 'Preferences', methods: ['set', 'get', 'keys', 'remove'] },
  { id: 'Dialog', methods: ['alert', 'confirm', 'prompt'] },
  { id: 'ActionSheet', methods: ['showActions'] },
  { id: 'Toast', methods: ['show', 'getCapabilities', 'cancel'] },
  { id: 'Haptics', methods: ['impact', 'notification', 'selection', 'vibrate', 'vibrateLong', 'vibrateWaveform', 'vibratePredefined', 'vibrateComposition', 'getCapabilities', 'cancel'] },
  { id: 'Share', methods: ['canShare', 'share'] },
  { id: 'Clipboard', methods: ['write', 'read'] },
  { id: 'Filesystem', methods: ['writeFile', 'readFile', 'readdir', 'stat', 'mkdir', 'getUri'] },
  { id: 'Camera', methods: ['checkPermissions', 'requestPermissions', 'getPhoto', 'pickImages', 'chooseFromGallery', 'takePhoto', 'recordVideo', 'playVideo'] },
  { id: 'Audio', methods: ['checkPermissions', 'requestPermissions', 'record', 'stopRecording', 'play', 'stopPlayback', 'getState'] },
  { id: 'FileTransfer', methods: ['downloadFile', 'getStatus', 'cancel'] },
  { id: 'FileViewer', methods: ['openDocumentFromLocalPath'] },
  { id: 'Network', methods: ['getStatus'] },
  { id: 'CapacitorHttp', methods: ['request', 'get', 'post'] },
  { id: 'CapacitorCookies', methods: ['setCookie', 'getCookies', 'clearAllCookies'] },
  { id: 'Browser', methods: ['open', 'close'] },
  { id: 'InAppBrowser', methods: ['openInWebView', 'close'] },
  { id: 'Geolocation', methods: ['checkPermissions', 'requestPermissions', 'getCurrentPosition'] },
  { id: 'Motion', methods: ['addListener', 'removeListener', 'removeAllListeners', 'start', 'stop'] },
  { id: 'StatusBar', methods: ['getInfo', 'setStyle', 'hide', 'show'] },
  { id: 'SystemBars', methods: ['setStyle'] },
  { id: 'ScreenOrientation', methods: ['orientation', 'lock', 'unlock'] },
  { id: 'ScreenReader', methods: ['isEnabled', 'speak'] },
  { id: 'TextZoom', methods: ['getPreferred', 'get', 'set'] },
  { id: 'Keyboard', methods: ['getResizeMode', 'setStyle', 'hide'] },
  { id: 'SplashScreen', methods: ['hide', 'show'] },
  { id: 'PrivacyScreen', methods: ['isEnabled', 'enable', 'disable'] },
  { id: 'Calendar', methods: ['createCalendar', 'createEvent', 'findEvents', 'deleteEvent', 'deleteCalendar', 'checkPermissions', 'requestPermissions', 'listCalendars'] },
  { id: 'LocalNotifications', methods: ['checkPermissions', 'requestPermissions', 'schedule', 'getPending', 'cancel', 'getDeliveredNotifications', 'createChannel', 'listChannels'] },
  { id: 'PushNotifications', methods: ['checkPermissions', 'requestPermissions', 'register'] },
  { id: 'CapacitorBarcodeScanner', methods: ['scanBarcode'] },
  { id: 'BackgroundRunner', methods: ['checkPermissions', 'requestPermissions', 'dispatchEvent'] },
  { id: 'KeepAwake', methods: ['isSupported', 'isKeptAwake', 'keepAwake', 'allowSleep'] },
  { id: 'SafeArea', methods: ['setSystemBarsStyle', 'hideSystemBars', 'showSystemBars'] },
  { id: 'CapacitorSQLite', methods: ['echo', 'createConnection', 'open', 'execute', 'run', 'query', 'close', 'isAvailable'] },
];

function headers(): Array<Record<string, Object>> {
  return JSON.parse(LynxCapacitorCatalog.headers()) as Array<Record<string, Object>>;
}

function methods(row: Record<string, Object>): Array<string> {
  const values = row['methods'] as Array<Record<string, Object>>;
  return values.map((value: Record<string, Object>) => String(value['name'] ?? ''));
}

function status(): Array<Record<string, Object>> {
  return JSON.parse(LynxCapacitorCatalog.status()) as Array<Record<string, Object>>;
}

export default function nativeCapabilityContractTest() {
  describe('Harmony NativeModule 单元契约', () => {
    it('目录包含 Android 完整的 40 个能力域和 146 个方法', 0, () => {
      const actual = headers();
      let count = 0;
      actual.forEach((row: Record<string, Object>) => { count += methods(row).length; });
      expect(actual.length).assertEqual(40);
      expect(count).assertEqual(146);
    });

    it('目录的能力域和方法顺序与 Android 一致', 0, () => {
      const actual = headers();
      EXPECTED.forEach((expected: ExpectedCapability, index: number) => {
        const row = actual[index];
        expect(row === undefined ? '' : String(row['name'] ?? '')).assertEqual(expected.id);
        expect(row === undefined ? [] : methods(row)).assertDeepEquals(expected.methods);
      });
    });

    it('目录所有方法都是 promise rtype', 0, () => {
      headers().forEach((row: Record<string, Object>) => {
        const values = row['methods'] as Array<Record<string, Object>>;
        values.forEach((value: Record<string, Object>) => expect(String(value['rtype'] ?? '')).assertEqual('promise'));
      });
    });

    it('目录 gate 接受核心方法并拒绝旧别名和额外能力', 0, () => {
      expect(LynxCapacitorCatalog.has('Audio', 'record')).assertTrue();
      expect(LynxCapacitorCatalog.has('Contacts', 'requestPermissions')).assertTrue();
      expect(LynxCapacitorCatalog.has('Haptics', 'vibrateLong')).assertTrue();
      expect(LynxCapacitorCatalog.has('FileTransfer', 'cancel')).assertTrue();
      expect(LynxCapacitorCatalog.has('CapacitorSQLite', 'isAvailable')).assertTrue();
      expect(LynxCapacitorCatalog.has('SQLite', 'open')).assertFalse();
      expect(LynxCapacitorCatalog.has('CapacitorBackgroundRunner', 'dispatchEvent')).assertFalse();
      expect(LynxCapacitorCatalog.has('HealthFitness', 'getData')).assertFalse();
      expect(LynxCapacitorCatalog.has('Audio', 'startRecording')).assertFalse();
    });

    it('状态目录覆盖 40 个能力域并明确 Android gap', 0, () => {
      const actual = status();
      expect(actual.length).assertEqual(40);
      expect(String(actual[1]?.['state'] ?? '')).assertEqual('unsupported');
      expect(String(actual[20]?.['state'] ?? '')).assertEqual('partial');
      expect(String(actual[36]?.['name'] ?? '')).assertEqual('BackgroundRunner');
      expect(String(actual[39]?.['name'] ?? '')).assertEqual('CapacitorSQLite');
    });

    it('成功 envelope 显式返回 save false 或 save true', 0, () => {
      const normalData: EnvelopeData = { value: 1 };
      const retainedData: EnvelopeData = { value: 2 };
      const normal = JSON.parse(LynxCapacitorEnvelope.success('c1', 'Device', 'getInfo', normalData)) as Record<string, Object>;
      const retained = JSON.parse(LynxCapacitorEnvelope.success('c2', 'Motion', 'addListener', retainedData, true)) as Record<string, Object>;
      expect(normal['success']).assertTrue();
      expect(normal['save']).assertFalse();
      expect(retained['save']).assertTrue();
      expect((normal['data'] as Record<string, Object>)['value']).assertEqual(1);
    });

    it('失败 envelope 保留身份、结构化错误和 save false', 0, () => {
      const result = JSON.parse(LynxCapacitorEnvelope.failure('c3', 'Biometrics', 'authenticate', 'UNSUPPORTED', 'not supported')) as Record<string, Object>;
      const error = result['error'] as Record<string, Object>;
      expect(result['success']).assertFalse();
      expect(result['save']).assertFalse();
      expect(result['pluginId']).assertEqual('Biometrics');
      expect(error['code']).assertEqual('UNSUPPORTED');
      expect(error['message']).assertEqual('not supported');
    });
  });
}
