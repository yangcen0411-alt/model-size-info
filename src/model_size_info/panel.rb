# encoding: UTF-8
module ModelFootprintTools
  module SizeInfo
    class SelectionListener < Sketchup::SelectionObserver
      def initialize(panel)
        @panel = panel
      end

      def onSelectionBulkChange(_selection)
        @panel.selection_changed
      end

      def onSelectionCleared(_selection)
        @panel.selection_changed
      end

      def onSelectionAdded(_selection, _entity)
        @panel.selection_changed
      end

      def onSelectionRemoved(_selection, _entity)
        @panel.selection_changed
      end
      alias_method :onSelectedRemoved, :onSelectionRemoved
    end

    class ModelListener < Sketchup::ModelObserver
      def initialize(panel)
        @panel = panel
      end

      def onTransactionCommit(_model)
        @panel.model_changed
      end

      def onTransactionUndo(_model)
        @panel.model_changed
      end

      def onTransactionRedo(_model)
        @panel.model_changed
      end

      def onTransactionAbort(_model)
        @panel.model_changed
      end

      def onSaveModel(_model)
        @panel.model_changed
      end

      def onActivePathChanged(_model)
        @panel.selection_changed
      end
    end

    class MaterialsListener < Sketchup::MaterialsObserver
      def initialize(panel)
        @panel = panel
      end

      def onMaterialChange(_materials, _material)
        @panel.model_changed
      end

      def onMaterialAdd(_materials, _material)
        @panel.model_changed
      end

      def onMaterialRemove(_materials, _material)
        @panel.model_changed
      end

      def onMaterialUndoRedo(_materials, _material)
        @panel.model_changed
      end
    end

    class ApplicationListener < Sketchup::AppObserver
      def initialize(panel)
        @panel = panel
      end

      def onNewModel(model)
        @panel.bind_model(model)
      end

      def onOpenModel(model)
        @panel.bind_model(model)
      end

      def onActivateModel(model)
        @panel.bind_model(model)
      end
    end

    class Panel
      AUTO_LIMIT = 3
      EXPORT_BATCH_LIMIT = 20
      EXPORT_SLICE_SECONDS = 0.012

      def initialize
        @dialog = nil
        @ready = false
        @scope = 'follow'
        @auto = Sketchup.read_default('ModelFootprintTools.SizeInfo', 'auto', true) != false
        @generation = 0
        @busy = false
        @measuring = false
        @navigating = false
        @error = nil
        @tree_serial = 0
        reset_tree
        @selection_listener = SelectionListener.new(self)
        @model_listener = ModelListener.new(self)
        @materials_listener = MaterialsListener.new(self)
        @app_listener = ApplicationListener.new(self)
      end

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return
        end
        @dialog = UI::HtmlDialog.new(
          dialog_title: '模型占用信息',
          preferences_key: 'ModelFootprintTools.SizeInfo.Panel',
          scrollable: true,
          resizable: true,
          width: 440,
          height: 740,
          min_width: 320,
          min_height: 440,
          style: UI::HtmlDialog::STYLE_UTILITY
        )
        @ready = false
        @dialog.set_file(File.join(__dir__, 'ui', 'panel.html'))
        callbacks
        @dialog.set_on_closed { close }
        Sketchup.add_observer(@app_listener)
        bind_model(Sketchup.active_model)
        @dialog.show
      end

      def close
        cancel
        reset_tree
        detach_model
        Sketchup.remove_observer(@app_listener)
        @dialog = nil
        @ready = false
      end

      def bind_model(model)
        return if @model.equal?(model) && @analyzer
        cancel
        detach_model
        @model = model
        @analyzer = Analyzer.new(model)
        reset_tree
        @model.selection.add_observer(@selection_listener)
        @model.add_observer(@model_listener)
        @model.materials.add_observer(@materials_listener)
        schedule
      end

      def selection_changed
        return unless @dialog
        return if @navigating || @scope == 'tree'
        @error = nil
        schedule
      end

      def model_changed
        return if @measuring || @navigating || !@dialog
        @analyzer.invalidate if @analyzer
        reset_tree
        @error = nil
        schedule
      end

      def refresh(force = false)
        return unless active?
        if force
          @analyzer.invalidate
          reset_tree
        end
        @error = nil
        if @scope == 'tree'
          if @tree_index.nil?
            scan_tree(false)
          else
            render
          end
          return
        end
        render
        auto_measure
      rescue StandardError => error
        show_error(error)
      end

      def measure(force = false)
        return unless active?
        return measure_tree(force) if @scope == 'tree'
        cancel
        @error = nil
        data = @analyzer.snapshot(@scope)
        if data[:kind] == 'model'
          @busy = true
          render
          token = @generation
          @job_timer = UI.start_timer(0.1, false) do
            @job_timer = nil
            if token == @generation && active?
              begin
                @measuring = true
                @analyzer.measure_model
              rescue StandardError => error
                @error = error.message
              ensure
                @measuring = false
                @busy = false
              end
              render
            end
          end
          return
        end
        queue = @analyzer.definitions_for(@analyzer.entities)
        queue.reject! { |definition| @analyzer.cached(definition) } unless force
        return render if queue.empty?
        @busy = true
        render
        measure_next(queue, @generation, force)
      rescue StandardError => error
        @busy = false
        show_error(error)
      end

      private

      def active?
        @dialog && @ready && @analyzer && @model && @model.valid? && Sketchup.active_model.equal?(@model)
      end

      def callbacks
        @dialog.add_action_callback('ready') do |_context|
          @ready = true
          @tree_index.resend if @tree_index
          @tree_sizes_sent = {}
          refresh
        end
        @dialog.add_action_callback('scope') do |_context, scope|
          next unless %w[follow model tree].include?(scope)
          next if @scope == scope
          @scope = scope
          if scope == 'tree'
            cancel
            refresh
          else
            schedule
          end
        end
        @dialog.add_action_callback('auto') do |_context, value|
          @auto = value == true
          Sketchup.write_default('ModelFootprintTools.SizeInfo', 'auto', @auto)
          schedule
        end
        @dialog.add_action_callback('measure') { |_context| measure(true) }
        @dialog.add_action_callback('refresh') { |_context| cancel; refresh(true) }
        @dialog.add_action_callback('cancel') do |_context|
          cancel
          render
        end
        @dialog.add_action_callback('locate') do |_context, request|
          locate_tree_item(request)
        end
        @dialog.add_action_callback('expand') do |_context, request|
          expand_tree_item(request)
        end
        @dialog.add_action_callback('load_all') do |_context|
          next unless active? && @scope == 'tree'
          @tree_index ||= ComponentTree.new(@model)
          @tree_index.request_all
          scan_tree(false) unless @busy
        end
      end

      def detach_model
        return unless @model
        begin
          @model.selection.remove_observer(@selection_listener)
          @model.remove_observer(@model_listener)
          @model.materials.remove_observer(@materials_listener)
        rescue StandardError
          # A closed SketchUp model may already have disposed its collections.
        end
        @model = nil
        @analyzer = nil
      end

      def cancel
        @generation += 1
        UI.stop_timer(@refresh_timer) if @refresh_timer
        UI.stop_timer(@job_timer) if @job_timer
        @refresh_timer = @job_timer = nil
        @busy = false
        @job_kind = nil
      end

      def schedule
        cancel
        return unless @dialog && @ready
        render
        token = @generation
        @refresh_timer = UI.start_timer(0.6, false) do
          @refresh_timer = nil
          refresh if token == @generation
        end
      end

      def auto_measure
        return unless @auto && !@busy && @scope == 'follow'
        data = @analyzer.snapshot(@scope)
        return unless data[:kind] == 'selection' && data[:pending_count] > 0
        return if data[:definition_count] > AUTO_LIMIT
        measure
      end

      def measure_next(queue, token, force)
        @job_timer = UI.start_timer(0.001, false) do
          @job_timer = nil
          next unless token == @generation && active?
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EXPORT_SLICE_SECONDS
          EXPORT_BATCH_LIMIT.times do
            break unless token == @generation && active?
            begin
              definition = queue.shift
              if definition && definition.valid?
                @measuring = true
                @analyzer.measure_definition(definition, force)
              end
            rescue StandardError => error
              if @scope == 'tree' && definition
                @tree_errors[definition.persistent_id.to_s] = error.message
                @error = "#{@tree_errors.length} 个定义测量失败；成功结果已保留，可点击下方按钮重试未完成项。"
              else
                @error = error.message
                queue.clear
              end
            ensure
              @measuring = false
            end
            break if queue.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          end
          next render unless token == @generation && active?
          if queue.empty?
            @busy = false
            @job_kind = nil
            render
            scan_tree(false) if @scope == 'tree' && @tree_index && !@tree_index.complete?
          else
            progress_render
            measure_next(queue, token, force)
          end
        end
      end

      def render
        return unless active?
        data = @scope == 'tree' ? tree_snapshot : @analyzer.snapshot(@scope)
        data[:auto] = @auto
        data[:scope] = @scope
        data[:busy] = @busy
        data[:job_kind] = @job_kind
        data[:error] = @error
        data[:auto_limit] = AUTO_LIMIT
        data[:version] = VERSION
        # JSON is embedded as data, never HTML. Escape JS line separators for
        # the embedded Chromium versions used by older SketchUp releases.
        payload = JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
        @dialog.execute_script("window.ModelSizeInfo.render(#{payload});")
        if data[:kind] == 'tree'
          @tree_index.acknowledge_delta if @tree_index && data[:tree_structure]
          @tree_sizes_sent.merge!(data[:tree_sizes])
        end
      rescue StandardError => error
        warn("[模型占用信息] #{error.class}: #{error.message}")
      end

      def show_error(error)
        @error = error.message
        render
      end

      def reset_tree
        @tree_index = nil
        @tree_errors = {}
        @tree_sizes_sent = {}
        @tree_scan_rendered_at = nil
        @tree_serial += 1
      end

      def tree_snapshot
        index = @tree_index
        definitions = index ? index.definitions_by_id : {}
        sizes = {}
        measured = 0
        definitions.each_key do |id|
          cached = @analyzer.cached_by_id(id)
          value = { bytes: cached && cached[:bytes], error: @tree_errors[id] }
          measured += 1 if cached
          sizes[id] = value if @tree_sizes_sent[id] != value
        end
        data = @analyzer.snapshot('model')
        data.merge!(
          kind: 'tree', bytes: nil, subtitle: '模型组件树',
          tree_token: @tree_serial.to_s,
          tree_complete: index ? index.complete? : false,
          tree_all_loaded: index ? index.all_loaded? : false,
          tree_read_seconds: index && index.last_read_seconds,
          tree_root_count: index ? index.root_count : 0,
          tree_scanned: index ? index.scanned_instances : 0,
          tree_scanned_definitions: index ? index.scanned_definitions : 0,
          tree_measured: measured,
          tree_errors: @tree_errors.length,
          tree_sizes: sizes,
          definition_count: definitions.length,
          pending_count: definitions.length - measured,
          tree_structure: index && index.delta,
          note: '目录按需读取，展开时加载子级；可点击“读取全部层级”查看全模型。每项为独立 SKP 大小，父级已包含子级，不能逐行相加。'
        )
        data
      end

      def scan_tree(measure_after)
        cancel
        @error = nil
        @tree_index ||= ComponentTree.new(@model)
        if @tree_index.complete?
          return measure_tree if measure_after
          return render
        end
        @busy = true
        @job_kind = 'scan'
        @tree_scan_rendered_at = nil
        render
        scan_tree_next(measure_after, @generation)
      end

      def scan_tree_next(measure_after, token)
        @job_timer = UI.start_timer(0.001, false) do
          @job_timer = nil
          next unless token == @generation && active? && @scope == 'tree'
          begin
            complete = @tree_index.step
            next unless token == @generation && active? && @scope == 'tree'
            if complete
              @busy = false
              @job_kind = nil
              render
              measure_tree if measure_after
            else
              progress_render
              scan_tree_next(measure_after, token)
            end
          rescue StandardError => error
            @busy = false
            @job_kind = nil
            reset_tree
            show_error(error)
          end
        end
      end

      def measure_tree(force = false)
        return scan_tree(true) unless @tree_index && @tree_index.complete?
        cancel
        @error = nil
        queue = @tree_index.definitions.select(&:valid?)
        # Resume partial scans without repeating every already-exported file.
        force = force && queue.all? { |definition| @analyzer.cached(definition) }
        @analyzer.invalidate if force
        queue.reject! { |definition| @analyzer.cached(definition) }
        @tree_errors = {}
        return render if queue.empty?
        @busy = true
        @job_kind = 'tree'
        render
        measure_next(queue, @generation, false)
      end

      def locate_tree_item(request)
        return unless active?
        unless request.is_a?(Hash) && request['token'] == @tree_serial.to_s && @tree_index
          raise '组件树已更新，请在最新列表中重新选择对象。'
        end
        path = @tree_index.resolve(request['path'])
        @navigating = true
        parent_path = path[0...-1]
        unless @model.active_path.to_a == parent_path
          @model.active_path = parent_path.empty? ? nil : parent_path
        end
        @model.selection.clear
        @model.selection.add(path.last)
        @model.active_view.zoom(@model.selection)
        @error = nil
      rescue StandardError => error
        @error = "无法定位：#{error.message}"
      ensure
        @navigating = false
        render
      end

      def progress_render
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if !@tree_scan_rendered_at || now - @tree_scan_rendered_at >= 0.12
          render
          @tree_scan_rendered_at = now
        end
      end

      def expand_tree_item(request)
        return unless active? && @scope == 'tree'
        unless request.is_a?(Hash) && request['token'] == @tree_serial.to_s && @tree_index
          raise '组件树已更新，请重新展开对象。'
        end
        entity = @tree_index.resolve(request['path']).last
        @tree_index.request(entity.definition.persistent_id.to_s)
        @busy ? render : scan_tree(false)
      rescue StandardError => error
        show_error(error)
      end
    end
  end
end
