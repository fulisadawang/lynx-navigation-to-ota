/** 与双端一致的命令选项；验证外部JSON后再进入单笔Native导航事务。 */
export default class ShellNavigationCommandOptions {
  launchMode: 'push' | 'singleTop' | 'clearTop' | 'singleTask' = 'push';
  animated: boolean = true;
  deduplicate: boolean = true;
  deduplicateWindowMs: number = 350;
  result?: Object;
  static parse(json: string, animated: boolean = true): ShellNavigationCommandOptions {
    const value = json.trim().length === 0 ? {} : JSON.parse(json) as Record<string, Object>;
    if (value === null || Array.isArray(value) || typeof value !== 'object') throw new Error('optionsJSON 必须为对象');
    const options = new ShellNavigationCommandOptions(); options.animated = animated;
    if (value['launchMode'] !== undefined) {
      const mode = value['launchMode'];
      if (typeof mode !== 'string' || !['push', 'singleTop', 'clearTop', 'singleTask'].includes(mode as string)) throw new Error('launchMode 只支持push/singleTop/clearTop/singleTask');
      options.launchMode = mode as 'push' | 'singleTop' | 'clearTop' | 'singleTask';
    }
    if (value['animated'] !== undefined) { if (typeof value['animated'] !== 'boolean') throw new Error('animated 必须为布尔值'); options.animated = value['animated'] as boolean; }
    if (value['deduplicate'] !== undefined) { if (typeof value['deduplicate'] !== 'boolean') throw new Error('deduplicate 必须为布尔值'); options.deduplicate = value['deduplicate'] as boolean; }
    if (value['deduplicateWindowMs'] !== undefined) {
      const window = value['deduplicateWindowMs'];
      if (typeof window !== 'number' || !Number.isInteger(window) || window < 0 || window > 5000) throw new Error('deduplicateWindowMs 必须是0..5000整数');
      options.deduplicateWindowMs = window as number;
    }
    if (value['result'] !== undefined) {
      const result = value['result'];
      if (result === null || Array.isArray(result) || typeof result !== 'object') throw new Error('result 必须为对象');
      options.result = result;
    }
    return options;
  }
}
