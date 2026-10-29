# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    # Only requested drawing contexts are read. Opening the panel never walks
    # DefinitionList or fetches all instances of every component definition.
    class ComponentTree
      attr_reader :scanned_instances, :scanned_definitions, :entry_count,
                  :definitions_by_id, :last_read_seconds

      def initialize(model)
        @model = model
        @roots, @children, @instances = [], {}, {}
        @definitions_by_id, @definition_ids, @names = {}, {}, {}
        @loaded, @queued, @dirty = {}, { nil => true }, {}
        @jobs, @job_offset = [nil], 0
        @active = nil
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

      def step(limit = 1000, seconds = 0.012)
        return true if complete?
        deadline = monotonic + seconds
        processed = 0
        loop do
          start_next unless @active
          break unless @active
          while @active[:offset] < @active[:items].length && processed < limit
            id, entity = @active[:items][@active[:offset]]
            @active[:offset] += 1
            add_node(id, entity, @active[:destination])
            processed += 1
            break if (processed % 32).zero? && monotonic >= deadline
          end
          finish_active if @active[:offset] == @active[:items].length
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
        # Type filtering is confined to this context. It does not descend into
        # unopened definitions or create a Ruby Enumerator for every face.
        items = entities.grep(Sketchup::Group) + entities.grep(Sketchup::ComponentInstance)
        items = items.select(&:valid?).map { |entity| [entity.persistent_id.to_s, entity] }
        items.sort_by! { |entry| entry[0].to_i }
        @active = { id: id, items: items, offset: 0, started: started,
                    destination: id ? @children.fetch(id) : @roots }
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
        if id
          @loaded[id] = true
          @dirty[id] = true
          @scanned_definitions += 1
        else
          @root_loaded = @roots_dirty = true
        end
        @queued.delete(id)
        @active = nil
      end

      def definition_data(id)
        { name: @names.fetch(id), children: @loaded[id] ? @children.fetch(id) : nil,
          loaded: !!@loaded[id], loading: !!@queued[id] }
      end
    end
  end
end
