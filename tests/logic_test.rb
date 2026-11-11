# encoding: UTF-8
require 'json'
require 'tmpdir'
require_relative '../src/model_size_info/analyzer'
require_relative '../src/model_size_info/component_tree'
module Sketchup
  class ModelObserver; end
  class AppObserver; end
  class Definition
    attr_reader :persistent_id
    def initialize(id); @persistent_id = id; end
  end
  class ComponentInstance
    attr_accessor :parent
    attr_reader :definition
    def initialize(id); @definition = Definition.new(id); end
    def valid?; true; end
  end
  class Group < ComponentInstance; end
  class << self
    attr_accessor :active_model
    def observers; @observers ||= []; end
    def add_observer(observer); observers << observer; end
    def remove_observer(observer); observers.delete(observer); end
  end
end
module UI
  @timers, @counter = {}, 0
  class << self
    attr_reader :timers
    def start_timer(interval, repeat, &block)
      raise 'Zero-delay loop' if interval < 0.05
      @counter += 1
      @timers[@counter] = [interval, block]
      @counter
    end
    def stop_timer(id); @timers.delete(id); end
    def step
      pair = @timers.first
      return false unless pair
      @timers.delete(pair[0]); pair[1][1].call
      true
    end
    def drain
      100.times { return unless step }
      raise 'Background poll loop did not finish'
    end
  end
  class HtmlDialog
    STYLE_UTILITY = 2
    attr_reader :last_data, :history, :callbacks
    def initialize(_options); @callbacks, @history = {}, []; end
    def set_file(path); raise 'Missing UI' unless File.file?(path); end
    def add_action_callback(name, &block); @callbacks[name] = block; end
    def set_on_closed(&block); @on_closed = block; end
    def show; @visible = true; end
    def visible?; @visible; end
    def bring_to_front; end
    def close; @visible = false; @on_closed.call; end
    def event(name, *args); @callbacks.fetch(name).call(nil, *args); end
    def execute_script(script)
      @last_data = JSON.parse(script.sub('window.ModelSizeInfo.render(', '').sub(/\);\z/, ''))
      @history << @last_data
    end
  end
end
class TestSelection < Array
  def add(entity); self << entity; end
end
class TestModel
  attr_accessor :path, :modified, :active_path
  attr_reader :observers, :selection, :by_id
  def initialize(path = 'C:/models/中文 & sample.skp')
    @path, @modified, @active_path = path, false, nil
    @observers, @selection, @by_id = [], TestSelection.new, {}
  end
  def valid?; true; end
  def modified?; @modified; end
  def add_observer(observer); @observers << observer; end
  def remove_observer(observer); @observers.delete(observer); end
  def find_entity_by_persistent_id(id); @by_id[id]; end
  %i[entities definitions save_copy active_view].each do |name|
    define_method(name) { |*| raise "Live model #{name} must never be used by the panel" }
  end
end
module ModelFootprintTools
  module SizeInfo
    VERSION = '1.5.0'
  end
end
require_relative '../src/model_size_info/panel'
def node(id, did, name = '中文 <组件>')
  { 'id' => id.to_s, 'definition_id' => did.to_s, 'name' => name, 'definition_name' => '共享定义', 'kind' => '组件' }
end
ROOT_NODES = [node(10, 500, '父组件'), node(11, 500, '父组件副本'), node(12, 501, '植物')]
CHILD_NODES = [node(20, 502, '子组件')]
class FakeSession
  attr_accessor :stall, :failure, :crash
  attr_reader :requests, :closed, :source_bytes
  def initialize
    @requests = []
    @source_bytes = 12345678
  end
  def start; self; end
  def ready?; !!@ready; end
  def pending?; !!@pending; end
  def request(operation, id = '', offset = 0, force = false)
    raise 'Duplicate request' if @pending
    @pending = { operation: operation, definition_id: id, offset: offset, force: force }
    @requests << @pending.dup
  end
  def poll
    return nil if @stall
    raise 'Worker exited' if @crash
    unless @ready
      @ready = true
      return { 'ok' => true, 'ready' => true, 'source_bytes' => @source_bytes }
    end
    task, @pending = @pending, nil
    return nil unless task
    if @failure
      value, @failure = @failure, nil
      raise value
    end
    value = { 'ok' => true, 'operation' => task[:operation], 'definition_id' => task[:definition_id] }
    if task[:operation] == 'list'
      nodes = task[:definition_id] == '' ? ROOT_NODES : (task[:definition_id] == '500' ? CHILD_NODES : [])
      value.merge!('offset' => task[:offset], 'nodes' => nodes, 'total' => nodes.length, 'next' => nodes.length)
    else
      value['bytes'] = task[:definition_id] == '500' ? 204800 : 4096
    end
    value
  end
  def close; @closed = true; end
end
class TestPanel < ModelFootprintTools::SizeInfo::Panel
  attr_reader :sessions
  def initialize; @sessions = []; super; end
  def new_session
    value = FakeSession.new.start
    @sessions << value
    value
  end
end
$checks = 0
def check(name)
  raise 'FAIL: ' + name unless yield
  $checks += 1
  puts 'PASS: ' + name
end
model = TestModel.new
Sketchup.active_model = model
panel = TestPanel.new
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
check('opening only starts an isolated session and returns before loading') { panel.sessions.length == 1 && dialog.last_data['busy'] && panel.sessions.last.requests.empty? }
UI.drain
check('roots come from background data without touching live geometry or saving') { dialog.last_data['tree_root_count'] == 3 && dialog.last_data['tree_structure']['roots'].length == 3 && !dialog.last_data['busy'] }
check('saved size is returned by the worker rather than a live model export') { dialog.last_data['file']['bytes'] == 12345678 }
session = panel.sessions.last
token = dialog.last_data['tree_token']
dialog.event('measure_item', { 'token' => token, 'path' => '10', 'force' => false })
check('row calculation is a background request') { session.requests.last[:operation] == 'measure' && dialog.last_data['tree_measuring_id'] == '500' }
UI.drain
check('parent calculation measures one definition and no descendants') { session.requests.count { |r| r[:operation] == 'measure' } == 1 && session.requests.none? { |r| r[:definition_id] == '502' } }
dialog.event('measure_item', { 'token' => token, 'path' => '11', 'force' => false })
check('repeated instances share the cached result') { session.requests.count { |r| r[:operation] == 'measure' } == 1 }
dialog.event('expand', { 'token' => token, 'path' => '10' })
UI.drain
check('expansion reads only the requested parent in the saved file') { session.requests.last[:operation] == 'list' && session.requests.last[:definition_id] == '500' }
before = session.requests.length
dialog.event('expand', { 'token' => token, 'path' => '11' })
check('another instance reuses the same child directory') { session.requests.length == before }
dialog.event('measure_item', { 'token' => token, 'path' => '10.20', 'force' => false })
UI.drain
check('a child can be calculated independently') { dialog.last_data['tree_measured'] == 2 && session.requests.last[:definition_id] == '502' }
session.stall = true
dialog.event('measure_item', { 'token' => token, 'path' => '10', 'force' => true })
UI.step
dialog.event('cancel')
check('Stop terminates an in-flight worker and clears polling timers') { session.closed && UI.timers.empty? && !dialog.last_data['busy'] }
check('cancel preserves other completed sizes') { dialog.last_data['tree_measured'] == 1 }
dialog.event('measure_item', { 'token' => token, 'path' => '10', 'force' => false })
UI.drain
check('calculation restarts a worker against the same saved IDs') { panel.sessions.length == 2 && dialog.last_data['tree_measured'] == 2 }
session = panel.sessions.last
session.failure = 'Cannot write temporary file'
dialog.event('measure_item', { 'token' => token, 'path' => '10', 'force' => true })
UI.drain
check('a failed recalculation clears only its own stale value') { dialog.last_data['tree_measured'] == 1 && dialog.last_data['tree_errors'] == 1 && !session.closed }
dialog.event('measure_item', { 'token' => token, 'path' => '10', 'force' => false })
UI.drain
check('retry updates the failed definition while keeping other results') { dialog.last_data['tree_measured'] == 2 && dialog.last_data['tree_errors'] == 0 }
model.modified = true
panel.model_changed
check('unsaved edits keep the saved snapshot and do not start a new scan') { dialog.last_data['file']['modified'] && panel.sessions.length == 2 && dialog.last_data['tree_token'] == token }
session.stall = true
dialog.event('expand', { 'token' => token, 'path' => '12' })
dialog.event('cancel')
check('canceling directory work exposes an explicit resume state') { !dialog.last_data['tree_complete'] && session.closed }
dialog.event('resume_scan')
UI.drain
check('resume restores the saved pending directory request') { dialog.last_data['tree_complete'] && panel.sessions.last.requests.last[:definition_id] == '501' }
panel.saved
check('saving cancels the old worker and invalidates snapshot results') { dialog.last_data['tree_measured'] == 0 && dialog.last_data['tree_token'] != token }
UI.drain
check('the saved file refresh is deferred until after the save callback') { dialog.last_data['tree_root_count'] == 3 }
dialog.event('measure_item', { 'token' => token, 'path' => '10' })
check('stale tree actions are rejected without starting exports') { dialog.last_data['error'].include?('组件树已更新') }
new_token = dialog.last_data['tree_token']
entity = Sketchup::Group.new(500); entity.parent = model; model.by_id[10] = entity
dialog.event('locate', { 'token' => new_token, 'path' => '10' })
check('selecting a current object validates its saved ID and parent') { model.selection == [entity] && !dialog.last_data['error'] }
entity.parent = Object.new
dialog.event('locate', { 'token' => new_token, 'path' => '10' })
check('moved or mismatched objects require a saved refresh') { dialog.last_data['error'].include?('当前对象') }
session = panel.sessions.last
session.crash = true
dialog.event('measure_item', { 'token' => new_token, 'path' => '10', 'force' => true })
UI.drain
check('a crashed worker returns an error and never falls back to live export') { !dialog.last_data['busy'] && dialog.last_data['error'].include?('Worker exited') && session.closed }
unsaved = TestModel.new('')
Sketchup.active_model = unsaved
panel.bind_model(unsaved)
check('an unsaved document waits for a normal save without opening a worker') { !dialog.last_data['file']['saved'] && dialog.last_data['empty_message'].include?('请先保存') && !dialog.last_data['busy'] }
check('switching documents detaches the previous observer') { model.observers.empty? && unsaved.observers.length == 1 }
dialog.close
check('closing clears observers and timers') { unsaved.observers.empty? && Sketchup.observers.empty? && UI.timers.empty? }
Sketchup.active_model = TestModel.new
startup = TestPanel.new
startup.show
startup_dialog = startup.instance_variable_get(:@dialog)
startup_dialog.event('ready')
startup_dialog.event('cancel')
check('canceling first load reports paused rather than active loading') { startup_dialog.last_data['tree_paused'] && startup_dialog.last_data['empty_message'].include?('读取已暂停') && !startup_dialog.last_data['busy'] }
startup_dialog.event('resume_scan')
UI.drain
check('a canceled first load can explicitly resume its root request') { startup_dialog.last_data['tree_root_count'] == 3 && !startup_dialog.last_data['tree_paused'] }
startup_dialog.close
puts "#{$checks} background panel checks passed."
