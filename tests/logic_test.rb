# encoding: UTF-8
# Run with Ruby 2.7+; no SketchUp application is launched or modified.
require 'json'
require 'tmpdir'

module Sketchup
  class Drawingelement
    attr_accessor :name, :definition, :hidden, :locked, :erased, :parent
    attr_reader :persistent_id
    def initialize(definition = nil, name = '')
      @definition, @name = definition, name
      @persistent_id = (@@next_id = (defined?(@@next_id) ? @@next_id : 100_000) + 1)
    end
    def valid?; !@erased; end
    def hidden?; !!@hidden; end
    def locked?; !!@locked; end
  end
  class Group < Drawingelement; end
  class ComponentInstance < Drawingelement; end
  class Face < Drawingelement; end
  class SelectionObserver; end
  class ModelObserver; end
  class MaterialsObserver; end
  class AppObserver; end
  class << self
    attr_accessor :active_model
    def read_default(*); true; end
    def write_default(*); true; end
    def add_observer(observer); (@observers ||= []) << observer; end
    def remove_observer(observer); (@observers ||= []).delete(observer); end
    def observer_count; (@observers ||= []).length; end
  end
end

module UI
  @timers = {}
  @next_id = 0
  class << self
    attr_accessor :timer_intervals
    def start_timer(_seconds, _repeat = false, &block)
      (@timer_intervals ||= []) << _seconds
      @next_id += 1
      @timers[@next_id] = block
      @next_id
    end
    def stop_timer(id); @timers.delete(id); end
    def tick
      key = @timers.keys.min
      @timers.delete(key).call if key
    end
    def timer_count; @timers.length; end
    def drain
      1000.times { tick if @timers.length > 0 }
      raise 'Timer loop detected' if @timers.length > 0
    end
  end
  class HtmlDialog
    STYLE_UTILITY = 2
    attr_reader :callbacks, :last_data, :path, :history
    def initialize(_options)
      @callbacks = {}
      @history = []
    end
    def set_file(path); @path = path; end
    def add_action_callback(name, &block); @callbacks[name] = block; end
    def set_on_closed(&block); @on_closed = block; end
    def show; @visible = true; end
    def visible?; @visible; end
    def bring_to_front; end
    def close; @visible = false; @on_closed.call; end
    def event(name, *args); @callbacks.fetch(name).call(nil, *args); end
    def execute_script(script)
      payload = script.sub('window.ModelSizeInfo.render(', '').sub(/\);\z/, '')
      @last_data = JSON.parse(payload)
      @history << @last_data
    end
  end
end

class ObservableList < Array
  def add(entity); self << entity; end
  def observers; @observers ||= []; end
  def add_observer(observer); observers << observer; end
  def remove_observer(observer); observers.delete(observer); end
end

class TestEntities < ObservableList
  attr_reader :iteration_count, :grep_calls
  attr_accessor :forbid_iteration
  def initialize(owner)
    super()
    @owner, @iteration_count = owner, 0
    @grep_calls = []
  end
  def <<(entity)
    entity.parent = @owner
    if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      entity.definition.instances << entity unless entity.definition.instances.include?(entity)
    end
    super
  end
  def concat(entities)
    entities.each { |entity| self << entity }
    self
  end
  def each(&block)
    raise 'Geometry collection must not be enumerated' if @forbid_iteration
    @iteration_count += 1
    super(&block)
  end
  def to_a
    raise 'Geometry collection must not be copied' if @forbid_iteration
    super
  end
  def grep(type)
    @grep_calls << type
    super
  end
end

class TestDefinition
  attr_accessor :name, :payload_bytes, :fail_save, :copies, :image, :erased
  attr_reader :persistent_id, :entities, :exports, :last_path, :instances
  def initialize(id, name, bytes)
    @persistent_id, @name, @payload_bytes = id, name, bytes
    @instances = []
    @entities = TestEntities.new(self)
    @entities.concat([Sketchup::Face.new, Sketchup::Face.new])
    @exports, @copies = 0, 1
  end
  def count_used_instances; @copies; end
  def valid?; !@erased; end
  def image?; !!@image; end
  def save_copy(path)
    @exports += 1
    @last_path = path
    File.binwrite(path, 'x' * @payload_bytes)
    return false if @fail_save
    true
  end
end
Sketchup.const_set(:ComponentDefinition, TestDefinition)

class TestModel
  attr_accessor :path, :title, :modified, :on_navigate
  attr_reader :selection, :definitions, :entities, :materials, :last_path, :active_path, :active_view
  def initialize
    @path, @title, @modified = '', '', true
    @selection, @definitions, @materials = 3.times.map { ObservableList.new }
    @entities = TestEntities.new(self)
    @observers = []
    @active_view = TestView.new
  end
  def active_path=(path)
    raise 'Cannot open a locked instance' if path.to_a.any?(&:locked?)
    @active_path = path
    @on_navigate.call if @on_navigate
  end
  def valid?; true; end
  def modified?; @modified; end
  def add_observer(observer); @observers << observer; end
  def remove_observer(observer); @observers.delete(observer); end
  def observer_count; @observers.length; end
  def save_copy(path)
    @last_path = path
    File.binwrite(path, 'm' * 2345)
    true
  end
end

class TestView
  attr_reader :zoomed
  def zoom(selection); @zoomed = selection.to_a; end
end

module ModelFootprintTools
  module SizeInfo
    VERSION = '1.2.0'
  end
end
require_relative '../src/model_size_info/analyzer'
require_relative '../src/model_size_info/component_tree'
require_relative '../src/model_size_info/panel'

passed = []
check = lambda do |name, &block|
  raise "FAIL: #{name}" unless block.call
  passed << name
  puts "PASS: #{name}"
end

model = TestModel.new
analyzer = ModelFootprintTools::SizeInfo::Analyzer.new(model)
check.call('unsaved model has no invented file size') { analyzer.snapshot[:bytes].nil? && analyzer.snapshot[:measurement_state] == 'unsaved' }
small = TestDefinition.new(10, '小组件', 1024)
large = TestDefinition.new(11, '<大组件 & 中文>', 65536)
a = Sketchup::ComponentInstance.new(small, '实例名称')
b = Sketchup::ComponentInstance.new(small)
group = Sketchup::Group.new(large)
small.copies = 8
model.definitions.concat([small, large])
model.selection << a
data = analyzer.snapshot
check.call('instance name and type are exposed') { data[:title] == '实例名称' && data[:subtitle] == '组件' }
check.call('a new selection is pending until serialized') { data[:measurement_state] == 'pending' && data[:bytes].nil? }
check.call('native instance count is not treated as file size') { data[:instance_count] == 8 && data[:direct_entities] == 2 }
result = analyzer.measure_definition(small)
check.call('size comes from actual temporary file bytes') { result[:bytes] == 1024 && analyzer.snapshot[:bytes] == 1024 }
check.call('temporary component files are removed') { !File.exist?(small.last_path) && !Dir.exist?(File.dirname(small.last_path)) }
analyzer.measure_definition(small)
check.call('unchanged definitions are served from cache') { small.exports == 1 }
analyzer.measure_definition(small, true)
check.call('forced measurement bypasses cache') { small.exports == 2 }
model.selection << b
data = analyzer.snapshot
check.call('identical definitions are counted once') { data[:bytes] == 1024 && data[:definition_count] == 1 && data[:rows][0][:selected_instances] == 2 }
check.call('the measurement queue is also deduplicated') { analyzer.definitions_for(model.selection).length == 1 }
model.selection << group
analyzer.measure_definition(large)
data = analyzer.snapshot
check.call('multi-selection sums independent files once per definition') { data[:bytes] == 66560 && data[:definition_count] == 2 }
check.call('results are sorted largest first') { data[:rows].map { |row| row[:bytes] } == [65536, 1024] }
check.call('Chinese and HTML-like names remain data') { data[:rows][0][:name] == '<大组件 & 中文>' }
model.selection << Sketchup::Face.new
data = analyzer.snapshot
check.call('mixed unsupported entities never produce a misleading total') { data[:bytes].nil? && data[:measurement_state] == 'partial' && data[:loose_count] == 1 }
model.selection.replace([Sketchup::Face.new])
check.call('raw geometry requires a group instead of an estimated size') { analyzer.snapshot[:measurement_state] == 'unsupported' && analyzer.snapshot[:rows].empty? }
model.selection.replace([a])
analyzer.invalidate
check.call('editing invalidates all size caches') { analyzer.revision == 1 && analyzer.snapshot[:pending_count] == 1 }
small.fail_save = true
begin
  analyzer.measure_definition(small)
  raise 'failed saves must raise'
rescue RuntimeError => error
  check.call('save failure is reported and not cached') { error.message.include?('SKP') && analyzer.cached(small).nil? }
  check.call('failed saves also clean up temporary files') { !File.exist?(small.last_path) }
ensure
  small.fail_save = false
end
Dir.mktmpdir('model-size-test-') do |directory|
  original = File.join(directory, 'source.skp')
  File.binwrite(original, 'saved-content')
  model.path = original
  model.title = '测试模型'
  model.selection.clear
  check.call('the saved model shows actual disk bytes') { analyzer.snapshot[:bytes] == 13 && analyzer.snapshot[:file][:modified] }
  analyzer.measure_model
  data = analyzer.snapshot
  check.call('current model copy includes a new byte measurement') { data[:bytes] == 2345 && data[:file][:bytes] == 13 }
  check.call('measuring a model preserves its source path and contents') { model.path == original && File.binread(original) == 'saved-content' }
  check.call('temporary model files are removed') { !File.exist?(model.last_path) }
  analyzer.invalidate
  check.call('a later edit invalidates the model copy measurement') { analyzer.snapshot[:bytes] == 13 }
end
model.path = ''

Sketchup.active_model = model
model.selection.replace([a])
panel = ModelFootprintTools::SizeInfo::Panel.new
panel.show
dialog = panel.instance_variable_get(:@dialog)
check.call('panel HTML is packaged at its expected relative path') { File.file?(dialog.path) }
dialog.event('ready')
check.call('ready callback starts automatic measurement') { dialog.last_data['busy'] == true && UI.timer_count == 1 }
UI.drain
check.call('automatic measurement finishes with real byte data') { dialog.last_data['bytes'] == 1024 && dialog.last_data['busy'] == false }
check.call('panel content passes through JSON data, not HTML injection') { dialog.last_data['title'] == '实例名称' }
before = small.exports
panel.selection_changed
UI.drain
check.call('reselecting unchanged objects reuses cached exports') { small.exports == before }
panel.model_changed
UI.drain
check.call('model edits trigger a fresh automatic export') { small.exports == before + 1 }
dialog.event('auto', false)
UI.drain
panel.model_changed
UI.drain
check.call('disabling auto leaves a new measurement pending') { dialog.last_data['busy'] == false && dialog.last_data['bytes'].nil? }
dialog.event('measure')
dialog.event('cancel')
UI.drain
check.call('cancel removes queued exports and resets busy state') { dialog.last_data['busy'] == false && dialog.last_data['bytes'].nil? }
dialog.event('measure')
UI.drain
check.call('manual measurement works with auto disabled') { dialog.last_data['bytes'] == 1024 }
dialog.event('scope', 'model')
UI.drain
check.call('whole-model mode ignores a still-active selection') { dialog.last_data['kind'] == 'model' && dialog.last_data['bytes'].nil? }
dialog.event('measure')
UI.drain
check.call('whole-model button measures a temporary current copy') { dialog.last_data['bytes'] == 2345 && dialog.last_data['busy'] == false }
dialog.event('scope', 'follow')
UI.drain
small.fail_save = true
dialog.event('measure')
UI.drain
check.call('measurement errors are visible and never leave the panel busy') { !dialog.last_data['error'].nil? && dialog.last_data['busy'] == false }
small.fail_save = false
new_model = TestModel.new
Sketchup.active_model = new_model
panel.bind_model(new_model)
UI.drain
check.call('changing documents detaches old observers') { model.observer_count == 0 && model.selection.observers.empty? && model.materials.observers.empty? }
check.call('a new document gets fresh stats and cache') { dialog.last_data['kind'] == 'model' && dialog.last_data['bytes'].nil? }
dialog.close
check.call('closing detaches all app and model observers') { new_model.observer_count == 0 && new_model.selection.observers.empty? && new_model.materials.observers.empty? && Sketchup.observer_count == 0 }
check.call('closing clears all pending timers') { UI.timer_count == 0 }
panel.show
again = panel.instance_variable_get(:@dialog)
again.event('ready')
check.call('reopening creates fresh JavaScript callbacks') { !again.equal?(dialog) && again.callbacks.key?('measure') && again.last_data['kind'] == 'model' }
again.event('auto', true)
UI.drain
four = 4.times.map { |index| Sketchup::Group.new(TestDefinition.new(50 + index, "定义 #{index}", 500 + index)) }
new_model.selection.replace(four)
panel.selection_changed
UI.drain
check.call('large selections wait for explicit measurement') { again.last_data['pending_count'] == 4 && again.last_data['busy'] == false && four.all? { |entity| entity.definition.exports == 0 } }
again.event('measure')
new_model.selection.replace([four.last])
panel.selection_changed
UI.drain
check.call('changing selection cancels obsolete queued measurements') { four[0].definition.exports == 0 && four.last.definition.exports == 1 && again.last_data['definition_count'] == 1 }
again.close

puts "#{passed.length} checks passed."
