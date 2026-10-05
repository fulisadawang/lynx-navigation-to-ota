# 发布时导出固定git根路径JSON；本地:path仍以现有ios目录为Pod根。
native_source_prefix = ENV['LYNX_NATIVE_REMOTE_SPEC'] == '1' ? 'ios/' : ''

Pod::Spec.new do |spec|
  spec.name = 'LynxShellDebugKit'
  spec.version = '1.1.0'
  spec.summary = 'LynxShell 开发期端内调试面板与只读诊断缓存'
  spec.description = <<-DESC
    仅 Debug configuration 使用的 LynxShell 诊断工具。它复用 Shell 的诊断 SPI，
    在进程内保存有界、脱敏的容器、Bundle、GlobalProps 和监控事件快照，不上传数据。
  DESC
  spec.license = { :type => 'Apache-2.0' }
  spec.homepage = 'https://github.com/fulisadawang/lynx-navigation-to-ota'
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/fulisadawang/lynx-navigation-to-ota.git', :tag => "native-v#{spec.version}" }
  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxShellDebugKit'
  spec.static_framework = true
  spec.source_files = "#{native_source_prefix}LynxShellDebugKit/**/*.{swift,h,m}"
  spec.public_header_files = "#{native_source_prefix}LynxShellDebugKit/Network/LynxDebugHttpCapture.h"
  spec.frameworks = 'Foundation', 'UIKit'
  # 由消费Podfile以configurations: ['Debug']显式引入，不能作为Shell生产依赖。
  spec.dependency 'LynxShellKit', '1.1.0'
  spec.dependency 'LynxService/Http', '4.1.0'
end
