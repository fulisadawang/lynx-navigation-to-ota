Pod::Spec.new do |spec|
  spec.name = 'AMapLocation'
  spec.version = '2.12.3'
  spec.summary = 'AMapLocationKit for iOS.'
  spec.homepage = 'https://lbs.amap.com/api/location-sdk-for-ios/summary'
  spec.license = { :type => 'Commercial' }
  spec.author = { 'AMap' => 'lbs@amap.com' }
  spec.source = {
    :http => 'https://a.amap.com/lbs/static/opnavi_resources/AMap_iOS_Loc_Lib_V2.12.3.zip'
  }
  spec.platform = :ios, '9.0'
  spec.vendored_frameworks = 'AMapLocationKit.framework'
  spec.frameworks = 'CoreLocation', 'CoreTelephony', 'SystemConfiguration', 'Security', 'ExternalAccessory'
  spec.libraries = 'z'
  spec.dependency 'AMapFoundation', '>= 1.9.0'
end
