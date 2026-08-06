/** JSON 边界工具：只接受 Object，拒绝数组和基础类型作为 initData/globalProps。 */
export default class ShellJson {
  static normalizeObjectJson(value: string, fallback: string = '{}'): string {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return fallback;
    }
    try {
      const parsed: Object = JSON.parse(trimmed) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        return fallback;
      }
      return JSON.stringify(parsed);
    } catch (error) {
      return fallback;
    }
  }

  static parseObject(value: string): Object {
    const normalized = ShellJson.normalizeObjectJson(value);
    return JSON.parse(normalized) as Object;
  }

  private constructor() {
  }
}
