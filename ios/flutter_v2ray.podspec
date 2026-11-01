#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_v2ray.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_v2ray_client'
  s.version          = '3.5.0'
  s.summary          = 'Flutter client plugin for Xray/V2Ray on Android and iOS (VPN & Proxy mode).'
  s.description      = <<-DESC
Flutter plugin providing V2Ray/Xray client control (VPN mode via NEPacketTunnelProvider & Proxy-only mode, server delay checks, traffic statistics, and log management) on Android and iOS.
                       DESC
  s.homepage         = 'https://github.com/amir-zr/flutter_v2ray_client'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Amir Ziari' => 'ahz85955@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'NetworkExtension', 'SystemConfiguration'
  s.libraries        = 'resolv', 'c++'

  # Automatically link LibXray.xcframework (or any custom *.xcframework) placed in ios/Frameworks/
  frameworks_dir = File.join(__dir__, 'Frameworks')
  xcframeworks = Dir.glob(File.join(frameworks_dir, '*.xcframework')).map { |f| "Frameworks/#{File.basename(f)}" }
  unless xcframeworks.empty?
    s.vendored_frameworks = xcframeworks
  end

  # Bundle geoip.dat / geosite.dat if placed in ios/Assets/
  assets_dir = File.join(__dir__, 'Assets')
  if Dir.exist?(assets_dir) && !Dir.empty?(assets_dir)
    s.resources = ['Assets/*']
  end

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'OTHER_LDFLAGS' => '-ObjC'
  }
  s.swift_version = '5.0'
end
