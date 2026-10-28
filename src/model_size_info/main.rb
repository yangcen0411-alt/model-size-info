# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require File.join(__dir__, 'analyzer')
require File.join(__dir__, 'component_tree')
require File.join(__dir__, 'panel')

module ModelFootprintTools
  module SizeInfo
    VERSION = '1.1.0'.freeze unless const_defined?(:VERSION)

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
      command.tooltip = '查看群组、组件与模型的 SKP 文件大小'
      command.status_bar_text = '打开模型占用信息面板；选中群组或组件即可查看独立文件体积。'
      UI.menu('Extensions').add_item(command)
      UI.add_context_menu_handler { |menu| menu.add_item(command) }
      file_loaded(__FILE__)
    end
  end
end
