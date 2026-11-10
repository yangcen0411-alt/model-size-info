# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    # Only requested drawing contexts are read. Opening the panel never walks
    # DefinitionList or fetches all instances of every component definition.
    class ComponentTree
      class ContextListener < Sketchup::EntitiesObserver
        def initialize(index)
          @index = index
        end

        def onElementAdded(_entities, _entity)
          @index.context_changed
        end
        alias_method :onElementModified, :onElementAdded
        alias_method :onElementRemoved, :onElementAdded

        def onEraseEntities(_entities)
          @index.context_changed
        end
      end

      attr_reader :scanned_instances, :scanned_definitions, :entry_count,
                  :definitions_by_id, :last_read_seconds

      def initialize(model)
        @model = model
        @roots, @children, @instances = [], {}, {}
        @definitions_by_id, @definition_ids, @names = {}, {}, {}
        @loaded, @queued, @dirty = {}, { nil => true }, {}
        @jobs, @job_offset = [nil], 0
        @active = nil
        @context_listener = ContextListener.new(self)
        @context_changed = false
        @root_loaded = @roots_dirty = @eager = false
        @scanned_instances = @scanned_definitions = @entry_count = 0
        @last_read_seconds = nil
      end

      def complete?
        @root_loaded && @active.nil? && @job_offset == @jobs.length
      end

      def all_loaded?
        complete? && @definitions_by_id.keys.all? { |id| @loaded[id] }
      end

      def definitions
        @definitions_by_id.values
      end

      def root_count
        @roots.length
      end

      def request(id)
        raise '此定义不在当前组件树中，请刷新后重试。' unless @definitions_by_id.key?(id)
        return false if @loaded[id] || @queued[id]
        @jobs << id
        @queued[id] = true
        @dirty[id] = true
        true
      end

      def request_all
        @eager = true
        @definitions_by_id.each_key { |id| request(id) }
      end

      def context_changed
        @context_changed = true
      end

      def dispose
        detach_context
        @context_changed = true
      end

      def read_progress
        return nil unless @active
        { read: @active[:offset], total: @active[:total] }
      end

      def step(limit = 1000, seconds = 0.008)
        raise '模型内容已变化，请刷新列表后继续读取。' if @context_changed
        return true if complete?
        deadline = monotonic + seconds
        processed = 0
        loop do
          start_next unless @active
          break unless @active
          raise '模型内容已变化，请刷新列表后继续读取。' if @context_changed
          begin
            entity = @active[:iterator].next
          rescue StopIteration
            finish_active
          end
          if @active
            raise '模型内容已变化，请刷新列表后继续读取。' if @context_changed
            @active[:offset] += 1
            if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              add_node(entity.persistent_id.to_s, entity, @active[:destination])
            end
            processed += 1
          end
          break if processed >= limit || monotonic >= deadline
        end
        complete?
      end

      def payload
        { roots: @roots, definitions: @definitions_by_id.keys.to_h { |id| [id, definition_data(id)] } }
      end

      def delta
        return nil if @dirty.empty? && !@roots_dirty
        { roots: @roots_dirty ? @roots : nil,
          definitions: @dirty.keys.to_h { |id| [id, definition_data(id)] } }
      end

      def acknowledge_delta
        @dirty.clear
        @roots_dirty = false
      end

      def resend
        @roots_dirty = true if @root_loaded
        @definitions_by_id.each_key { |id| @dirty[id] = true }
      end

      def resolve(path)
        raise '顶层目录尚未就绪，请稍候。' unless @root_loaded
        unless path.is_a?(String) && path.bytesize <= 8192 && path.match?(/\A\d+(?:\.\d+)*\z/)
          raise '对象路径无效，请重新扫描模型。'
        end
        allowed, seen, result = @roots, {}, []
        path.split('.').each do |id|
          node = allowed.find { |entry| entry[:id] == id }
          entity = @instances[id]
          raise '此对象已变化或不在当前模型层级中，请刷新。' unless node && entity && entity.valid?
          definition_id = node[:definition_id]
          raise '此层级包含循环引用，无法定位。' if seen[definition_id]
          seen[definition_id] = true
          result << entity
          allowed = @children.fetch(definition_id)
        end
        result
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def start_next
        return if @job_offset == @jobs.length
        id = @jobs[@job_offset]
        @job_offset += 1
        started = monotonic
        entities = id ? @definitions_by_id.fetch(id).entities : @model.entities
        # Resume one native iterator between timer callbacks. Every visited
        # entity, including raw geometry, counts against the slice budget.
        @active = { id: id, entities: entities, iterator: entities.to_enum(:each),
                    offset: 0, total: entities.length, started: started,
                    destination: id ? @children.fetch(id) : @roots }
        entities.add_observer(@context_listener)
      end

      def add_node(id, entity, destination)
        return unless entity.valid?
        definition = entity.definition
        return unless definition.valid?
        definition_id = @definition_ids[definition]
        unless definition_id
          definition_id = definition.persistent_id.to_s
          @definition_ids[definition] = definition_id
        end
        unless @definitions_by_id.key?(definition_id)
          @definitions_by_id[definition_id] = definition
          @names[definition_id] = definition.name.to_s
          @children[definition_id] = []
          @dirty[definition_id] = true
          request(definition_id) if @eager
        end
        destination << { id: id, definition_id: definition_id, name: entity.name.to_s,
          kind: entity.is_a?(Sketchup::Group) ? '群组' : '组件',
          hidden: entity.hidden?, locked: entity.locked? }
        @instances[id] = entity
        @scanned_instances += 1
        @entry_count += 1
      end

      def finish_active
        id = @active[:id]
        @last_read_seconds = monotonic - @active[:started]
        detach_context
        if id
          @loaded[id] = true
          @dirty[id] = true
          @scanned_definitions += 1
        else
          @root_loaded = @roots_dirty = true
        end
        @queued.delete(id)
      end

      def detach_context
        @active[:entities].remove_observer(@context_listener) if @active
      rescue StandardError
        # A deleted drawing context may have disposed its native collection.
      ensure
        @active = nil
      end

      def definition_data(id)
        { name: @names.fetch(id), children: @loaded[id] ? @children.fetch(id) : nil,
          loaded: !!@loaded[id], loading: !!@queued[id] }
      end
    end
  end
end
