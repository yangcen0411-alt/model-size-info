# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    # This graph contains plain saved-file data, with no SketchUp geometry refs.
    class ComponentTree
      attr_reader :roots, :definitions, :root_total

      def initialize
        @roots, @definitions = [], {}
        @contexts = { '' => @roots }
        @node_ids = { '' => {} }
        @totals = {}
        @dirty = {}
        @roots_dirty = false
      end

      def apply(data)
        id = data.fetch('definition_id')
        destination = @contexts.fetch(id)
        raise '目录页码已过期，请刷新。' unless data.fetch('offset') == destination.length
        nodes = data.fetch('nodes')
        raise '目录数据过大。' unless nodes.is_a?(Array) && nodes.length <= 100
        total = data.fetch('total')
        expected = destination.length + nodes.length
        raise '目录条目数量无效。' unless total.is_a?(Integer) && total >= expected && data.fetch('next') == expected
        page_ids = {}
        nodes.each do |node|
          %w[id definition_id].each do |key|
            raise '后台对象编号无效。' unless node[key].is_a?(String) && node[key].bytesize <= 19 && node[key].match?(/\A[1-9]\d*\z/)
          end
          raise '目录包含重复对象，请刷新。' if page_ids[node['id']] || @node_ids.fetch(id)[node['id']]
          page_ids[node['id']] = true
        end
        nodes.each do |node|
          definition_id = node.fetch('definition_id')
          unless @definitions.key?(definition_id)
            @definitions[definition_id] = { 'name' => node['definition_name'].to_s,
              'children' => nil, 'loaded' => false, 'more' => false }
            @contexts[definition_id] = []
            @node_ids[definition_id] = {}
            @dirty[definition_id] = true
          end
          destination << node
          @node_ids.fetch(id)[node['id']] = true
        end
        @totals[id] = total
        if id.empty?
          @root_total = total
          @roots_dirty = true
        else
          @definitions.fetch(id).merge!('children' => destination, 'loaded' => true, 'more' => destination.length < total)
          @dirty[id] = true
        end
      end

      def root_loaded?
        @totals.key?('')
      end

      def loaded?(id)
        @totals.key?(id)
      end

      def more?(id)
        @totals.key?(id) && @contexts.fetch(id).length < @totals.fetch(id)
      end

      def offset(id)
        @contexts.fetch(id).length
      end

      def resolve(path)
        raise '对象路径无效，请刷新。' unless path.is_a?(String) && path.bytesize <= 8192 && path.match?(/\A\d+(?:\.\d+)*\z/)
        allowed, result, seen = @roots, [], {}
        path.split('.').each do |id|
          node = allowed.find { |entry| entry['id'] == id }
          raise '此对象不在已读取的层级中，请刷新。' unless node
          definition_id = node.fetch('definition_id')
          raise '此层级包含循环引用。' if seen[definition_id]
          seen[definition_id] = true
          result << node
          allowed = @contexts.fetch(definition_id)
        end
        result
      end

      def delta
        return nil if !@roots_dirty && @dirty.empty?
        { roots: @roots_dirty ? @roots : nil, root_more: more?(''),
          definitions: @dirty.keys.to_h { |id| [id, @definitions.fetch(id)] } }
      end

      def acknowledge_delta
        @roots_dirty = false
        @dirty.clear
      end

      def resend
        @roots_dirty = true
        @definitions.each_key { |id| @dirty[id] = true }
      end
    end
  end
end
