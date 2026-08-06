#!/usr/bin/env ruby
# frozen_string_literal: true

# 当本机没有 XcodeGen 时，用 CocoaPods 自带的 xcodeproj gem把 App Target 收口到
# LynxShellSample。LynxShellKit 由 Podfile 注入，不再直接加入 App Compile Sources。

require 'xcodeproj'

project_path = File.expand_path('../LynxShell.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |item| item.name == 'LynxShell' }
raise '找不到 LynxShell target' unless target

target.source_build_phase.files.to_a.each(&:remove_from_project)
target.resources_build_phase.files.to_a.each(&:remove_from_project)

old_group = project.main_group.children.find { |item| item.display_name == 'LynxShell' }
old_group&.remove_from_project
sample_group = project.main_group.children.find { |item| item.display_name == 'LynxShellSample' }
sample_group&.remove_from_project

sample_group = project.main_group.new_group('LynxShellSample', 'LynxShellSample')
source_refs = []

%w[App UI].each do |directory|
  group = sample_group.new_group(directory, directory)
  Dir[File.join(__dir__, '..', 'LynxShellSample', directory, '*.swift')].sort.each do |path|
    source_refs << group.new_file(File.basename(path))
  end
end
target.add_file_references(source_refs)

supporting_group = sample_group.new_group('Supporting', 'Supporting')
%w[Info-Debug.plist Info.plist].each { |name| supporting_group.new_file(name) }
launch_screen = supporting_group.new_file('LaunchScreen.storyboard')
target.add_resources([launch_screen])

resources_group = sample_group.new_group('Resources', 'Resources')
bundles = project.new(Xcodeproj::Project::Object::PBXFileReference)
bundles.name = 'Bundles'
bundles.path = 'Bundles'
bundles.source_tree = '<group>'
bundles.last_known_file_type = 'folder'
resources_group.children << bundles
target.add_resources([bundles])

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings.delete('SWIFT_OBJC_BRIDGING_HEADER')
  settings.delete('SWIFT_OBJC_INTERFACE_HEADER_NAME')
  settings['INFOPLIST_FILE'] =
    configuration.name == 'Debug' \
      ? 'LynxShellSample/Supporting/Info-Debug.plist' \
      : 'LynxShellSample/Supporting/Info.plist'
end

project.save
puts 'LynxShell App Target 已收口到 LynxShellSample。'
