# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    # Store the definition graph once, rather than expanding every instance path.
    # A shared nested definition can occur on millions of paths in a large model.
    class ComponentTree
      attr_reader :scanned_entities, :entry_count

      def initialize(model)
        @roots = []
        @children = {}
        @definitions = {}
        @instances = {}
        @tasks = [[model.entities, @roots]]
        @task_index = 0
        @iterator = nil
        @scanned_entities = 0
        @entry_count = 0
        @complete = false
      end

      def complete?
        @complete
      end

      def definitions
        @definitions.values
      end

      def root_count
        @roots.length
      end

      # Called in small timer slices so scanning dense geometry can be stopped.
      def step(limit = 2000)
        return true if @complete
        limit.times do
          unless @iterator
            task = @tasks[@task_index]
            unless task
              @complete = true
              break
            end
            @task_index += 1
            @iterator = task[0].to_enum(:each)
            @destination = task[1]
          end
          begin
            entity = @iterator.next
          rescue StopIteration
            @iterator = nil
            next
          end
          @scanned_entities += 1
          next unless entity.valid? && container?(entity)
          definition = entity.definition
          next unless definition.valid?
          definition_id = definition.persistent_id.to_s
          unless @definitions.key?(definition_id)
            @definitions[definition_id] = definition
            @children[definition_id] = []
            @tasks << [definition.entities, @children[definition_id]]
          end
          id = entity.persistent_id.to_s
          @instances[id] = entity
          @destination << {
            id: id,
            definition_id: definition_id,
            name: entity.name.to_s,
            kind: entity.is_a?(Sketchup::Group) ? '群组' : '组件',
            hidden: entity.hidden?,
            locked: entity.locked?
          }
          @entry_count += 1
        end
        @complete
      end

      def payload
        raise '模型结构仍在扫描，请稍候。' unless complete?
        definitions = {}
        @definitions.each do |id, definition|
          definitions[id] = { name: definition.name.to_s, children: @children.fetch(id) }
        end
        { roots: @roots, definitions: definitions }
      end

      def resolve(path)
        raise '模型结构尚未就绪，请先扫描。' unless complete?
        unless path.is_a?(String) && path.bytesize <= 8192 && path.match?(/\A\d+(?:\.\d+)*\z/)
          raise '对象路径无效，请重新扫描模型。'
        end
        allowed = @roots
        seen = {}
        result = []
        path.split('.').each do |id|
          node = allowed.find { |entry| entry[:id] == id }
          entity = @instances[id]
          raise '此对象已变化或不在当前模型层级中，请重新扫描。' unless node && entity && entity.valid?
          definition_id = node[:definition_id]
          raise '此层级包含循环引用，无法定位。' if seen[definition_id]
          seen[definition_id] = true
          result << entity
          allowed = @children.fetch(definition_id)
        end
        result
      end

      private

      def container?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end
    end
  end
end
