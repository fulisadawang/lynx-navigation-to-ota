// Copyright (c) 2025 TikTok Pte. Ltd.
// Licensed under the Apache License Version 2.0 that can be found in the
// LICENSE file in the root directory of this source tree.
import { defineConfig } from '@lynx-js/rspeedy'
import { pluginQRCode } from '@lynx-js/qrcode-rsbuild-plugin'
import { pluginReactLynx } from '@lynx-js/react-rsbuild-plugin'

function toSparklingScheme(url: string) {
  const devUrl = new URL(url)
  devUrl.searchParams.set('fullscreen', 'true')
  return `hybrid://lynxview_page?url=${encodeURIComponent(devUrl.toString())}`
}

export default defineConfig({
  source: {
    entry: {
      main: './src/pages/main/index.tsx',
      showcase: './src/pages/showcase/index.tsx',
      'scheme-builder': './src/pages/scheme-builder/index.tsx',
      'scheme-presets': './src/pages/scheme-presets/index.tsx',
      'go-bundles': './src/pages/go-bundles/index.tsx',
      'nav-basic': './src/pages/nav-basic/index.tsx',
      'i18n-demo': './src/pages/i18n-demo/index.tsx',
      'video-demo': './src/pages/video-demo/index.tsx',
      'map-diagnostic': './src/pages/map-diagnostic/index.tsx',
      'map-layout': './src/pages/map-layout/index.tsx',
      'map-scenarios': './src/pages/map-scenarios/index.tsx',
      'map-scenario-detail': './src/pages/map-scenario-detail/index.tsx',
      'map-bottom-sheet': './src/pages/map-bottom-sheet/index.tsx',
      'map-route-demo': './src/pages/map-route-demo/index.tsx',
      'map-navigation-demo': './src/pages/map-navigation-demo/index.tsx',
      'map-marker-overlay-demo': './src/pages/map-marker-overlay-demo/index.tsx',
      'map-mass-points-demo': './src/pages/map-mass-points-demo/index.tsx',
      'map-marker-demo': './src/pages/map-marker-demo/index.tsx',
      'map-layer-demo': './src/pages/map-layer-demo/index.tsx',
      'map-poi-demo': './src/pages/map-poi-demo/index.tsx',
      'map-performance': './src/pages/map-performance/index.tsx',
      'map-location': './src/pages/map-location/index.tsx',
      'nav-chain': './src/pages/nav-chain/index.tsx',
      'transition-gallery': './src/pages/transition-gallery/index.tsx',
      'transition-detail': './src/pages/transition-detail/index.tsx',
      'gp-device': './src/pages/gp-device/index.tsx',
      'gp-screen': './src/pages/gp-screen/index.tsx',
      'gp-container': './src/pages/gp-container/index.tsx',
      'storage-demo': './src/pages/storage-demo/index.tsx',
      'media-choose': './src/pages/media-choose/index.tsx',
      'media-upload': './src/pages/media-upload/index.tsx',
      'media-download': './src/pages/media-download/index.tsx',
    },
  },
  output: {
    // 使用小写 bundles 作为跨端逻辑资源前缀；iOS Provider 会把 bundles/ 映射到
    // App Bundle 内实际的 Bundles folder reference，Android/HarmonyOS 保持小写路径。
    assetPrefix: 'asset:///bundles/',
    filename: {
      bundle: '[name].lynx.bundle',
    },
  },
  plugins: [
    pluginQRCode({
      schema(url) {
        return toSparklingScheme(url)
      },
    }),
    // 4.1 Runtime 才能消费本次 Bundle；engineVersion 会同时写入 targetSdkVersion。
    pluginReactLynx({ engineVersion: '4.1.0' }),
  ],
})
