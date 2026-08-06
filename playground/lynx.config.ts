// Playground 只负责编译 Lynx Bundle，并把产物同步到当前手写 iOS / Android 壳。
// 这里不调用 sparkling-app-cli，也不执行任何 autolink/codegen。
import fs from 'node:fs'
import path from 'node:path'
import { defineConfig } from '@lynx-js/rspeedy'
import lynxSharedConfig from './lynx.shared.config.js'

function copyDirectory(source: string, destination: string) {
  if (!fs.existsSync(source)) {
    console.warn(`Bundle 输出目录不存在，跳过同步: ${source}`)
    return
  }

  fs.mkdirSync(destination, { recursive: true })
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    if (entry.name.includes('.hot-update.')) {
      continue
    }

    const sourcePath = path.join(source, entry.name)
    const destinationPath = path.join(destination, entry.name)
    if (entry.isDirectory()) {
      copyDirectory(sourcePath, destinationPath)
    } else if (entry.isFile()) {
      fs.copyFileSync(sourcePath, destinationPath)
    }
  }
}

export default defineConfig({
  ...lynxSharedConfig,
  server: {
    port: 5969,
  },
  plugins: [
    ...(lynxSharedConfig.plugins ?? []),
    {
      name: 'sync-manual-native-shell-bundles',
      setup(api) {
        api.onAfterBuild(() => {
          const source = path.resolve(process.cwd(), 'dist')
          const iosDestination = path.resolve(
            process.cwd(),
            '../ios/LynxShellSample/Resources/Bundles',
          )
          const androidBundleDestination = path.resolve(
            process.cwd(),
            '../android/app/src/main/assets/bundles',
          )
          const androidStaticDestination = path.resolve(
            process.cwd(),
            '../android/app/src/main/assets/Bundles/static',
          )

          copyDirectory(source, iosDestination)
          copyDirectory(source, androidBundleDestination)

          // Bundle 内静态资源沿用 iOS 的 asset:///Bundles/ 前缀。
          // Android 的 assets 路径区分大小写，因此额外同步 static 子目录。
          copyDirectory(path.join(source, 'static'), androidStaticDestination)

          console.log(`Lynx Bundle 已同步到 ${iosDestination}`)
          console.log(`Lynx Bundle 已同步到 ${androidBundleDestination}`)
        })
      },
    },
  ],
})
