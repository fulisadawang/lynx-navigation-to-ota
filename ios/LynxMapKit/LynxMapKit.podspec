Pod::Spec.new do |spec|
  spec.name = 'LynxMapKit'
  spec.version = '1.0.0'
  spec.summary = 'Lynx Native Map Element、AMap Provider、Search 与 Location 模块'
  spec.description = <<-DESC
    独立地图能力 Module。包含 LynxMap Native Element、AMap 11.2.100 Provider、
    AMapSearchKit 9.8.1、AMapLocationKit 2.12.3，以及 Shell 需要的最小注册/隐私配置接口。
    不依赖 LynxShellKit，Shell 只通过 LynxMapModuleRuntime 接入。
  DESC
  spec.homepage = 'https://lbs.amap.com/'
  spec.license = { :type => 'Apache-2.0' }
  spec.author = { 'LynxMapKit' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/lynx-family/lynx.git', :tag => '4.1.0' }

  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxMapKit'
  spec.static_framework = true
  spec.requires_arc = true

  spec.source_files = '**/*.{h,m,swift}'
  spec.public_header_files = 'LynxMapModuleRuntime.h'
  spec.frameworks = 'Foundation', 'UIKit', 'CoreLocation'
  spec.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  }

  spec.dependency 'Lynx/Framework', '4.1.0'
  spec.dependency 'AMap3DMap', '11.2.100'
  spec.dependency 'AMapLocation', '2.12.3'
  spec.dependency 'AMapSearch', '9.8.1'
  spec.dependency 'SDWebImage', '5.15.5'
end
