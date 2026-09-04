import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';

interface LynxHarmonyAudioError {
  code: string;
  message: string;
}

/**
 * Audio adapter 的业务结果。
 *
 * 这里故意不包含 callbackId、pluginId、methodName、success、data envelope 等 Bridge 字段。
 * LynxCapacitorModule 负责把本对象转换成公共 NativeModule envelope。
 *
 * ArkTS 禁止在接口属性中直接使用对象字面量类型，因此 error 使用同构的命名接口。
 */
export interface LynxHarmonyAudioResult {
  data?: Record<string, Object>;
  error?: LynxHarmonyAudioError;
}

type LynxHarmonyAudioCompletion = (result: LynxHarmonyAudioResult) => void;
type LynxHarmonyAudioState = 'idle' | 'recording' | 'preparing' | 'playing' | 'stopping';

interface LynxHarmonyAudioPathResolution {
  path: string;
  error?: LynxHarmonyAudioError;
}

/**
 * Harmony Audio 原生 adapter。
 *
 * 设计约束：
 * - 以 UIAbilityContext 为 session key，每个 Ability 独立持有 AVRecorder、AVPlayer 和 fd；
 * - 录音固定输出到 context.cacheDir/lynx-audio/*.m4a，使用 fd:// 交给 AVRecorder；
 * - 播放接受本地路径、相对录音路径和 file URI，统一转换成 cache 私有目录内的 fdSrc；
 * - stop/release 会先停止（如果当前状态允许），再 reset/release 媒体对象，最后关闭 fd；
 * - 所有错误只返回能力层业务对象，不在这里拼接 Bridge success/data envelope。
 */
export default class LynxHarmonyAudioCapabilities {
  private static readonly MICROPHONE_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
  private static readonly AUDIO_DIRECTORY: string = 'lynx-audio';
  private static readonly RECORDING_EXTENSION: string = '.m4a';
  private static readonly MIN_RECORDING_DURATION_MS: number = 500;
  private static readonly HANDLED_METHODS: Array<string> = [
    'checkPermissions',
    'requestPermissions',
    'record',
    'stopRecording',
    'play',
    'stopPlayback',
    'getState',
  ];
  private static readonly sessions: Map<common.UIAbilityContext, LynxHarmonyAudioCapabilities> = new Map();
  private static nextRecordingId: number = 0;

  private readonly context: common.UIAbilityContext;
  private state: LynxHarmonyAudioState = 'idle';
  private operationGeneration: number = 0;
  private released: boolean = false;
  private permissionRequestInProgress: boolean = false;

  private recorder: media.AVRecorder | null = null;
  private recordingFile: fileIo.File | null = null;
  private recordingPath: string = '';
  private recordingStartedAt: number = 0;
  private recordCompletion: LynxHarmonyAudioCompletion | null = null;
  private recorderErrorHandler: ((error: BusinessError) => void) | null = null;

  private player: media.AVPlayer | null = null;
  private playbackFile: fileIo.File | null = null;
  private playbackPath: string = '';
  private playCompletion: LynxHarmonyAudioCompletion | null = null;
  private playerStateChangeHandler: ((state: media.AVPlayerState, reason: media.StateChangeReason) => void) | null = null;
  private playerErrorHandler: ((error: BusinessError) => void) | null = null;

  /** 录音停止和播放停止本身也是异步清理，销毁期间用它们避免调用方永久等待。 */
  private stopCompletion: LynxHarmonyAudioCompletion | null = null;
  private lastRecordingPath: string = '';
  private lastError: LynxHarmonyAudioError | null = null;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 供主 Module 调用的静态 dispatch 接口。
   * 返回 false 表示 methodName 不属于 Audio 的 7 个核心方法；返回 true 表示已接管，
   * 即使最终返回参数错误、权限拒绝或原生错误，也不会落入其它默认分支。
   */
  public static dispatch(
    context: common.UIAbilityContext,
    methodName: string,
    options: Record<string, Object>,
    complete: LynxHarmonyAudioCompletion,
  ): boolean {
    if (LynxHarmonyAudioCapabilities.HANDLED_METHODS.indexOf(methodName) < 0) return false;

    let session = LynxHarmonyAudioCapabilities.sessions.get(context);
    if (session === undefined) {
      session = new LynxHarmonyAudioCapabilities(context);
      LynxHarmonyAudioCapabilities.sessions.set(context, session);
    }

    try {
      session.dispatch(methodName, options, complete);
    } catch (error) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'NATIVE_ERROR', `Audio.${methodName} 调用失败`),
      );
    }
    return true;
  }

  /**
   * 释放全部 Ability session。主 Module 在 destroy 时调用；重复调用安全无副作用。
   */
  public static release(): void {
    const sessions: Array<LynxHarmonyAudioCapabilities> = [];
    LynxHarmonyAudioCapabilities.sessions.forEach((session: LynxHarmonyAudioCapabilities): void => {
      sessions.push(session);
    });
    LynxHarmonyAudioCapabilities.sessions.clear();
    sessions.forEach((session: LynxHarmonyAudioCapabilities): void => {
      session.dispose().catch((error: Object): void => {
        console.error('LynxHarmonyAudioCapabilities', `Audio session release failed: ${String(error)}`);
      });
    });
  }

  private dispatch(
    methodName: string,
    options: Record<string, Object>,
    complete: LynxHarmonyAudioCompletion,
  ): void {
    switch (methodName) {
      case 'checkPermissions':
        this.checkPermissions(complete);
        return;
      case 'requestPermissions':
        this.requestPermissions(complete);
        return;
      case 'record':
        this.record(complete);
        return;
      case 'stopRecording':
        this.stopRecording(complete);
        return;
      case 'play':
        this.play(options, complete);
        return;
      case 'stopPlayback':
        this.stopPlayback(complete);
        return;
      case 'getState':
        LynxHarmonyAudioCapabilities.safeComplete(complete, this.stateResult());
        return;
      default:
        LynxHarmonyAudioCapabilities.safeComplete(
          complete,
          LynxHarmonyAudioCapabilities.failure('UNIMPLEMENTED', `Audio.${methodName} 未实现`),
        );
    }
  }

  private checkPermissions(complete: LynxHarmonyAudioCompletion): void {
    try {
      const status = this.readMicrophonePermissionStatus();
      if (status === Number(abilityAccessCtrl.PermissionStatus.INVALID)) {
        LynxHarmonyAudioCapabilities.safeComplete(
          complete,
          LynxHarmonyAudioCapabilities.failure('PERMISSION_NOT_DECLARED', 'Manifest 未声明 ohos.permission.MICROPHONE'),
        );
        return;
      }
      const data: Record<string, Object> = {};
      data['audio'] = this.permissionState(status);
      LynxHarmonyAudioCapabilities.safeComplete(complete, LynxHarmonyAudioCapabilities.success(data));
    } catch (error) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'PERMISSION_CHECK_FAILED', '录音权限检查失败'),
      );
    }
  }

  private requestPermissions(complete: LynxHarmonyAudioCompletion): void {
    if (this.permissionRequestInProgress) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('PERMISSION_REQUEST_IN_PROGRESS', '录音权限请求正在进行中'),
      );
      return;
    }

    let currentStatus: number;
    try {
      currentStatus = this.readMicrophonePermissionStatus();
    } catch (error) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'PERMISSION_CHECK_FAILED', '录音权限检查失败'),
      );
      return;
    }

    if (currentStatus === Number(abilityAccessCtrl.PermissionStatus.INVALID)) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('PERMISSION_NOT_DECLARED', 'Manifest 未声明 ohos.permission.MICROPHONE'),
      );
      return;
    }
    if (currentStatus === Number(abilityAccessCtrl.PermissionStatus.GRANTED)) {
      const data: Record<string, Object> = {};
      data['audio'] = 'granted';
      LynxHarmonyAudioCapabilities.safeComplete(complete, LynxHarmonyAudioCapabilities.success(data));
      return;
    }

    this.permissionRequestInProgress = true;
    try {
      abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(this.context, [LynxHarmonyAudioCapabilities.MICROPHONE_PERMISSION])
        .then((requestResult: Object): void => {
          this.permissionRequestInProgress = false;
          const raw = requestResult as Record<string, Object>;
          const authResults = raw['authResults'] as Array<Object>;
          const errorReasons = raw['errorReasons'] as Array<Object>;
          const firstErrorReason = errorReasons !== undefined && errorReasons.length > 0
            ? Number(errorReasons[0])
            : 0;

          if (firstErrorReason === 2) {
            LynxHarmonyAudioCapabilities.safeComplete(
              complete,
              LynxHarmonyAudioCapabilities.failure('PERMISSION_NOT_DECLARED', 'Manifest 未声明 ohos.permission.MICROPHONE'),
            );
            return;
          }
          if (firstErrorReason === 12) {
            LynxHarmonyAudioCapabilities.safeComplete(
              complete,
              LynxHarmonyAudioCapabilities.failure('PERMISSION_REQUEST_FAILED', '系统权限服务异常，无法申请录音权限'),
            );
            return;
          }

          let granted = authResults !== undefined && authResults.length > 0;
          if (granted) {
            authResults.forEach((value: Object): void => {
              if (Number(value) !== 0) granted = false;
            });
          }
          if (!granted) {
            const message = authResults !== undefined && authResults.length > 0
              ? '用户拒绝或取消了录音权限请求'
              : '录音权限请求没有返回有效结果';
            LynxHarmonyAudioCapabilities.safeComplete(
              complete,
              LynxHarmonyAudioCapabilities.failure(
                authResults !== undefined && authResults.length > 0 ? 'PERMISSION_DENIED' : 'PERMISSION_REQUEST_FAILED',
                message,
              ),
            );
            return;
          }

          const data: Record<string, Object> = {};
          data['audio'] = 'granted';
          LynxHarmonyAudioCapabilities.safeComplete(complete, LynxHarmonyAudioCapabilities.success(data));
        })
        .catch((error: Object): void => {
          this.permissionRequestInProgress = false;
          LynxHarmonyAudioCapabilities.safeComplete(
            complete,
            LynxHarmonyAudioCapabilities.failureFromNative(error, 'PERMISSION_REQUEST_FAILED', '录音权限请求失败'),
          );
        });
    } catch (error) {
      this.permissionRequestInProgress = false;
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'PERMISSION_REQUEST_FAILED', '录音权限请求失败'),
      );
    }
  }

  private async record(complete: LynxHarmonyAudioCompletion): Promise<void> {
    let permissionStatus: number;
    try {
      permissionStatus = this.readMicrophonePermissionStatus();
    } catch (error) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'PERMISSION_CHECK_FAILED', '录音权限检查失败'),
      );
      return;
    }
    if (permissionStatus !== Number(abilityAccessCtrl.PermissionStatus.GRANTED)) {
      const code = permissionStatus === Number(abilityAccessCtrl.PermissionStatus.INVALID)
        ? 'PERMISSION_NOT_DECLARED'
        : 'PERMISSION_DENIED';
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure(code, code === 'PERMISSION_NOT_DECLARED'
          ? 'Manifest 未声明 ohos.permission.MICROPHONE'
          : '缺少录音权限，请先调用 requestPermissions'),
      );
      return;
    }
    if (this.isBusy()) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('BUSY', '当前 Audio session 已有录音或播放操作'),
      );
      return;
    }

    const generation = this.beginOperation('recording');
    this.recordCompletion = complete;
    let outputFile: fileIo.File | null = null;
    let recorder: media.AVRecorder | null = null;
    let outputPath: string = '';

    try {
      outputPath = this.createRecordingPath();
      outputFile = fileIo.openSync(
        outputPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
      this.recordingPath = outputPath;
      this.recordingFile = outputFile;

      recorder = await media.createAVRecorder();
      if (recorder === null) {
        throw new Error('AVRecorder 创建失败');
      }
      if (!this.isCurrent(generation)) {
        await this.disposeRecorder(recorder, outputFile, outputPath, true, false);
        return;
      }

      this.recorder = recorder;
      this.bindRecorder(recorder, generation);
      const profile: media.AVRecorderProfile = {
        audioBitrate: 128000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 44100,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A,
      };
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: profile,
        url: `fd://${String(outputFile.fd)}`,
      };

      await recorder.prepare(config);
      if (!this.isCurrent(generation)) {
        await this.disposeRecorder(recorder, outputFile, outputPath, true, false);
        return;
      }

      this.recordingStartedAt = Date.now();
      await recorder.start();
      if (!this.isCurrent(generation)) {
        await this.disposeRecorder(recorder, outputFile, outputPath, true, false);
        return;
      }

      const data: Record<string, Object> = {};
      data['state'] = 'recording';
      data['recording'] = true;
      data['playing'] = false;
      data['path'] = outputPath;
      this.lastError = null;
      this.completeRecord(LynxHarmonyAudioCapabilities.success(data));
    } catch (error) {
      const failure = LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'RECORDER_ERROR', 'AVRecorder 录音失败');
      if (this.isCurrent(generation)) {
        this.operationGeneration += 1;
        this.recorder = null;
        this.recordingFile = null;
        this.recordingPath = '';
        this.recordingStartedAt = 0;
        this.state = 'idle';
        this.lastError = failure.error === undefined ? null : failure.error;
        this.completeRecord(failure);
      }
      await this.disposeRecorder(recorder, outputFile, outputPath, true, false);
    }
  }

  private async stopRecording(complete: LynxHarmonyAudioCompletion): Promise<void> {
    if (this.state !== 'recording' || this.recorder === null) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('NOT_RECORDING', '当前 Audio session 没有正在进行的录音'),
      );
      return;
    }

    const recorder = this.recorder;
    const outputFile = this.recordingFile;
    const outputPath = this.recordingPath;
    const startedAt = this.recordingStartedAt;
    const wasStarted = this.recorderIsStarted(recorder);
    const pendingRecord = this.recordCompletion;

    this.operationGeneration += 1;
    this.recorder = null;
    this.recordingFile = null;
    this.recordingPath = '';
    this.recordingStartedAt = 0;
    this.state = 'stopping';
    this.recordCompletion = null;
    this.stopCompletion = complete;

    if (pendingRecord !== null) {
      LynxHarmonyAudioCapabilities.safeComplete(
        pendingRecord,
        LynxHarmonyAudioCapabilities.failure('CANCELLED', '录音启动已被 stopRecording 取消'),
      );
    }

    const cleanupError = await this.disposeRecorder(recorder, outputFile, outputPath, false, true);
    if (this.released) return;

    this.state = 'idle';
    if (!wasStarted) {
      this.deleteFile(outputPath);
      this.lastError = { code: 'CANCELLED', message: '录音尚未开始，已取消' };
      this.completeStop(LynxHarmonyAudioCapabilities.failure('CANCELLED', '录音尚未开始，已取消'));
      return;
    }
    if (cleanupError !== null) {
      this.deleteFile(outputPath);
      this.lastError = cleanupError;
      this.completeStop(LynxHarmonyAudioCapabilities.failure(cleanupError.code, cleanupError.message));
      return;
    }

    const durationMs = startedAt > 0 ? Math.max(0, Date.now() - startedAt) : 0;
    if (durationMs < LynxHarmonyAudioCapabilities.MIN_RECORDING_DURATION_MS) {
      this.deleteFile(outputPath);
      this.lastError = { code: 'RECORDING_TOO_SHORT', message: '录音时长太短，无法生成有效文件' };
      this.completeStop(LynxHarmonyAudioCapabilities.failure('RECORDING_TOO_SHORT', '录音时长太短，无法生成有效文件'));
      return;
    }

    const size = this.fileSize(outputPath);
    if (size < 0) {
      this.lastError = { code: 'FILE_NOT_FOUND', message: '录音文件不存在' };
      this.completeStop(LynxHarmonyAudioCapabilities.failure('FILE_NOT_FOUND', '录音文件不存在'));
      return;
    }
    if (size <= 0) {
      this.deleteFile(outputPath);
      this.lastError = { code: 'EMPTY_FILE', message: '录音文件为空' };
      this.completeStop(LynxHarmonyAudioCapabilities.failure('EMPTY_FILE', '录音文件为空'));
      return;
    }

    this.lastRecordingPath = outputPath;
    this.lastError = null;
    const data: Record<string, Object> = {};
    data['state'] = 'idle';
    data['stopped'] = true;
    data['durationMs'] = durationMs;
    data['path'] = outputPath;
    this.completeStop(LynxHarmonyAudioCapabilities.success(data));
  }

  private async play(options: Record<string, Object>, complete: LynxHarmonyAudioCompletion): Promise<void> {
    if (this.isBusy()) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('BUSY', '当前 Audio session 已有录音或播放操作'),
      );
      return;
    }

    const resolution = this.resolvePlaybackPath(options);
    if (resolution.error !== undefined) {
      LynxHarmonyAudioCapabilities.safeComplete(complete, { error: resolution.error });
      return;
    }
    const playbackPath = resolution.path;
    const size = this.fileSize(playbackPath);
    if (size < 0) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('FILE_NOT_FOUND', '没有可播放的本地录音文件'),
      );
      return;
    }
    if (size <= 0) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('EMPTY_FILE', '播放文件为空'),
      );
      return;
    }

    const generation = this.beginOperation('preparing');
    this.playbackPath = playbackPath;
    this.playCompletion = complete;
    let playbackFile: fileIo.File | null = null;
    let player: media.AVPlayer | null = null;

    try {
      playbackFile = fileIo.openSync(playbackPath, fileIo.OpenMode.READ_ONLY);
      this.playbackFile = playbackFile;
      player = await media.createAVPlayer();
      if (player === null) {
        throw new Error('AVPlayer 创建失败');
      }
      if (!this.isCurrent(generation)) {
        await this.disposePlayer(player, playbackFile, playbackPath, false, false);
        return;
      }

      this.player = player;
      this.bindPlayer(player, generation);
      player.fdSrc = { fd: playbackFile.fd, offset: 0, length: size };
      // 通过 AudioKit 明确走音乐播放流，避免 AVPlayer 使用设备默认 usage 导致焦点/音量路由漂移。
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0,
      };
      await player.prepare();
      if (!this.isCurrent(generation)) {
        await this.disposePlayer(player, playbackFile, playbackPath, false, false);
        return;
      }

      await player.play();
      if (!this.isCurrent(generation)) {
        await this.disposePlayer(player, playbackFile, playbackPath, false, false);
        return;
      }
      this.state = 'playing';
      const data: Record<string, Object> = {};
      data['state'] = 'playing';
      data['recording'] = false;
      data['playing'] = true;
      data['path'] = playbackPath;
      this.lastError = null;
      this.completePlay(LynxHarmonyAudioCapabilities.success(data));
    } catch (error) {
      const failure = LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'PLAYER_ERROR', 'AVPlayer 播放失败');
      if (this.isCurrent(generation)) {
        this.operationGeneration += 1;
        this.player = null;
        this.playbackFile = null;
        this.playbackPath = '';
        this.state = 'idle';
        this.lastError = failure.error === undefined ? null : failure.error;
        this.completePlay(failure);
      }
      await this.disposePlayer(player, playbackFile, playbackPath, false, false);
    }
  }

  private async stopPlayback(complete: LynxHarmonyAudioCompletion): Promise<void> {
    if ((this.state !== 'preparing' && this.state !== 'playing') || this.player === null) {
      LynxHarmonyAudioCapabilities.safeComplete(
        complete,
        LynxHarmonyAudioCapabilities.failure('NOT_PLAYING', '当前 Audio session 没有正在进行的播放'),
      );
      return;
    }

    const player = this.player;
    const playbackFile = this.playbackFile;
    const playbackPath = this.playbackPath;
    const pendingPlay = this.playCompletion;

    this.operationGeneration += 1;
    this.player = null;
    this.playbackFile = null;
    this.playbackPath = '';
    this.state = 'stopping';
    this.playCompletion = null;
    this.stopCompletion = complete;

    const cleanupError = await this.disposePlayer(player, playbackFile, playbackPath, false, true);
    if (this.released) return;

    this.state = 'idle';
    this.lastError = cleanupError;
    if (pendingPlay !== null) {
      LynxHarmonyAudioCapabilities.safeComplete(
        pendingPlay,
        LynxHarmonyAudioCapabilities.failure('CANCELLED', '播放已被 stopPlayback 取消'),
      );
    }
    if (cleanupError !== null) {
      this.completeStop(LynxHarmonyAudioCapabilities.failure(cleanupError.code, cleanupError.message));
      return;
    }

    const data: Record<string, Object> = {};
    data['state'] = 'idle';
    data['stopped'] = true;
    data['path'] = playbackPath;
    this.completeStop(LynxHarmonyAudioCapabilities.success(data));
  }

  private stateResult(): LynxHarmonyAudioResult {
    const data: Record<string, Object> = {};
    const wireState = this.state === 'stopping' ? 'idle' : this.state;
    data['state'] = wireState;
    data['recording'] = this.state === 'recording';
    data['playing'] = this.state === 'preparing' || this.state === 'playing';
    const currentPath = this.state === 'recording'
      ? this.recordingPath
      : this.state === 'preparing' || this.state === 'playing'
        ? this.playbackPath
        : this.lastRecordingPath;
    // Record<string, Object> 在 ArkTS 中不接受 null；JSON.parse 保留了桥接层需要的 null 语义。
    data['path'] = currentPath.length > 0 ? currentPath : JSON.parse('null') as Object;
    if (this.lastError !== null) {
      const lastError: Record<string, Object> = {};
      lastError['code'] = this.lastError.code;
      lastError['message'] = this.lastError.message;
      data['lastError'] = lastError;
    }
    return LynxHarmonyAudioCapabilities.success(data);
  }

  private beginOperation(nextState: LynxHarmonyAudioState): number {
    this.operationGeneration += 1;
    this.state = nextState;
    this.lastError = null;
    return this.operationGeneration;
  }

  private isCurrent(generation: number): boolean {
    return !this.released && this.operationGeneration === generation;
  }

  private isBusy(): boolean {
    return this.state !== 'idle' || this.stopCompletion !== null;
  }

  private completeRecord(result: LynxHarmonyAudioResult): void {
    const complete = this.recordCompletion;
    this.recordCompletion = null;
    if (complete !== null) LynxHarmonyAudioCapabilities.safeComplete(complete, result);
  }

  private completePlay(result: LynxHarmonyAudioResult): void {
    const complete = this.playCompletion;
    this.playCompletion = null;
    if (complete !== null) LynxHarmonyAudioCapabilities.safeComplete(complete, result);
  }

  private completeStop(result: LynxHarmonyAudioResult): void {
    const complete = this.stopCompletion;
    this.stopCompletion = null;
    if (complete !== null) LynxHarmonyAudioCapabilities.safeComplete(complete, result);
  }

  private bindRecorder(recorder: media.AVRecorder, generation: number): void {
    const handler = (error: BusinessError): void => {
      if (!this.isCurrent(generation) || this.recorder !== recorder) return;
      const failure = LynxHarmonyAudioCapabilities.failureFromNative(error as Object, 'RECORDER_ERROR', 'AVRecorder 发生错误');
      const outputFile = this.recordingFile;
      const outputPath = this.recordingPath;
      this.operationGeneration += 1;
      this.recorder = null;
      this.recordingFile = null;
      this.recordingPath = '';
      this.recordingStartedAt = 0;
      this.state = 'idle';
      this.lastError = failure.error === undefined ? null : failure.error;
      this.completeRecord(failure);
      this.disposeRecorder(recorder, outputFile, outputPath, true, false).catch((cleanupError: Object): void => {
        console.error('LynxHarmonyAudioCapabilities', `AVRecorder error cleanup failed: ${String(cleanupError)}`);
      });
    };
    this.recorderErrorHandler = handler;
    recorder.on('error', handler);
  }

  private bindPlayer(player: media.AVPlayer, generation: number): void {
    const stateHandler = (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
      if (!this.isCurrent(generation) || this.player !== player) return;
      if (state === 'playing' && this.state === 'preparing') this.state = 'playing';
      if (state === 'error') {
        this.failPlayback(generation, player, { code: 'PLAYER_ERROR', message: 'AVPlayer 进入 error 状态' });
        return;
      }
      if (state === 'completed') this.finishPlayback(generation, player);
    };
    const errorHandler = (error: BusinessError): void => {
      if (!this.isCurrent(generation) || this.player !== player) return;
      this.failPlayback(
        generation,
        player,
        LynxHarmonyAudioCapabilities.nativeError(error as Object, 'PLAYER_ERROR', 'AVPlayer 发生错误'),
      );
    };
    this.playerStateChangeHandler = stateHandler;
    this.playerErrorHandler = errorHandler;
    player.on('stateChange', stateHandler);
    player.on('error', errorHandler);
  }

  private finishPlayback(generation: number, player: media.AVPlayer): void {
    if (!this.isCurrent(generation) || this.player !== player) return;
    const playbackFile = this.playbackFile;
    const playbackPath = this.playbackPath;
    this.operationGeneration += 1;
    this.player = null;
    this.playbackFile = null;
    this.playbackPath = '';
    this.state = 'idle';
    this.lastError = null;
    const pending = this.playCompletion;
    this.playCompletion = null;
    if (pending !== null) {
      const data: Record<string, Object> = {};
      data['state'] = 'playing';
      data['recording'] = false;
      data['playing'] = true;
      data['path'] = playbackPath;
      LynxHarmonyAudioCapabilities.safeComplete(pending, LynxHarmonyAudioCapabilities.success(data));
    }
    this.disposePlayer(player, playbackFile, playbackPath, false, false).catch((error: Object): void => {
      console.error('LynxHarmonyAudioCapabilities', `AVPlayer completion cleanup failed: ${String(error)}`);
    });
  }

  private failPlayback(generation: number, player: media.AVPlayer, errorInfo: LynxHarmonyAudioError): void {
    if (!this.isCurrent(generation) || this.player !== player) return;
    const playbackFile = this.playbackFile;
    const playbackPath = this.playbackPath;
    this.operationGeneration += 1;
    this.player = null;
    this.playbackFile = null;
    this.playbackPath = '';
    this.state = 'idle';
    this.lastError = errorInfo;
    this.completePlay({ error: errorInfo });
    this.disposePlayer(player, playbackFile, playbackPath, false, false).catch((error: Object): void => {
      console.error('LynxHarmonyAudioCapabilities', `AVPlayer error cleanup failed: ${String(error)}`);
    });
  }

  private async dispose(): Promise<void> {
    if (this.released) return;
    this.released = true;
    this.operationGeneration += 1;

    const recorder = this.recorder;
    const recordingFile = this.recordingFile;
    const recordingPath = this.recordingPath;
    const player = this.player;
    const playbackFile = this.playbackFile;
    const playbackPath = this.playbackPath;
    const recordPending = this.recordCompletion;
    const playPending = this.playCompletion;
    const stopPending = this.stopCompletion;

    this.recorder = null;
    this.recordingFile = null;
    this.recordingPath = '';
    this.player = null;
    this.playbackFile = null;
    this.playbackPath = '';
    this.recordCompletion = null;
    this.playCompletion = null;
    this.stopCompletion = null;
    this.recordingStartedAt = 0;
    this.state = 'idle';

    const cancelled = LynxHarmonyAudioCapabilities.failure('ACTIVITY_DESTROYED', 'Audio session 已销毁，当前操作已取消');
    if (recordPending !== null) LynxHarmonyAudioCapabilities.safeComplete(recordPending, cancelled);
    if (playPending !== null) LynxHarmonyAudioCapabilities.safeComplete(playPending, cancelled);
    if (stopPending !== null) LynxHarmonyAudioCapabilities.safeComplete(stopPending, cancelled);

    await this.disposeRecorder(recorder, recordingFile, recordingPath, true, false);
    await this.disposePlayer(player, playbackFile, playbackPath, false, false);
  }

  private async disposeRecorder(
    recorder: media.AVRecorder | null,
    file: fileIo.File | null,
    path: string,
    deleteOutput: boolean,
    reportErrors: boolean,
  ): Promise<LynxHarmonyAudioError | null> {
    let firstError: LynxHarmonyAudioError | null = null;
    if (recorder !== null) {
      this.unbindRecorder(recorder);
      let recorderState: media.AVRecorderState = 'released';
      try {
        recorderState = recorder.state;
      } catch (error) {
        if (reportErrors) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'RECORDER_ERROR', 'AVRecorder 状态读取失败');
      }
      if (recorderState === 'started' || recorderState === 'paused') {
        try {
          await recorder.stop();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'RECORDER_ERROR', 'AVRecorder 停止录音失败');
        }
      }
      if (recorderState !== 'released') {
        try {
          await recorder.reset();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'RECORDER_ERROR', 'AVRecorder reset 失败');
        }
        try {
          await recorder.release();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'RECORDER_ERROR', 'AVRecorder release 失败');
        }
      }
    }

    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'FILE_ERROR', '录音文件 fd 关闭失败');
      }
    }
    if (deleteOutput && path.length > 0) this.deleteFile(path);
    return firstError;
  }

  private async disposePlayer(
    player: media.AVPlayer | null,
    file: fileIo.File | null,
    _path: string,
    _deleteOutput: boolean,
    reportErrors: boolean,
  ): Promise<LynxHarmonyAudioError | null> {
    let firstError: LynxHarmonyAudioError | null = null;
    if (player !== null) {
      this.unbindPlayer(player);
      let playerState: media.AVPlayerState = 'released';
      try {
        playerState = player.state;
      } catch (error) {
        if (reportErrors) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'PLAYER_ERROR', 'AVPlayer 状态读取失败');
      }
      if (playerState === 'prepared' || playerState === 'playing' || playerState === 'paused' || playerState === 'completed') {
        try {
          await player.stop();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'PLAYER_ERROR', 'AVPlayer 停止播放失败');
        }
      }
      if (playerState !== 'released') {
        try {
          await player.reset();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'PLAYER_ERROR', 'AVPlayer reset 失败');
        }
        try {
          await player.release();
        } catch (error) {
          if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'PLAYER_ERROR', 'AVPlayer release 失败');
        }
      }
    }
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        if (reportErrors && firstError === null) firstError = LynxHarmonyAudioCapabilities.nativeError(error as Object, 'FILE_ERROR', '播放文件 fd 关闭失败');
      }
    }
    return firstError;
  }

  private unbindRecorder(recorder: media.AVRecorder): void {
    if (this.recorderErrorHandler !== null) {
      try {
        recorder.off('error', this.recorderErrorHandler);
      } catch (error) {
        console.error('LynxHarmonyAudioCapabilities', `AVRecorder error listener removal failed: ${String(error)}`);
      }
      this.recorderErrorHandler = null;
    }
  }

  private unbindPlayer(player: media.AVPlayer): void {
    if (this.playerStateChangeHandler !== null) {
      try {
        player.off('stateChange', this.playerStateChangeHandler);
      } catch (error) {
        console.error('LynxHarmonyAudioCapabilities', `AVPlayer state listener removal failed: ${String(error)}`);
      }
      this.playerStateChangeHandler = null;
    }
    if (this.playerErrorHandler !== null) {
      try {
        player.off('error', this.playerErrorHandler);
      } catch (error) {
        console.error('LynxHarmonyAudioCapabilities', `AVPlayer error listener removal failed: ${String(error)}`);
      }
      this.playerErrorHandler = null;
    }
  }

  private recorderIsStarted(recorder: media.AVRecorder): boolean {
    try {
      const state = recorder.state;
      return state === 'started' || state === 'paused';
    } catch (error) {
      return false;
    }
  }

  private readMicrophonePermissionStatus(): number {
    return Number(abilityAccessCtrl.createAtManager().getSelfPermissionStatus(
      LynxHarmonyAudioCapabilities.MICROPHONE_PERMISSION,
    ));
  }

  private permissionState(status: number): string {
    if (status === Number(abilityAccessCtrl.PermissionStatus.GRANTED)) return 'granted';
    if (status === Number(abilityAccessCtrl.PermissionStatus.NOT_DETERMINED)) return 'prompt';
    return 'denied';
  }

  private createRecordingPath(): string {
    const directory = this.audioDirectory();
    let directoryReady = false;
    try {
      const stat = fileIo.statSync(directory);
      directoryReady = (stat.mode & fileIo.OpenMode.DIR) !== 0;
    } catch (error) {
      fileIo.mkdirSync(directory);
      directoryReady = true;
    }
    if (!directoryReady) throw new Error('lynx-audio 路径不是目录');

    LynxHarmonyAudioCapabilities.nextRecordingId += 1;
    return `${directory}/recording-${String(Date.now())}-${String(LynxHarmonyAudioCapabilities.nextRecordingId)}${LynxHarmonyAudioCapabilities.RECORDING_EXTENSION}`;
  }

  private resolvePlaybackPath(options: Record<string, Object>): LynxHarmonyAudioPathResolution {
    const rawValue = options['path'] ?? options['filePath'] ?? options['uri'];
    let requested = '';
    if (rawValue !== undefined && rawValue !== null) {
      if (typeof rawValue !== 'string') {
        return { path: '', error: { code: 'INVALID_ARGUMENT', message: 'Audio.play 的 path 必须是字符串' } };
      }
      requested = rawValue.trim();
    }
    if (requested.length === 0) requested = this.lastRecordingPath;
    if (requested.length === 0) {
      return { path: '', error: { code: 'FILE_NOT_FOUND', message: '没有可播放的录音文件' } };
    }

    let path = requested;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
      if (path.startsWith('localhost/')) path = path.substring('localhost'.length);
      try {
        path = decodeURIComponent(path);
      } catch (error) {
        return { path: '', error: { code: 'INVALID_ARGUMENT', message: 'Audio.play 的 file URI 无效' } };
      }
    } else if (path.indexOf('://') >= 0) {
      return { path: '', error: { code: 'INVALID_ARGUMENT', message: 'Audio.play 只支持本地路径或 file URI' } };
    }

    const cacheRoot = this.cacheRoot();
    if (!path.startsWith('/')) path = `${this.audioDirectory()}/${path}`;
    path = LynxHarmonyAudioCapabilities.normalizePath(path);
    if (!LynxHarmonyAudioCapabilities.isWithin(path, cacheRoot)) {
      return { path: '', error: { code: 'INVALID_ARGUMENT', message: '播放文件必须位于 app cache 私有目录' } };
    }
    return { path: path };
  }

  private cacheRoot(): string {
    return LynxHarmonyAudioCapabilities.normalizePath(this.context.cacheDir);
  }

  private audioDirectory(): string {
    return `${this.cacheRoot()}/${LynxHarmonyAudioCapabilities.AUDIO_DIRECTORY}`;
  }

  private fileSize(path: string): number {
    try {
      const stat = fileIo.statSync(path);
      if ((stat.mode & fileIo.OpenMode.DIR) !== 0) return -1;
      return Number(stat.size);
    } catch (error) {
      return -1;
    }
  }

  private deleteFile(path: string): void {
    if (path.length === 0) return;
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
      // 清理动作幂等：文件已经不存在时不再把删除异常回传成二次错误。
    }
  }

  private static normalizePath(path: string): string {
    const absolute = path.startsWith('/');
    const stack: Array<string> = [];
    path.split('/').forEach((part: string): void => {
      if (part.length === 0 || part === '.') return;
      if (part === '..') {
        if (stack.length > 0 && stack[stack.length - 1] !== '..') stack.pop();
        else if (!absolute) stack.push(part);
        return;
      }
      stack.push(part);
    });
    const joined = stack.join('/');
    if (absolute) return joined.length > 0 ? `/${joined}` : '/';
    return joined.length > 0 ? joined : '.';
  }

  private static isWithin(path: string, root: string): boolean {
    return path === root || path.startsWith(`${root}/`);
  }

  private static success(data?: Record<string, Object>): LynxHarmonyAudioResult {
    if (data === undefined) return {};
    return { data: data };
  }

  private static failure(code: string, message: string): LynxHarmonyAudioResult {
    return { error: { code: code, message: message } };
  }

  private static failureFromNative(error: Object, fallbackCode: string, fallbackMessage: string): LynxHarmonyAudioResult {
    return { error: LynxHarmonyAudioCapabilities.nativeError(error, fallbackCode, fallbackMessage) };
  }

  private static nativeError(error: Object, fallbackCode: string, fallbackMessage: string): LynxHarmonyAudioError {
    const raw = error as Record<string, Object>;
    const nativeCode = Number(raw['code'] ?? 0);
    const nativeMessage = String(raw['message'] ?? '').trim();
    let code = fallbackCode;
    if (nativeCode === 201 || nativeCode === 12100003 || nativeCode === 13900012 || nativeMessage.toLowerCase().indexOf('permission') >= 0) {
      code = 'PERMISSION_DENIED';
    } else if (nativeCode === 401 || nativeCode === 13900020) {
      code = 'INVALID_ARGUMENT';
    } else if (nativeCode === 13900002) {
      code = 'FILE_NOT_FOUND';
    } else if (nativeCode === 5400106) {
      code = 'UNSUPPORTED_FORMAT';
    }
    return {
      code: code,
      message: nativeMessage.length > 0 ? nativeMessage : fallbackMessage,
    };
  }

  private static safeComplete(complete: LynxHarmonyAudioCompletion, result: LynxHarmonyAudioResult): void {
    try {
      complete(result);
    } catch (error) {
      console.error('LynxHarmonyAudioCapabilities', `Audio completion callback failed: ${String(error)}`);
    }
  }
}
