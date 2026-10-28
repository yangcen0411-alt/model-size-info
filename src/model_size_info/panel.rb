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

      def initialize
        @dialog = nil
        @ready = false
        @scope = 'follow'
        @auto = Sketchup.read_default('ModelFootprintTools.SizeInfo', 'auto', true) != false
        @generation = 0
        @busy = false
        @measuring = false
        @error = nil
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
          width: 380,
          height: 700,
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
        @model.selection.add_observer(@selection_listener)
        @model.add_observer(@model_listener)
        @model.materials.add_observer(@materials_listener)
        schedule
      end

      def selection_changed
        return unless @dialog
        @error = nil
        schedule
      end

      def model_changed
        return if @measuring || !@dialog
        @analyzer.invalidate if @analyzer
        @error = nil
        schedule
      end

      def refresh(force = false)
        return unless active?
        @analyzer.invalidate if force
        @error = nil
        render
        auto_measure
      rescue StandardError => error
        show_error(error)
      end

      def measure(force = false)
        return unless active?
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
          refresh
        end
        @dialog.add_action_callback('scope') do |_context, scope|
          next unless %w[follow model].include?(scope)
          @scope = scope
          schedule
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
        return unless @auto && !@busy && @scope != 'model'
        data = @analyzer.snapshot(@scope)
        return unless data[:kind] == 'selection' && data[:pending_count] > 0
        return if data[:definition_count] > AUTO_LIMIT
        measure
      end

      def measure_next(queue, token, force)
        @job_timer = UI.start_timer(0.08, false) do
          @job_timer = nil
          next unless token == @generation && active?
          begin
            definition = queue.shift
            if definition && definition.valid?
              @measuring = true
              @analyzer.measure_definition(definition, force)
            end
          rescue StandardError => error
            @error = error.message
            queue.clear
          ensure
            @measuring = false
          end
          if queue.empty?
            @busy = false
            render
          else
            render
            measure_next(queue, token, force)
          end
        end
      end

      def render
        return unless active?
        data = @analyzer.snapshot(@scope)
        data[:auto] = @auto
        data[:scope] = @scope
        data[:busy] = @busy
        data[:error] = @error
        data[:auto_limit] = AUTO_LIMIT
        data[:version] = VERSION
        # JSON is embedded as data, never HTML. Escape JS line separators for
        # the embedded Chromium versions used by older SketchUp releases.
        payload = JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
        @dialog.execute_script("window.ModelSizeInfo.render(#{payload});")
      rescue StandardError => error
        warn("[模型占用信息] #{error.class}: #{error.message}")
      end

      def show_error(error)
        @error = error.message
        render
      end
    end
  end
end
