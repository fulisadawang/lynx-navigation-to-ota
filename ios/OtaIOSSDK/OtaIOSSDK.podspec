Pod::Spec.new do |s|
  s.name             = 'OtaIOSSDK'
  s.version          = '0.1.0'
  s.summary          = 'iOS OTA runtime SDK for Lynx Platform Kit.'
  s.description      = 'Provides OTA release lookup, manifest fetching, bundle syncing, event reporting and current template resolution for Lynx hosts.'
  s.homepage         = 'https://example.invalid/ota-platform'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'OTA Platform' => 'platform@example.invalid' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'
  s.source_files     = 'Sources/OtaIOSSDK/**/*.swift'
  s.swift_version    = '5.9'
end
