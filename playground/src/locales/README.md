# Playground 语言资源边界

Playground 的宿主语言由 `LocaleProvider` 从 Lynx 4.0 GlobalProps 和
`lynxShellLocaleChanged` 事件取得，规范化为 `zh-CN` / `en-US`。每个 Bundle 都有独立
的 JavaScript 运行时，因此每个 Bundle 需要在自己的入口注册资源或创建自己的 i18next
实例；宿主只负责保存 App 语言、向活体页面同步状态和给后续页面补 `locale` 参数。

业务资源可以直接放在本目录，或者由 Bundle 自己管理，再通过
`playground/src/lib/i18n.ts` 的 `configureLocaleResources` 注册。资源对象的形状为：

```ts
{
  'zh-CN': { 'settings.title': '...' },
  'en-US': { 'settings.title': '...' },
}
```

`translate(locale, key, fallback)` 在资源缺失时返回调用方的 fallback，不把缺失资源伪装成
加载成功。需要使用 Lynx 官方国际化建议的 i18next 时，Bundle 可在此边界接入自己的
`i18next@23` 实例并调用 `registerI18nInstance`；宿主语言变化时会调用该实例的
`changeLanguage`。本仓库当前不替用户提交具体业务文案和额外依赖。
