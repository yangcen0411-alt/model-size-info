# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module ModelFootprintTools
  module SizeInfo
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('模型占用信息', 'model_size_info/main')
      extension.description = '跟随选择显示 SKP 文件体积，按模型组件树查看嵌套对象大小，并定位模型中的对象。'
      extension.version = '1.2.0'
      extension.creator = 'Model Footprint Tools'
      extension.copyright = '2026 Model Footprint Tools'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
