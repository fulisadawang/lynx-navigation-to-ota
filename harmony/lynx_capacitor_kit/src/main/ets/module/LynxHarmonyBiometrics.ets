import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxCapacitorHost } from './LynxCapacitorHost';

interface BiometricAvailability { types: Array<userAuth.UserAuthType>; type: string; reason: string | null; }

/** UserAuthenticationKit 的真实可用性与认证；无 executor/未登记属于设备条件。 */
export class LynxHarmonyBiometrics {
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly host: () => LynxCapacitorHost | null;
  constructor(owner: LynxHarmonyNativeOwner, host: () => LynxCapacitorHost | null) { this.owner = owner; this.host = host; }

  public dispatch(method: string, options: Record<string, Object>): Promise<Object> {
    this.owner.checkActive();
    const availability = this.availability();
    const data: Record<string, Object> = { type: availability.type, biometryType: availability.type, supportsFaceID: false, supportsTouchID: false, supportsOpticID: false, supportsFace: availability.types.includes(userAuth.UserAuthType.FACE), supportsFingerprint: availability.types.includes(userAuth.UserAuthType.FINGERPRINT) };
    if (method === 'getBiometryType') return Promise.resolve(data);
    if (method === 'isAvailable') {
      data['available'] = availability.types.length > 0;
      data['canEvaluatePolicy'] = availability.types.length > 0;
      data['reason'] = availability.reason;
      return Promise.resolve(data);
    }
    if (method !== 'authenticate') return Promise.reject(new Error('UNIMPLEMENTED: Biometrics.' + method));
    const host = this.host();
    if (host === null || !host.isVisible()) return Promise.reject(new Error('UNAVAILABLE: 生物认证需要当前前台页面'));
    const types = availability.types.slice();
    const allowCredential = options['allowDeviceCredential'] === true || options['fallbackToPasscode'] === true;
    if (allowCredential) {
      try { userAuth.getAvailableStatus(userAuth.UserAuthType.PIN, userAuth.AuthTrustLevel.ATL1); types.push(userAuth.UserAuthType.PIN); }
      catch (error) {
        const code = (error as BusinessError).code;
        if (code !== 12500005 && code !== 12500010) throw error;
      }
    }
    if (types.length === 0) return Promise.reject(new Error('UNAVAILABLE: ' + String(availability.reason ?? '没有可用的认证凭据')));
    return new Promise<Object>((resolve, reject): void => {
      const auth = userAuth.getUserAuthInstance({ challenge: new Uint8Array([]), authType: types, authTrustLevel: userAuth.AuthTrustLevel.ATL1 }, { title: String(options['reason'] ?? options['localizedReason'] ?? '请验证你的身份') });
      const key = 'biometrics:' + util.generateRandomUUID(false);
      let finished = false;
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult): void => {
          if (finished) return;
          finished = true;
          this.owner.disown(key);
          auth.off('result', callback);
          if (!this.owner.isActive) { reject(new Error('ACTIVITY_DESTROYED: 认证页面已销毁')); return; }
          if (result.result === 0) resolve({ authenticated: true, biometryType: availability.type, policy: allowCredential ? 'deviceOwnerAuthentication' : 'biometricsOnly' });
          else reject(new Error(this.code(result.result) + ': 系统认证结果 ' + String(result.result)));
        }
      };
      this.owner.own(key, (): void => {
        if (finished) return;
        finished = true;
        auth.off('result', callback);
        auth.cancel();
        reject(new Error('ACTIVITY_DESTROYED: 页面关闭取消认证'));
      });
      auth.on('result', callback);
      try { auth.start(); }
      catch (error) { this.owner.disown(key); auth.off('result', callback); reject(error as Object); }
    });
  }

  private availability(): BiometricAvailability {
    const types: Array<userAuth.UserAuthType> = [];
    let reason: string | null = null;
    [userAuth.UserAuthType.FACE, userAuth.UserAuthType.FINGERPRINT].forEach((type: userAuth.UserAuthType): void => {
      try { userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL1); types.push(type); }
      catch (error) {
        const native = error as BusinessError;
        if (native.code === 12500005 || native.code === 12500010) reason = native.code === 12500010 ? '当前设备尚未登记生物识别' : '当前设备没有该认证 executor';
        else throw error;
      }
    });
    return { types: types, type: types.includes(userAuth.UserAuthType.FACE) ? 'FACE' : types.includes(userAuth.UserAuthType.FINGERPRINT) ? 'FINGERPRINT' : 'NONE', reason: types.length > 0 ? null : reason };
  }

  private code(code: number): string {
    if (code === 12500003) return 'USER_CANCELLED';
    if (code === 12500004) return 'AUTHENTICATION_TIMEOUT';
    if (code === 12500009) return 'BIOMETRY_LOCKOUT';
    if (code === 12500005 || code === 12500010) return 'UNAVAILABLE';
    if (code === 201) return 'PERMISSION_DENIED';
    return 'AUTHENTICATION_FAILED';
  }
}
