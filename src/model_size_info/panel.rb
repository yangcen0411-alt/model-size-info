# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    class ModelListener < Sketchup::ModelObserver
      def initialize(panel); @panel = panel; end
      def onSaveModel(_model); @panel.saved; end
      def onTransactionCommit(_model); @panel.model_changed; end
      alias_method :onTransactionUndo, :onTransactionCommit
      alias_method :onTransactionRedo, :onTransactionCommit
      alias_method :onTransactionAbort, :onTransactionCommit
    end

    class ApplicationListener < Sketchup::AppObserver
      def initialize(panel); @panel = panel; end
      def onNewModel(model); @panel.bind_model(model); end
      alias_method :onOpenModel, :onNewModel
      alias_method :onActivateModel, :onNewModel
    end

    class Panel
      POLL_INTERVAL = 0.1

      def initialize
        @ready = false
        @generation = @serial = 0
        @queue, @paused = [], []
        @model_listener = ModelListener.new(self)
        @app_listener = ApplicationListener.new(self)
        clear_graph
      end

      def show
        return @dialog.bring_to_front if @dialog && @dialog.visible?
        @dialog = UI::HtmlDialog.new(dialog_title: '模型占用信息',
          preferences_key: 'ModelFootprintTools.SizeInfo.Panel', scrollable: true,
          resizable: true, width: 380, height: 560, min_width: 320, min_height: 360,
          style: UI::HtmlDialog::STYLE_UTILITY)
        @ready = false
        @dialog.set_file(File.join(__dir__, 'ui', 'panel.html'))
        callbacks
        @dialog.set_on_closed { close }
        Sketchup.add_observer(@app_listener)
        bind_model(Sketchup.active_model)
        @dialog.show
      end

      def close
        cancel(false)
        detach_model
        Sketchup.remove_observer(@app_listener)
        @dialog = nil
        @ready = false
      end

      def bind_model(model)
        return if @model.equal?(model)
        cancel(false)
        detach_model
        @model = model
        @model.add_observer(@model_listener) if @model
        clear_graph
        load_roots if active?
      end

      def model_changed
        # Unsaved edits never trigger parsing or exporting in the live model.
        render
      end

      def saved
        cancel(false)
        clear_graph
        render
        token = @generation
        @refresh_timer = UI.start_timer(0.3, false) do
          @refresh_timer = nil
          load_roots if token == @generation && active?
        end
      end

      private

      def active?
        @dialog && @ready && @model && @model.valid? && Sketchup.active_model.equal?(@model)
      end

      def busy?
        @loading || @running || !@queue.empty?
      end

      def source_path
        @model ? @model.path.to_s : ''
      end

      def clear_graph
        @tree = ComponentTree.new
        @sizes, @errors, @sizes_sent = {}, {}, {}
        @source_bytes = nil
        @error = nil
        @serial += 1
      end

      def detach_model
        @model.remove_observer(@model_listener) if @model
      rescue StandardError
      ensure
        @model = nil
      end

      def callbacks
        @dialog.add_action_callback('ready') do |_context|
          @ready = true
          @tree.resend
          @sizes_sent.clear
          @tree.root_loaded? ? render : load_roots
        end
        @dialog.add_action_callback('refresh') do |_context|
          next unless active?
          cancel(false)
          clear_graph
          load_roots
        end
        @dialog.add_action_callback('cancel') do |_context|
          cancel(true)
          render
        end
        @dialog.add_action_callback('resume_scan') do |_context|
          next unless active? && !busy?
          tasks = @paused
          @paused = []
          tasks.each { |task| enqueue(task) }
          pump
        end
        @dialog.add_action_callback('expand') { |_context, request| expand(request) }
        @dialog.add_action_callback('more') { |_context, request| more(request) }
        @dialog.add_action_callback('measure_item') { |_context, request| measure_item(request) }
        @dialog.add_action_callback('locate') { |_context, request| locate(request) }
      end

      def load_roots
        return render if source_path.empty?
        enqueue(operation: 'list', definition_id: '', offset: @tree.offset(''))
        pump
      end

      def enqueue(task)
        return if @running == task || @queue.include?(task)
        @paused.delete(task)
        @queue << task
      end

      def new_session
        BackgroundSession.new(source_path).start
      end

      def pump
        return unless active?
        return render if @queue.empty? && !@running
        @session ||= new_session
        @loading = !@session.ready?
        if !@loading && !@running
          @running = @queue.shift
          @session.request(@running.fetch(:operation), @running.fetch(:definition_id),
            @running[:offset] || 0, @running[:force] == true)
        end
        render
        schedule_poll
      rescue StandardError => error
        fail_task(error)
      end

      def schedule_poll
        return if @poll_timer
        token = @generation
        @poll_timer = UI.start_timer(POLL_INTERVAL, false) do
          @poll_timer = nil
          next unless token == @generation && active?
          begin
            data = @session.poll
            if data
              if data['ready']
                @loading = false
                @source_bytes = data.fetch('source_bytes')
              else
                task = @running
                unless task && data['operation'] == task[:operation] && data['definition_id'] == task[:definition_id]
                  raise '后台结果与当前任务不符，请刷新。'
                end
                if task[:operation] == 'list'
                  @tree.apply(data)
                else
                  bytes = data.fetch('bytes')
                  raise '后台文件大小无效。' unless bytes.is_a?(Integer) && bytes >= 0
                  @sizes[task[:definition_id]] = bytes
                  @errors.delete(task[:definition_id])
                end
                @running = nil
              end
              if @queue.empty? && !@running
                render
              else
                pump
              end
            else
              schedule_poll
            end
          rescue StandardError => error
            fail_task(error)
          end
        end
      end

      def fail_task(error)
        task = @running
        if task && task[:operation] == 'measure'
          @errors[task[:definition_id]] = error.message
        end
        @error = error.message
        if @session && @session.ready? && !@session.pending?
          @running = nil
          @loading = false
          @queue.empty? ? render : pump
        else
          cancel(true)
          render
        end
      end

      def cancel(preserve_reads)
        @generation += 1
        UI.stop_timer(@poll_timer) if @poll_timer
        UI.stop_timer(@refresh_timer) if @refresh_timer
        @poll_timer = @refresh_timer = nil
        tasks = [@running, *@queue].compact
        @paused = preserve_reads ? (@paused + tasks.select { |task| task[:operation] == 'list' }).uniq : []
        @queue = []
        @running = nil
        @loading = false
        @session.close if @session
        @session = nil
      end

      def validate(request)
        raise '组件树已更新，请在最新列表中操作。' unless request.is_a?(Hash) && request['token'] == @serial.to_s
      end

      def expand(request)
        return unless active?
        validate(request)
        id = @tree.resolve(request['path']).last.fetch('definition_id')
        return render if @tree.loaded?(id)
        @error = nil
        enqueue(operation: 'list', definition_id: id, offset: @tree.offset(id))
        pump
      rescue StandardError => error
        @error = error.message
        render
      end

      def more(request)
        return unless active?
        validate(request)
        id = request['path'] == '' ? '' : @tree.resolve(request['path']).last.fetch('definition_id')
        return render unless @tree.more?(id)
        @error = nil
        enqueue(operation: 'list', definition_id: id, offset: @tree.offset(id))
        pump
      rescue StandardError => error
        @error = error.message
        render
      end

      def measure_item(request)
        return unless active? && !busy?
        validate(request)
        id = @tree.resolve(request['path']).last.fetch('definition_id')
        force = request['force'] == true
        return render if @sizes.key?(id) && !force
        @sizes.delete(id) if force
        @errors.delete(id)
        @error = nil
        enqueue(operation: 'measure', definition_id: id, force: force)
        pump
      rescue StandardError => error
        @error = error.message
        render
      end

      def locate(request)
        return unless active?
        validate(request)
        nodes = @tree.resolve(request['path'])
        expected_parent = @model
        path = nodes.map do |node|
          entity = @model.find_entity_by_persistent_id(node.fetch('id').to_i)
          unless entity && entity.valid? && entity.parent == expected_parent &&
              (entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)) &&
              entity.definition.persistent_id.to_s == node.fetch('definition_id')
            raise '当前对象与已保存文件不同，请先保存并刷新。'
          end
          expected_parent = entity.definition
          entity
        end
        parents = path[0...-1]
        @model.active_path = parents.empty? ? nil : parents unless @model.active_path.to_a == parents
        @model.selection.clear
        @model.selection.add(path.last)
        @error = nil
      rescue StandardError => error
        @error = '无法选择对象：' + error.message
      ensure
        render
      end

      def snapshot
        saved = !source_path.empty?
        task = @running || @queue.first
        measuring_id = task && task[:operation] == 'measure' ? task[:definition_id] : nil
        changes = {}
        @tree.definitions.each_key do |id|
          value = { bytes: @sizes[id], error: @errors[id] }
          changes[id] = value if @sizes_sent[id] != value
        end
        complete = !busy? && @paused.empty? && (@tree.root_loaded? || !saved || @error)
        {
          kind: 'tree', scope: 'tree', version: VERSION, busy: !!busy?,
          job_kind: @loading ? 'loading' : (task && task[:operation] == 'measure' ? 'tree' : 'scan'),
          error: @error, title: saved ? File.basename(source_path) : '尚未保存的模型',
          file: { name: saved ? File.basename(source_path) : '尚未保存的模型',
            bytes: @source_bytes, saved: saved, modified: @model.modified? },
          tree_token: @serial.to_s, tree_complete: !!complete,
          tree_paused: !@paused.empty?,
          tree_root_count: @tree.root_total || 0, definition_count: @tree.definitions.length,
          tree_measured: @sizes.length, tree_errors: @errors.length,
          tree_measuring_id: measuring_id, tree_structure: @tree.delta, tree_sizes: changes,
          empty_message: saved ? (@error ? '后台读取未完成，请刷新重试。' : (@tree.root_loaded? ? '已保存文件中没有群组或组件。' : (@paused.empty? ? '后台正在读取已保存的文件…' : '读取已暂停，点击“继续读取”恢复。'))) : '请先保存模型，再点击刷新。',
          note: '读取和计算以上次保存的文件为准。父级大小包含子级，相同定义共享结果。保存模型后自动更新。'
        }
      end

      def render
        return unless active?
        data = snapshot
        payload = JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
        @dialog.execute_script("window.ModelSizeInfo.render(#{payload});")
        @tree.acknowledge_delta
        @sizes_sent.merge!(data[:tree_sizes])
      rescue StandardError => error
        warn("[模型占用信息] #{error.class}: #{error.message}")
      end
    end
  end
end
