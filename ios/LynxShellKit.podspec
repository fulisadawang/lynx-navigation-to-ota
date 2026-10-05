# 发布时导出固定git根路径JSON；本地:path仍以现有ios目录为Pod根。
native_source_prefix = ENV['LYNX_NATIVE_REMOTE_SPEC'] == '1' ? 'ios/' : ''

Pod::Spec.new do |spec|
  spec.name = 'LynxShellKit'
  spec.version = '1.1.0'
  spec.summary = 'Lynx 4.1 iOS Router、Runtime、NativeModules、OTA 与原生转场模块'
  spec.description = <<-DESC
    显式单一 CocoaPods Module。包含 Lynx 4.1 容器、手写 NativeModules、资源加载、
    高级导航、Skyline 风格转场、XElement 全量注册以及内置 OTA 事务，不使用 Sparkling autolink。
  DESC
  spec.homepage = 'https://github.com/fulisadawang/lynx-navigation-to-ota'
  spec.license = { :type => 'Apache-2.0' }
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/fulisadawang/lynx-navigation-to-ota.git', :tag => "native-v#{spec.version}" }

  # 与 KMP capp-iOS 主 target 的最低系统版本保持一致；高德 11.2.100 也在此边界内接入。
  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxShellKit'
  spec.static_framework = true
  spec.requires_arc = true
  spec.resource_bundles = { 'LynxShellKitPrivacy' => ["#{native_source_prefix}LynxShellKit/Resources/PrivacyInfo.xcprivacy"] }
  # 生产公开 Pod 默认带地图；本地 E2E 宿主使用独立 Core-only Pod。
  spec.default_subspecs = 'Map'
  # OTA 源码作为 Router 的内部实现一起编译；业务方不需要再引入独立 OTA Pod。
  spec.source_files = [
    "#{native_source_prefix}LynxShellKit/**/*.{swift,h,m}",
    "#{native_source_prefix}OtaIOSSDK/Sources/OtaIOSSDK/**/*.swift",
  ]
  spec.public_header_files = "#{native_source_prefix}LynxShellKit/Native/LynxNativeRuntime.h"
  spec.frameworks = 'Foundation', 'UIKit', 'MobileCoreServices'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  }

  spec.dependency 'Lynx/Framework', '4.1.0'
  spec.dependency 'PrimJS/quickjs', '4.1.1'
  spec.dependency 'PrimJS/napi', '4.1.1'
  spec.dependency 'LynxService/Image', '4.1.0'
  spec.dependency 'LynxService/Log', '4.1.0'
  spec.dependency 'LynxService/Http', '4.1.0'
  spec.dependency 'SDWebImage', '5.15.5'
  spec.dependency 'SDWebImageWebPCoder', '0.11.0'
  # Lynx 4.1 Explorer 对应的 XElement 全量 subspec。
  spec.dependency 'XElement/Input', '4.1.0'
  spec.dependency 'XElement/BlurView', '4.1.0'
  spec.dependency 'XElement/Overlay', '4.1.0'
  spec.dependency 'XElement/ScrollCoordinator', '4.1.0'
  spec.dependency 'XElement/ViewPager', '4.1.0'
  spec.dependency 'XElement/WebView', '4.1.0'
  spec.dependency 'XElement/SVG', '4.1.0'
  spec.dependency 'XElement/Refresh', '4.1.0'
  spec.dependency 'XElement/Markdown', '4.1.0'
  spec.dependency 'XElement/Video', '4.1.0'
  spec.dependency 'XElement/Behavior', '4.1.0'

  spec.subspec 'Map' do |map|
    map.dependency 'LynxMapKit', '1.1.0'
    map.pod_target_xcconfig = {
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LYNX_SHELL_ENABLE_MAP=1',
    }
  end
end
