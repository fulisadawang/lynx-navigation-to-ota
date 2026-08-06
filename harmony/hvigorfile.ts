import { appTasks } from '@ohos/hvigor-ohos-plugin';

/**
 * 标准业务壳只使用 OHPM 发布包，因此不需要 Explorer 源码工程里的 GN/CMake 插件。
 * 这样打开工程后不会隐式编译 Lynx Core，也不会依赖 Lynx monorepo 相对路径。
 */
export default {
  system: appTasks,
  plugins: []
};
