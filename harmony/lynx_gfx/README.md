# HarmonyOS Lynx Gfx 4.1.0

这个模块提供 `@lynx/gfx` 在 HarmonyOS 上缺失的原生动态库。Lynx 官方 `@lynx/gfx@4.1.0` HAR 的 ArkTS 与构建元数据完整，但发布包没有携带 `liblynxgfx.so`；而 `@lynx/lynx@4.1.0` 在动态依赖中明确声明了这个库，导致应用在 `EntryAbility` 执行前装载失败。

当前目录中的两个 ELF 文件均从 Lynx 官方 `4.1.0` tag（commit `b7eb5a809c0526bcfdca8c629848e01475f70ad9`）的 `gfx/platform/harmony` GN target 构建：

- `libs/arm64-v8a/liblynxgfx.so`：真机/arm64 模拟器。
- `libs/x86_64/liblynxgfx.so`：x86_64 模拟器。

当前文件 SHA-256：arm64 `4a353e2e5215085c2ce96570dfa75481ab67744bc2fd76d4dc03791e0641e309`，
x86_64 `56cb1c9e2ed69a9710edbaa104dd8308d47fd3a295b15ee2ba6f771a0cb3da6b`。

两个库只依赖同版本的 `liblynxbase.so` 和系统 C/C++ 运行库，并覆盖 `@lynx/lynx@4.1.0` 的全部 `lynx::gfx` 未定义符号。不要用 4.2/4.3 nightly 的 Gfx 二进制替换它们；nightly 与稳定版核心混用没有经过 ABI 验证。

根工程通过 `oh-package.json5` 的项目级 override 将 `@lynx/gfx` 固定到本地 HAR，并把 `lynx_gfx` 注册到 `build-profile.json5`，所以最终 HAP 会同时包含 `liblynx.so` 与 `liblynxgfx.so`。
