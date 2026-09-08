import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { LynxOtaConfig } from './OtaModels';

/** Server 同义校验；序号和版本分量只按规范化十进制字符串比较。 */
class OtaContextNormalization {
  static normalizeUserId(value?: string | null): string | undefined {
    if (value === undefined || value === null) return undefined;
    if (/[\u0000-\u001f\u007f-\u009f]/.test(value)) throw new Error('invalid_user_id');
    const normalized = value.trim();
    if (normalized.length === 0) return undefined;
    if (OtaUserContext.utf8(normalized).length > 256) throw new Error('invalid_user_id');
    return normalized;
  }

  static decimal(value: string, allowZero: boolean = false): string {
    if (!/^[0-9]+$/.test(value)) throw new Error('invalid_decimal');
    const normalized = value.replace(/^0+/, '') || '0';
    if (!allowZero && normalized === '0') throw new Error('invalid_decimal');
    return normalized;
  }

  static compareDecimal(left: string, right: string): number {
    const a = OtaUserContext.decimal(left, true);
    const b = OtaUserContext.decimal(right, true);
    if (a.length !== b.length) return a.length < b.length ? -1 : 1;
    return a === b ? 0 : (a < b ? -1 : 1);
  }

  static normalizeVersionCode(value: string): string {
    const code = OtaUserContext.decimal(value.trim());
    if (OtaUserContext.compareDecimal(code, '9223372036854775807') > 0) throw new Error('invalid_version_code');
    return code;
  }

  static normalizeLynxSdkVersion(value: string): string {
    const version = value.trim();
    if (!/^[0-9]+(\.[0-9]+){0,2}$/.test(version)) throw new Error('invalid_sdk_version');
    const parts = version.split('.').map((part: string) => OtaUserContext.decimal(part, true));
    while (parts.length < 3) parts.push('0');
    return parts.join('.');
  }

  static compareVersion(left: string, right: string): number {
    const a = OtaUserContext.normalizeLynxSdkVersion(left).split('.');
    const b = OtaUserContext.normalizeLynxSdkVersion(right).split('.');
    for (let index = 0; index < 3; index += 1) {
      const order = OtaUserContext.compareDecimal(a[index], b[index]);
      if (order !== 0) return order;
    }
    return 0;
  }

  static utf8(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let index = 0; index < value.length; index += 1) {
      let point = value.charCodeAt(index);
      if (point >= 0xd800 && point <= 0xdbff) {
        const low = value.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) { point = 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00; index += 1; }
        else point = 0xfffd;
      } else if (point >= 0xdc00 && point <= 0xdfff) point = 0xfffd;
      if (point < 0x80) bytes.push(point);
      else if (point < 0x800) bytes.push(0xc0 | (point >> 6), 0x80 | (point & 63));
      else if (point < 0x10000) bytes.push(0xe0 | (point >> 12), 0x80 | ((point >> 6) & 63), 0x80 | (point & 63));
      else bytes.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 63), 0x80 | ((point >> 6) & 63), 0x80 | (point & 63));
    }
    return new Uint8Array(bytes);
  }

  static hash(value: string): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: OtaUserContext.utf8(value) });
    let hex = '';
    digest.digestSync().data.forEach((byte: number) => { hex += byte.toString(16).padStart(2, '0'); });
    return `sha256:${hex}`;
  }
}

/** 每个异步操作显式传递这一只读值；没有 TaskLocal/global operation context。 */
export class OtaUserContext extends OtaContextNormalization {
  readonly ownerId: string;
  readonly identityEpoch: number;
  readonly userId?: string;
  readonly audienceKey: string;
  readonly clientContextKey: string;
  readonly env: string;
  readonly hostApp: string;
  readonly platform: string = 'harmony';
  readonly versionCode?: string;
  readonly lynxSdkVersion?: string;
  readonly appVersion?: string;
  readonly nativeProtocolVersion?: string;
  readonly selectionEnabled: boolean;

  constructor(config: LynxOtaConfig, owner: string, epoch: number, userId: string | undefined, salt: string) {
    super();
    this.ownerId = owner;
    this.identityEpoch = epoch;
    this.userId = userId;
    this.env = config.environment;
    this.hostApp = config.hostApp;
    this.selectionEnabled = config.versionCode !== undefined;
    this.versionCode = config.versionCode === undefined ? undefined : OtaUserContext.normalizeVersionCode(config.versionCode);
    this.lynxSdkVersion = config.lynxSdkVersion === undefined ? undefined : OtaUserContext.normalizeLynxSdkVersion(config.lynxSdkVersion);
    if (this.selectionEnabled && this.lynxSdkVersion === undefined) throw new Error('missing_sdk_version');
    if (!this.selectionEnabled && (userId !== undefined || this.lynxSdkVersion !== undefined)) throw new Error('missing_version_code');
    this.appVersion = config.appVersion;
    this.nativeProtocolVersion = config.nativeProtocolVersion;
    this.audienceKey = userId === undefined ? 'anonymous' : OtaUserContext.hash(JSON.stringify([salt, this.env, this.hostApp, userId]));
    this.clientContextKey = OtaUserContext.hash(JSON.stringify([this.env, this.hostApp, this.platform, this.audienceKey,
      this.versionCode ?? '', this.lynxSdkVersion ?? '', this.appVersion ?? '', this.nativeProtocolVersion ?? '']));
  }
}

/** UI-thread identity box。同步注册与同步最终 rename 不包含 await，不能被另一 UI 操作插入。 */
export class OtaUserContextBox {
  private readonly config: LynxOtaConfig;
  private readonly ownerId: string;
  private readonly salt: string;
  private epoch: number = 0;
  private userId?: string;

  constructor(config: LynxOtaConfig) {
    this.config = config;
    this.userId = OtaUserContext.normalizeUserId(config.userId);
    const random: Uint8Array = cryptoFramework.createRandom().generateRandomSync(32).data;
    this.ownerId = Array.from(random).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
    this.salt = config.versionCode === undefined ? this.ownerId : this.loadSalt(config.storageDirectory);
    this.capture();
  }

  get userIdentityEpoch(): number { return this.epoch; }
  get identityEpoch(): number { return this.epoch; }
  register(value?: string | null): boolean { return this.registerUserId(value); }
  invalidate(): void { this.invalidatePendingOperations(); }

  registerUserId(value?: string | null): boolean {
    const normalized = OtaUserContext.normalizeUserId(value);
    if (normalized === this.userId) return false;
    if (this.config.versionCode === undefined && normalized !== undefined) throw new Error('missing_version_code');
    this.invalidatePendingOperations();
    this.userId = normalized;
    return true;
  }

  invalidatePendingOperations(): void {
    if (this.epoch >= Number.MAX_SAFE_INTEGER) throw new Error('identity_epoch_exhausted');
    this.epoch += 1;
  }

  capture(expectedEpoch?: number): OtaUserContext {
    if (expectedEpoch !== undefined && expectedEpoch !== this.epoch) throw new Error('stale_identity');
    return new OtaUserContext(this.config, this.ownerId, this.epoch, this.userId, this.salt);
  }

  validate(context: OtaUserContext): void {
    if (context.ownerId !== this.ownerId || context.identityEpoch !== this.epoch) throw new Error('stale_identity');
  }

  private loadSalt(root: string): string {
    if (root.trim().length === 0) throw new Error('missing_storage_directory');
    if (!fs.accessSync(root)) fs.mkdirSync(root, true);
    const path = `${root}/selection-salt`;
    if (fs.accessSync(path)) {
      const value = fs.readTextSync(path);
      if (!/^[0-9a-f]{64}$/.test(value)) throw new Error('invalid_selection_salt');
      return value;
    }
    const temporary = `${path}.tmp-${this.ownerId}`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, this.ownerId); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    fs.renameSync(temporary, path);
    const directory = fs.openSync(root, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR);
    try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory); }
    return this.ownerId;
  }
}
