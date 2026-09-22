Pod::Spec.new do |spec|
  spec.name = 'LynxShellDebugKit'
  spec.version = '1.0.0'
  spec.summary = 'LynxShell 开发期端内调试面板与只读诊断缓存'
  spec.description = <<-DESC
    仅 Debug configuration 使用的 LynxShell 诊断工具。它复用 Shell 的诊断 SPI，
    在进程内保存有界、脱敏的容器、Bundle、GlobalProps 和监控事件快照，不上传数据。
  DESC
  spec.license = { :type => 'Apache-2.0' }
  spec.homepage = 'https://github.com/lynx-family/lynx'
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/lynx-family/lynx.git', :tag => '4.1.0' }
  spec.platform = :ios, '13.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxShellDebugKit'
  spec.static_framework = true
  spec.source_files = 'LynxShellDebugKit/**/*.{swift,h,m}'
  spec.public_header_files = 'LynxShellDebugKit/Network/LynxDebugHttpCapture.h'
  spec.frameworks = 'Foundation', 'UIKit'
  spec.dependency 'LynxShellKit'
  spec.dependency 'LynxService/Http', '4.1.0'
end
