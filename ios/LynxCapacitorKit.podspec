# 发布时导出固定git根路径JSON；本地:path仍以现有ios目录为Pod根。
native_source_prefix = ENV['LYNX_NATIVE_REMOTE_SPEC'] == '1' ? 'ios/' : ''

Pod::Spec.new do |spec|
  spec.name = 'LynxCapacitorKit'
  spec.version = '1.1.0'
  spec.summary = 'Lynx 4.1 页面使用的独立原生能力模块'
  spec.homepage = 'https://github.com/fulisadawang/lynx-navigation-to-ota'
  spec.license = { :type => 'Apache-2.0' }
  spec.author = { 'LynxShell' => 'local-module@example.invalid' }
  spec.source = { :git => 'https://github.com/fulisadawang/lynx-navigation-to-ota.git', :tag => "native-v#{spec.version}" }
  spec.platform = :ios, '14.0'
  spec.swift_version = '5.0'
  spec.module_name = 'LynxCapacitorKit'
  spec.static_framework = true
  spec.requires_arc = true
  spec.resource_bundles = { 'LynxCapacitorKitPrivacy' => ["#{native_source_prefix}LynxCapacitorKit/Resources/PrivacyInfo.xcprivacy"] }
  spec.source_files = ["#{native_source_prefix}LynxCapacitorKit/Bridge/**/*.swift", "#{native_source_prefix}LynxCapacitorKit/Capabilities/**/*.swift"]
  spec.dependency 'Lynx/Framework', '4.1.0'
  spec.frameworks = 'UIKit', 'AVFoundation', 'AVKit', 'AudioToolbox', 'BackgroundTasks',
                    'Contacts', 'CoreHaptics', 'CoreLocation', 'CoreMotion', 'EventKit',
                    'LocalAuthentication', 'Network', 'Photos', 'PhotosUI', 'QuickLook',
                    'SafariServices', 'UniformTypeIdentifiers', 'UserNotifications', 'WebKit'
  spec.libraries = 'sqlite3'
end
