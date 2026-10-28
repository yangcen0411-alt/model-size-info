# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module ModelFootprintTools
  module SizeInfo
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('模型占用信息', 'model_size_info/main')
      extension.description = '跟随选择显示群组、组件的独立 SKP 文件体积，并查看整个模型的文件大小。'
      extension.version = '1.0.0'
      extension.creator = 'Model Footprint Tools'
      extension.copyright = '2026 Model Footprint Tools'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
