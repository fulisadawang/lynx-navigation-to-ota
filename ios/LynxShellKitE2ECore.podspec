Pod::Spec.new do |spec|
  spec.name = 'LynxShellKitE2ECore'
  spec.version = '1.0.0'
  spec.summary = 'iOS Store v3 Async/i18n E2E 专用的无地图 Shell Module'
  spec.description = <<-DESC
    仅供本地 LynxShellE2EHost 使用。复用 LynxShellKit 的 Router、Runtime、OTA 和 Resource 源码，
    不依赖 LynxMapKit，也不进入生产 App 的依赖图。
  DESC
  spec.homepage = 'https://github.com/lynx-family/lynx'
  spec.license = { :type => 'Apache-2.0' }
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/lynx-family/lynx.git', :tag => '4.1.0' }
  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxShellKitE2ECore'
  spec.static_framework = true
  spec.requires_arc = true
  spec.resource_bundles = { 'LynxShellKitPrivacy' => ['LynxShellKit/Resources/PrivacyInfo.xcprivacy'] }
  spec.source_files = [
    'LynxShellKit/**/*.{swift,h,m}',
    'OtaIOSSDK/Sources/OtaIOSSDK/**/*.swift',
  ]
  spec.public_header_files = 'LynxShellKit/Native/LynxNativeRuntime.h'
  spec.frameworks = 'Foundation', 'UIKit', 'MobileCoreServices'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LYNX_SHELL_E2E_CORE_ONLY=1',
  }

  spec.dependency 'Lynx/Framework', '4.1.0'
  spec.dependency 'PrimJS/quickjs', '4.1.1'
  spec.dependency 'PrimJS/napi', '4.1.1'
  spec.dependency 'LynxService/Image', '4.1.0'
  spec.dependency 'LynxService/Log', '4.1.0'
  spec.dependency 'LynxService/Http', '4.1.0'
  spec.dependency 'SDWebImage', '5.15.5'
  spec.dependency 'SDWebImageWebPCoder', '0.11.0'
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
end
