Pod::Spec.new do |spec|
  spec.name = 'LynxShellKit'
  spec.version = '1.0.0'
  spec.summary = 'Lynx 4.1 iOS Router、Runtime、NativeModules、OTA 与原生转场模块'
  spec.description = <<-DESC
    显式单一 CocoaPods Module。包含 Lynx 4.1 容器、手写 NativeModules、资源加载、
    高级导航、Skyline 风格转场、XElement 全量注册以及内置 OTA 事务，不使用 Sparkling autolink。
  DESC
  spec.homepage = 'https://github.com/lynx-family/lynx'
  spec.license = { :type => 'Apache-2.0' }
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  # 开发 Pod 由 Podfile 的 :path 指定本地源码；该 source 仅满足 Podspec 元数据。
  spec.source = { :git => 'https://github.com/lynx-family/lynx.git', :tag => '4.1.0' }

  # 与 KMP capp-iOS 主 target 的最低系统版本保持一致；高德 11.2.100 也在此边界内接入。
  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxShellKit'
  spec.static_framework = true
  spec.requires_arc = true

  # OTA 源码作为 Router 的内部实现一起编译进 LynxShellKit；业务方不需要再引入独立 OTA Pod。
  spec.source_files = [
    'LynxShellKit/**/*.{swift,h,m}',
    'OtaIOSSDK/Sources/OtaIOSSDK/**/*.swift',
  ]
  spec.public_header_files = 'LynxShellKit/Native/LynxNativeRuntime.h'
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
  # 地图能力由独立 LynxMapKit Module 提供；Shell 只负责容器/runtime 接入与 Config 注册。
  spec.dependency 'LynxMapKit', '1.0.0'
end
