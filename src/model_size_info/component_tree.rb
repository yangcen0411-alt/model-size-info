# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    # Build the hierarchy from native instance lists and parent links. Never walk
    # Entities: even a leaf component can hold millions of faces and edges.
    # Keep shared definitions compact rather than expanding every instance path.
    class ComponentTree
      attr_reader :scanned_instances, :scanned_definitions, :entry_count

      def initialize(model)
        @model = model
        @roots = []
        @children = {}
        @definitions = {}
        @instances = {}
        @definition_iterator = model.definitions.to_enum(:each)
        @instance_iterator = nil
        @candidates = {}
        @candidate_instances = {}
        @candidate_children = {}
        @owners = [nil]
        @owner_offset = 0
        @child_iterator = nil
        @phase = :index
        @scanned_instances = 0
        @scanned_definitions = 0
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
        @complete ? @roots.length : (@candidate_children[nil] || []).length
      end

      # Both the item cap and time budget yield to SketchUp's UI. The native
      # instances call is synchronous, but contains no faces or edges.
      def step(limit = 2000, seconds = 0.015)
        return true if @complete
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        limit.times do |number|
          @phase == :index ? index_next : link_next
          break if @complete
          break if (number % 64).zero? && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
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

      def index_next
        unless @instance_iterator
          begin
            definition = @definition_iterator.next
          rescue StopIteration
            @definition_iterator = nil
            @phase = :link
            return
          end
          @scanned_definitions += 1
          return unless definition.valid? && !definition.image?
          @current_definition_id = definition.persistent_id.to_s
          @candidates[@current_definition_id] = definition
          @instance_iterator = definition.instances.each
          return
        end
        begin
          entity = @instance_iterator.next
        rescue StopIteration
          @instance_iterator = nil
          return
        end
        return unless container?(entity) && entity.valid?
        @scanned_instances += 1
        owner = entity.parent
        # Modern SketchUp returns the containing definition. Normalize a group
        # wrapper as well, without opening its geometry collection.
        owner = owner.definition if container?(owner)
        owner_id = if owner == @model
                     nil
                   elsif owner.is_a?(Sketchup::ComponentDefinition) && owner.valid?
                     owner.persistent_id.to_s
                   else
                     return
                   end
        id = entity.persistent_id.to_s
        return if @candidate_instances.key?(id)
        @candidate_instances[id] = entity
        (@candidate_children[owner_id] ||= []) << {
          id: id, definition_id: @current_definition_id, name: entity.name.to_s,
          kind: entity.is_a?(Sketchup::Group) ? '群组' : '组件',
          hidden: entity.hidden?, locked: entity.locked?
        }
      end

      def link_next
        unless @child_iterator
          if @owner_offset == @owners.length
            @complete = true
            # Drop unused-definition subtrees after determining reachability.
            @candidates = @candidate_children = @candidate_instances = nil
            return
          end
          owner_id = @owners[@owner_offset]
          @owner_offset += 1
          @destination = owner_id ? @children.fetch(owner_id) : @roots
          # Native instance lists are grouped by definition. Use object IDs for
          # deterministic sibling order without enumerating their Entities.
          nodes = @candidate_children[owner_id] || []
          @child_iterator = nodes.sort_by { |node| node[:id].to_i }.each
        end
        begin
          node = @child_iterator.next
        rescue StopIteration
          @child_iterator = nil
          return
        end
        definition_id = node[:definition_id]
        definition = @candidates[definition_id]
        instance = @candidate_instances[node[:id]]
        return unless definition && definition.valid? && instance.valid?
        @destination << node
        @instances[node[:id]] = instance
        @entry_count += 1
        return if @definitions.key?(definition_id)
        @definitions[definition_id] = definition
        @children[definition_id] = []
        @owners << definition_id
      end

      def container?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end
    end
  end
end
