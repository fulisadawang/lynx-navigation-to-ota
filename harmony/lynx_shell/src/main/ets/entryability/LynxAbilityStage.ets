import { AbilityStage } from '@kit.AbilityKit';
import { ImageKnife } from '@ohos/imageknifepro';

/** App 进程创建时初始化 ImageKnife 文件缓存，供 Lynx Image Service 和资源 Fetcher 复用。 */
export default class LynxAbilityStage extends AbilityStage {
  onCreate(): void {
    ImageKnife.getInstance().initFileCache(this.context);
  }
}
