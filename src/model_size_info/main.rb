# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require File.join(__dir__, 'analyzer')
require File.join(__dir__, 'component_tree')
require File.join(__dir__, 'panel')

module ModelFootprintTools
  module SizeInfo
    VERSION = '1.5.0'.freeze unless const_defined?(:VERSION)

    def self.show
      if Sketchup.version.to_i < 22
        UI.messagebox('模型占用信息需要 SketchUp 2022 或更新版本（桌面版）。')
        return
      end
      @panel ||= Panel.new
      @panel.show
    end

    unless file_loaded?(__FILE__)
      command = UI::Command.new('模型占用信息') { show }
      icon_extension = Sketchup.platform == :platform_win ? 'svg' : 'pdf'
      icon_path = File.join(__dir__, 'icons', "model_size_info.#{icon_extension}")
      command.small_icon = icon_path
      command.large_icon = icon_path
      command.tooltip = '后台查看已保存模型与组件的 SKP 文件大小'
      command.status_bar_text = '打开模型占用信息面板，按需计算已保存文件中的群组和组件大小。'
      UI.menu('Extensions').add_item(command)
      UI.add_context_menu_handler { |menu| menu.add_item(command) }
      @toolbar = UI::Toolbar.new('模型占用信息')
      @toolbar.add_item(command)
      if @toolbar.get_last_state == TB_NEVER_SHOWN
        @toolbar.show
      else
        @toolbar.restore
      end
      file_loaded(__FILE__)
    end
  end
end
