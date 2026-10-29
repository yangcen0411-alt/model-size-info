# encoding: UTF-8
require 'tmpdir'

module ModelFootprintTools
  module SizeInfo
    # Only a serialized .skp has a meaningful byte size. An instance shares its
    # definition; it has no independently measurable contribution to a model.
    class Analyzer
      attr_reader :model, :revision

      def initialize(model)
        @model = model
        @revision = 0
        @cache = {}
        @model_measurement = nil
      end

      def invalidate
        @revision += 1
        @cache.clear
        @model_measurement = nil
      end

      def entities
        @model.selection.to_a.select(&:valid?)
      end

      def container?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end

      def definitions_for(selection)
        selection.select { |entity| container?(entity) }
                 .map(&:definition).uniq { |definition| definition.persistent_id }
      end

      def cached(definition)
        @cache[definition.persistent_id]
      end

      def cached_by_id(id)
        @cache[id.to_i]
      end

      def disk_file
        path = @model.path.to_s
        exists = !path.empty? && File.file?(path)
        {
          name: exists ? File.basename(path) : '尚未保存的模型',
          bytes: exists ? File.size(path) : nil,
          modified: @model.modified?,
          saved: exists
        }
      rescue SystemCallError, IOError
        { name: '文件暂时无法读取', bytes: nil, modified: @model.modified?, saved: false }
      end

      def snapshot(scope = 'follow')
        file = disk_file
        # Model/tree panels do not need to materialize a potentially huge raw
        # selection just to ignore it.
        return snapshot_model(file) if scope == 'model'
        selection = entities
        if selection.empty?
          snapshot_model(file)
        else
          snapshot_selection(selection, file)
        end
      end

      def measure_definition(definition, force = false)
        return cached(definition) if !force && cached(definition)
        raise '当前 SketchUp 版本不支持组件副本测量，请使用 SketchUp 2022 或更新版本。' unless definition.respond_to?(:save_copy)
        bytes = serialized_bytes { |path| definition.save_copy(path) }
        result = { bytes: bytes, measured_at: Time.now.strftime('%H:%M:%S') }
        @cache[definition.persistent_id] = result
      end

      def measure_model
        bytes = serialized_bytes { |path| @model.save_copy(path) }
        @model_measurement = { bytes: bytes, measured_at: Time.now.strftime('%H:%M:%S') }
      end

      private

      def serialized_bytes
        # The block form cleans up even when SketchUp refuses a save. The source
        # document is never saved over, regrouped, purged, or made unique.
        Dir.mktmpdir('su-model-size-') do |directory|
          path = File.join(directory, 'measurement.skp')
          success = yield(path)
          raise 'SketchUp 未能写入临时 SKP 副本。请检查临时目录可用空间，然后重试。' unless success && File.file?(path)
          File.size(path)
        end
      end

      def snapshot_model(file)
        current = @model_measurement
        {
          kind: 'model',
          title: @model.title.to_s.empty? ? '未命名模型' : @model.title,
          subtitle: '整个模型',
          measurement_label: current ? '当前模型副本体积' : '上次保存的文件体积',
          bytes: current ? current[:bytes] : file[:bytes],
          measurement_state: current || file[:saved] ? 'ready' : 'unsaved',
          measured_at: current && current[:measured_at],
          selected_count: 0,
          definition_count: @model.definitions.length,
          direct_entities: @model.entities.length,
          instance_count: nil,
          loose_count: 0,
          pending_count: 0,
          rows: [],
          file: file,
          note: current ? '临时保存当前模型副本，包含尚未保存的修改；原文件未被覆盖。' :
            (file[:modified] ? '当前存在未保存修改。上方数值来自上次保存的文件，可点击下方按钮测量当前版本。' :
              '从磁盘读取实际文件大小；包含模型中保留的组件定义、材质、场景等数据。')
        }
      end

      def snapshot_selection(selection, file)
        rows = {}
        loose_count = 0
        selection.each do |entity|
          unless container?(entity)
            loose_count += 1
            next
          end
          definition = entity.definition
          key = definition.persistent_id
          rows[key] ||= {
            id: key.to_s,
            name: definition.name.to_s.empty? ? '未命名定义' : definition.name,
            kind: entity.is_a?(Sketchup::Group) ? '群组' : '组件',
            selected_instances: 0,
            bytes: cached(definition) && cached(definition)[:bytes]
          }
          rows[key][:selected_instances] += 1
        end
        values = rows.values.sort_by { |row| [row[:bytes] ? 0 : 1, -(row[:bytes] || 0), row[:name]] }
        pending = values.count { |row| row[:bytes].nil? }
        complete = !values.empty? && pending.zero? && loose_count.zero?
        single = selection.length == 1 && container?(selection.first)
        first = selection.first
        title = if single
                  first.name.to_s.empty? ? first.definition.name : first.name
                else
                  "已选择 #{selection.length} 个图元"
                end
        note = if loose_count > 0
                 "包含 #{loose_count} 个散线、面、图片或其他图元：这些图元没有独立 SKP 文件。请先创建群组或组件再测量完整选择。"
               elsif values.length > 1
                 '不同定义各自保存为 SKP 后相加；相同定义只计一次。共享的嵌套数据可能在不同文件中重复，因此合计不等于合并后的文件大小。'
               else
                 '显示组件定义单独保存为 SKP 的实际体积，包含定义内的嵌套对象与材质。实例外层的材质、缩放等覆盖不计入。'
               end
        {
          kind: 'selection',
          title: title.to_s.empty? ? '未命名对象' : title,
          subtitle: single ? (first.is_a?(Sketchup::Group) ? '群组' : '组件') : '多项选择',
          measurement_label: values.length > 1 ? '独立文件体积合计（定义去重）' : '独立组件 SKP 体积',
          bytes: complete ? values.inject(0) { |sum, row| sum + row[:bytes] } : nil,
          measurement_state: values.empty? ? 'unsupported' : (complete ? 'ready' : (loose_count > 0 ? 'partial' : 'pending')),
          measured_at: nil,
          selected_count: selection.length,
          definition_count: values.length,
          direct_entities: single ? first.definition.entities.length : nil,
          instance_count: single ? first.definition.count_used_instances : nil,
          loose_count: loose_count,
          pending_count: pending,
          rows: values,
          file: file,
          note: note
        }
      end
    end
  end
end
