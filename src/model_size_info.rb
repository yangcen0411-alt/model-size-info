# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module ModelFootprintTools
  module SizeInfo
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('模型占用信息', 'model_size_info/main')
      extension.description = '后台读取已保存的 SKP，按需查看群组与组件的独立文件体积。'
      extension.version = '1.5.0'
      extension.creator = 'Model Footprint Tools'
      extension.copyright = '2026 Model Footprint Tools'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
