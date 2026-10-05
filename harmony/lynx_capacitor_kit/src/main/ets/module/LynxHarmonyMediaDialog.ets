import { ComponentContent, promptAction } from '@kit.ArkUI';
import { LynxCapacitorHost } from './LynxCapacitorHost';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';

export interface LynxHarmonyPreviewImage {
  uri: string;
  width: number;
  height: number;
}

export interface LynxHarmonyMediaChoice { label: string; value: string; color?: string; disabled?: boolean; }
interface MediaMenuParams {
  title: string;
  choices: Array<LynxHarmonyMediaChoice>;
  message?: string;
  onChoice: (value: string) => void;
}

@Component
struct LynxHarmonyMediaSourceView {
  params: MediaMenuParams = { title: '', choices: [], onChoice: (_value: string): void => {} };
  build(): void {
    Column({ space: 12 }) {
      Text(this.params.title).fontSize(18).fontWeight(FontWeight.Medium);
      if (this.params.message !== undefined && this.params.message.length > 0) Text(this.params.message).fontSize(14);
      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.params.choices, (choice: LynxHarmonyMediaChoice): void => {
            Button(choice.label).width('100%').height(48).fontColor(choice.color ?? '#000000').enabled(choice.disabled !== true)
              .onClick((): void => this.params.onChoice(choice.value));
          }, (choice: LynxHarmonyMediaChoice): string => choice.value);
        }.width('100%');
      }.constraintSize({ maxHeight: '60%' });
    }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(16);
  }
}

@Builder
function mediaMenuBuilder(params: MediaMenuParams): void { LynxHarmonyMediaSourceView({ params: params }); }

/** 可由 owner 关闭的原生来源菜单，先结束菜单动画再进入系统 Picker。 */
export class LynxHarmonyMediaMenu {
  private static nextID: number = 0;
  private owner: LynxHarmonyNativeOwner;
  private host: LynxCapacitorHost;
  private content: ComponentContent<MediaMenuParams> | null = null;
  private opening: Promise<void> | null = null;
  private settled: boolean = false;
  private nativeDismissed: boolean = false;
  private resolveChoice: ((value: string) => void) | null = null;
  private rejectChoice: ((error: Object) => void) | null = null;
  private readonly key: string;
  constructor(owner: LynxHarmonyNativeOwner, host: LynxCapacitorHost) {
    this.owner = owner;
    this.host = host;
    this.key = 'native-menu:' + owner.id + ':' + String(++LynxHarmonyMediaMenu.nextID);
  }

  public select(title: string, choices: Array<LynxHarmonyMediaChoice>, message: string = ''): Promise<string> {
    this.owner.checkActive();
    this.owner.own(this.key, (): void => this.cancel('ACTIVITY_DESTROYED: 来源菜单 owner 已结束'));
    return new Promise<string>((resolve, reject): void => {
      this.resolveChoice = resolve;
      this.rejectChoice = reject;
      try { this.host.uiContext.runScopedTask((): void => {
        try {
          this.owner.checkActive();
          if (!this.host.isVisible()) throw new Error('UNAVAILABLE: 来源菜单所属页面不在前台');
          const params: MediaMenuParams = { title: title, choices: choices, message: message, onChoice: (value: string): void => this.finish(value) };
          const content = new ComponentContent(this.host.uiContext, wrapBuilder(mediaMenuBuilder), params);
          this.content = content;
          this.opening = this.host.uiContext.getPromptAction().openCustomDialog(content, {
            autoCancel: true, customStyle: true, alignment: DialogAlignment.Bottom,
            onWillDismiss: (action: promptAction.DismissDialogAction): void => {
              action.dismiss();
            },
            onDidDisappear: (): void => { this.nativeDismissed = true; this.cancel('CANCELLED: 用户取消了来源选择'); },
          });
          this.opening.catch((_error: Object): void => this.cancel('UNAVAILABLE: 原生来源菜单无法打开'));
        } catch (error) { this.cancel(String(error)); }
      }); } catch (_error) { this.cancel('UNAVAILABLE: 来源菜单 UIContext 已失效'); }
    });
  }

  public cancel(message: string = 'CANCELLED: 来源菜单已关闭'): void { this.finish(null, new Error(message)); }

  private finish(value: string | null, error: Object | null = null): void {
    if (this.settled) return;
    this.settled = true;
    this.owner.disown(this.key);
    this.close().then((): void => {
      if (error !== null || value === null || !this.owner.isActive || !this.host.isVisible()) {
        if (this.rejectChoice !== null) this.rejectChoice(error ?? new Error('ACTIVITY_DESTROYED: 来源菜单所属页面已结束'));
      } else if (this.resolveChoice !== null) this.resolveChoice(value);
      this.resolveChoice = null;
      this.rejectChoice = null;
    }).catch((_error: Object): void => {
      if (this.rejectChoice !== null) this.rejectChoice(new Error('UNAVAILABLE: 原生来源菜单关闭失败'));
      this.resolveChoice = null;
      this.rejectChoice = null;
    });
  }

  private async close(): Promise<void> {
    const opening = this.opening;
    if (opening !== null) {
      try { await opening; } catch (_error) { this.dispose(); return; }
    }
    const content = this.content;
    if (content === null) return;
    if (this.nativeDismissed) { this.dispose(); return; }
    try {
      await new Promise<void>((resolve, reject): void => {
        this.host.uiContext.runScopedTask((): void => {
          try { this.host.uiContext.getPromptAction().closeCustomDialog(content).then(resolve).catch(reject); }
          catch (error) { reject(error); }
        });
      });
    } finally { this.dispose(); }
  }

  private dispose(): void {
    const content = this.content;
    this.content = null;
    if (content !== null) {
      try { this.host.uiContext.runScopedTask((): void => content.dispose()); }
      catch (_error) { console.error('LynxHarmonyMedia', '来源菜单所属 UIContext 已释放'); }
    }
  }
}

interface MediaDialogParams {
  images: Array<LynxHarmonyPreviewImage>;
  initialIndex: number;
  videoUri: string;
  videoController: VideoController;
  onClose: () => void;
}

@Component
struct LynxHarmonyPreviewImageView {
  item: LynxHarmonyPreviewImage = { uri: '', width: 1, height: 1 };
  @State zoom: number = 1;
  @State failed: boolean = false;
  private initialZoom: number = 1;

  build(): void {
    Stack() {
      Image(this.item.uri)
        .width('100%')
        .height('100%')
        .sourceSize({ width: this.item.width, height: this.item.height })
        .objectFit(ImageFit.Contain)
        .autoResize(true)
        .syncLoad(false)
        .scale({ x: this.zoom, y: this.zoom })
        .onError((): void => { this.failed = true; })
        .gesture(PinchGesture()
          .onActionStart((): void => { this.initialZoom = this.zoom; })
          .onActionUpdate((event: GestureEvent): void => {
            this.zoom = Math.max(1, Math.min(4, this.initialZoom * event.scale));
          }))
        .onClick((): void => { this.zoom = 1; });
      if (this.failed) Text('无法显示这张本地图片').fontColor(Color.White);
    }
    .width('100%')
    .height('100%')
    .clip(true);
  }
}

@Component
struct LynxHarmonyMediaDialogView {
  params: MediaDialogParams = {
    images: [], initialIndex: 0, videoUri: '', videoController: new VideoController(), onClose: (): void => {},
  };
  @State index: number = 0;
  @State videoFailed: boolean = false;

  aboutToAppear(): void { this.index = this.params.initialIndex; }
  aboutToDisappear(): void {
    if (this.params.videoUri.length > 0) {
      try { this.params.videoController.stop(); }
      catch (_error) { console.error('LynxHarmonyMedia', '预览页面关闭时播放器已不可用'); }
    }
  }

  build(): void {
    Column() {
      Row() {
        Text(this.params.videoUri.length > 0 ? '视频预览' : `${this.index + 1} / ${this.params.images.length}`)
          .fontSize(16).fontColor(Color.White).layoutWeight(1);
        Button('关闭').onClick((): void => this.params.onClose());
      }.width('100%').height(56).padding({ left: 16, right: 16 });
      if (this.params.videoUri.length > 0) {
        Stack() {
          Video({ src: this.params.videoUri, controller: this.params.videoController })
            .width('100%').height('100%').objectFit(ImageFit.Contain)
            .controls(true).autoPlay(true)
            .onError((): void => { this.videoFailed = true; });
          if (this.videoFailed) Text('无法播放这段本地视频').fontColor(Color.White);
        }.width('100%').layoutWeight(1);
      } else {
        Swiper() {
          ForEach(this.params.images, (item: LynxHarmonyPreviewImage, index: number): void => {
            if (Math.abs(this.index - index) <= 1) {
              LynxHarmonyPreviewImageView({ item: item });
            } else {
              Blank().width('100%').height('100%');
            }
          }, (item: LynxHarmonyPreviewImage, index: number): string => item.uri + ':' + String(index));
        }
        .index(this.index)
        .cachedCount(1)
        .loop(false)
        .indicator(false)
        .onChange((index: number): void => { this.index = index; })
        .width('100%').layoutWeight(1);
      }
    }.width('100%').height('100%').backgroundColor(Color.Black);
  }
}

@Builder
function mediaDialogBuilder(params: MediaDialogParams): void {
  LynxHarmonyMediaDialogView({ params: params });
}

/** 界面对象只留在所属 UIContext；系统滑动/播放不经过 Lynx 逐帧桥接。 */
export class LynxHarmonyMediaDialog {
  private owner: LynxHarmonyNativeOwner;
  private host: LynxCapacitorHost;
  private onClosed: () => void;
  private content: ComponentContent<MediaDialogParams> | null = null;
  private controller: VideoController | null = null;
  private video: boolean = false;
  private opening: boolean = false;
  private closing: boolean = false;
  private disposed: boolean = false;
  private readonly key: string;

  constructor(
    owner: LynxHarmonyNativeOwner,
    host: LynxCapacitorHost,
    onClosed: () => void,
  ) {
    this.owner = owner;
    this.host = host;
    this.onClosed = onClosed;
    this.key = 'media-dialog:' + owner.id;
  }

  public open(images: Array<LynxHarmonyPreviewImage>, initialIndex: number, videoUri: string = ''): Promise<void> {
    this.owner.checkActive();
    if (!this.host.isVisible()) return Promise.reject(new Error('UNAVAILABLE: 媒体界面所属页面不在前台'));
    this.opening = true;
    this.video = videoUri.length > 0;
    this.owner.own(this.key, (): void => this.close());
    return new Promise<void>((resolve, reject): void => {
      try { this.host.uiContext.runScopedTask((): void => {
        try {
          this.owner.checkActive();
          if (!this.host.isVisible()) throw new Error('UNAVAILABLE: 媒体界面所属页面不在前台');
          this.controller = new VideoController();
          const params: MediaDialogParams = {
            images: images, initialIndex: initialIndex, videoUri: videoUri,
            videoController: this.controller, onClose: (): void => this.close(),
          };
          const content = new ComponentContent(this.host.uiContext, wrapBuilder(mediaDialogBuilder), params);
          this.content = content;
          const options: promptAction.BaseDialogOptions = {
            autoCancel: true, customStyle: true, alignment: DialogAlignment.Center,
            onWillDismiss: (action: promptAction.DismissDialogAction): void => {
              action.dismiss();
              this.closing = true;
            },
            onDidDisappear: (): void => this.dispose(),
          };
          this.host.uiContext.getPromptAction().openCustomDialog(content, options).then((): void => {
            this.opening = false;
            if (this.closing || !this.owner.isActive || !this.host.isVisible()) {
              this.close();
              reject(new Error('ACTIVITY_DESTROYED: 媒体界面打开期间 owner 已结束或离开前台'));
              return;
            }
            resolve();
          }).catch((error: Object): void => {
            this.opening = false;
            this.dispose();
            reject(error);
          });
        } catch (error) {
          this.opening = false;
          this.dispose();
          reject(error);
        }
      }); } catch (error) { this.opening = false; this.dispose(); reject(error); }
    });
  }

  public close(): void {
    this.closing = true;
    if (this.opening || this.disposed) return;
    const content = this.content;
    if (content === null) { this.dispose(); return; }
    try { this.host.uiContext.runScopedTask((): void => {
      if (this.video && this.controller !== null) {
        try { this.controller.stop(); }
        catch (_error) { console.error('LynxHarmonyMedia', '关闭预览时播放器已不可用'); }
      }
      try {
        this.host.uiContext.getPromptAction().closeCustomDialog(content)
          .then((): void => this.dispose())
          .catch((_error: Object): void => this.dispose());
      } catch (_error) { this.dispose(); }
    }); } catch (_error) { this.dispose(); }
  }

  private dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.owner.disown(this.key);
    const content = this.content;
    this.content = null;
    this.controller = null;
    if (content !== null) {
      try { this.host.uiContext.runScopedTask((): void => content.dispose()); }
      catch (_error) { console.error('LynxHarmonyMedia', '预览所属 UIContext 已释放'); }
    }
    this.onClosed();
  }
}
