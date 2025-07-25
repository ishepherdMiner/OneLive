Pod::Spec.new do |s|
  s.name = 'FFMpeg'
  s.version = '1.0.0'
  s.source = { :git => 'https://github.com/your/repo.git', :tag => s.version.to_s }
  s.author = "webrtc-sdk"

  s.ios.deployment_target = "13.0"
  s.osx.deployment_target = "10.15"
  s.tvos.deployment_target = "17.0"
  s.visionos.deployment_target = "1.0"
  s.license = "MIT"
  s.homepage = "https://www.example.com"
  s.summary = "FFMpeg library"
  # 指定头文件路径（保留层级结构）
  s.header_mappings_dir = 'include'  # 确保头文件层级不变
  s.source_files = 'include/**/*.h'  # 包含所有头文件
  s.public_header_files = 'include/**/*.h'  # 公开头文件

  # 指定静态库路径
  s.vendored_libraries = 'lib/*.a'  # 链接所有.a文件

  # 保留include的原始目录结构（防止CocoaPods清理）
  s.preserve_paths = 'include/**/*.h', 'lib/*.a'
end