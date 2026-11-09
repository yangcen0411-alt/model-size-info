# encoding: UTF-8
require_relative 'logic_test'

passed = []
check = lambda do |name, &block|
  raise "FAIL: #{name}" unless block.call
  passed << name
  puts "PASS: #{name}"
end
tree_class = ModelFootprintTools::SizeInfo::ComponentTree
model = TestModel.new
parent = TestDefinition.new(502, '餐桌', 32768)
leaf = TestDefinition.new(501, '<桌腿 & 中文>', 4096)
unused = TestDefinition.new(503, 'unused', 16)
child = Sketchup::ComponentInstance.new(leaf, '桌腿 1')
child.hidden = true
parent.entities << child
first = Sketchup::Group.new(parent, '餐桌 A')
second = Sketchup::ComponentInstance.new(parent, '餐桌 B')
second.locked = true
model.entities.concat([first, Sketchup::Face.new, second])
model.definitions.concat([unused, leaf, parent])
index = tree_class.new(model)
check.call('reading a large level can yield after one item') { !index.step(1) && index.scanned_instances == 1 }
index.step until index.complete?
payload = index.payload
check.call('first open lists roots without entering their definitions') { index.definitions == [parent] && parent.entities.grep_calls.empty? && leaf.entities.grep_calls.empty? }
check.call('unread children are explicit rather than reported as empty') { payload[:definitions]['502'][:loaded] == false && payload[:definitions]['502'][:children].nil? && !index.all_loaded? }
check.call('only groups and components are returned in stable object-ID order') { payload[:roots].map { |node| node[:id] } == [first, second].map { |item| item.persistent_id.to_s } }
check.call('locked roots remain visible') { payload[:roots][1][:locked] }
index.acknowledge_delta
check.call('unchanged directory has no structural update to resend') { index.delta.nil? }
check.call('expansion requests exactly one definition') { index.request('502') && !index.complete? }
index.step until index.complete?
payload = index.payload
check.call('expansion returns a definition delta without resending all roots') { index.delta[:roots].nil? && index.delta[:definitions]['502'][:children].length == 1 }
check.call('nested names and visibility flags remain literal data') { payload[:definitions]['502'][:children][0][:hidden] && payload[:definitions]['501'][:name] == '<桌腿 & 中文>' }
check.call('the child itself is still unread until requested') { payload[:definitions]['501'][:children].nil? && leaf.entities.grep_calls.empty? }
before = parent.entities.grep_calls.length
check.call('shared parent definitions are not read again') { !index.request('502') && index.complete? && parent.entities.grep_calls.length == before }
path = "#{second.persistent_id}.#{child.persistent_id}"
check.call('nested location uses the chosen shared parent instance') { index.resolve(path) == [second, child] }
begin
  index.resolve("#{first.persistent_id}.#{second.persistent_id}")
  raise 'Expected wrong parent failure'
rescue RuntimeError => error
  check.call('paths cannot jump to unrelated siblings') { error.message.include?('层级') }
end
['', '../501', '1..2', nil, '1.' * 5000].each do |bad|
  begin
    index.resolve(bad)
    raise 'Expected invalid path failure'
  rescue RuntimeError => error
    check.call("invalid path rejected: #{bad.inspect[0, 16]}") { error.message.include?('路径无效') }
  end
end
child.erased = true
begin
  index.resolve(path)
  raise 'Expected erased object failure'
rescue RuntimeError => error
  check.call('deleted nodes cannot be located') { error.message.include?('已变化') }
end
child.erased = false
index.request_all
index.step until index.complete?
check.call('explicit full reading reaches every used level and excludes unused definitions') { index.all_loaded? && index.definitions.length == 2 && unused.entities.grep_calls.empty? }
check.call('a leaf becomes a confirmed empty child list after it is read') { index.payload[:definitions]['501'][:children] == [] && index.payload[:definitions]['501'][:loaded] }
check.call('the latest level exposes measured reading duration') { index.last_read_seconds.is_a?(Float) && index.last_read_seconds >= 0 }

Sketchup.active_model = model
panel = ModelFootprintTools::SizeInfo::Panel.new
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
dialog.event('scope', 'tree')
UI.drain
token = dialog.last_data['tree_token']
check.call('opening the panel reads roots and never exports automatically') { dialog.last_data['definition_count'] == 1 && parent.exports == 0 && !dialog.last_data['tree_all_loaded'] }
dialog.event('expand', { 'token' => token, 'path' => first.persistent_id.to_s })
UI.drain
check.call('native expansion loads the requested level and discovers its child') { dialog.last_data['definition_count'] == 2 && dialog.last_data['tree_complete'] && !dialog.last_data['tree_all_loaded'] }
dialog.event('measure')
UI.drain
check.call('loaded definitions are exported once despite repeated instances') { dialog.last_data['tree_measured'] == 2 && parent.exports == 1 && leaf.exports == 1 && unused.exports == 0 }
check.call('measurement never invents a sum across nested levels') { dialog.last_data['bytes'].nil? }
panel.send(:render)
check.call('unchanged byte counts are omitted from progress updates') { dialog.last_data['tree_sizes'].empty? }
analyzer = panel.instance_variable_get(:@analyzer)
check.call('size cache lookups by string ID do not need a native definition call') { analyzer.cached_by_id('501')[:bytes] == 4096 }
model.on_navigate = -> { panel.model_changed; panel.selection_changed }
dialog.event('locate', { 'token' => token, 'path' => "#{first.persistent_id}.#{child.persistent_id}" })
check.call('nested location changes edit context, selection and zoom together') { model.active_path == [first] && model.selection == [child] && model.active_view.zoomed == [child] && dialog.last_data['error'].nil? }
check.call('navigation does not discard measured tree data') { dialog.last_data['tree_token'] == token && dialog.last_data['tree_measured'] == 2 }
dialog.event('locate', { 'token' => token, 'path' => path })
check.call('locked edit contexts produce a location error without unlocking') { dialog.last_data['error'].include?('无法定位') && second.locked? }
parent.fail_save = true
dialog.event('measure')
UI.drain
check.call('a failed export does not stop other definitions or preserve stale bytes') { dialog.last_data['tree_errors'] == 1 && dialog.last_data['tree_measured'] == 1 && analyzer.cached_by_id('502').nil? && leaf.exports == 2 }
parent.fail_save = false
dialog.event('measure')
UI.drain
check.call('retrying exports only the missing definition') { dialog.last_data['tree_measured'] == 2 && leaf.exports == 2 && dialog.last_data['error'].nil? }
dialog.event('load_all')
UI.drain
check.call('the explicit full-directory button finishes unread leaf levels') { dialog.last_data['tree_all_loaded'] && dialog.last_data['tree_measured'] == 2 }
original = panel.instance_variable_get(:@tree_index)
dialog.event('scope', 'model')
UI.drain
dialog.event('scope', 'tree')
UI.drain
check.call('switching back to an unchanged tree reuses its loaded levels') { panel.instance_variable_get(:@tree_index).equal?(original) && dialog.last_data['tree_all_loaded'] }
dialog.event('ready')
check.call('reloading the HTML resends cached structure and sizes without scanning again') { dialog.last_data['tree_structure']['roots'].length == 2 && dialog.last_data['tree_sizes'].length == 2 && panel.instance_variable_get(:@tree_index).equal?(original) }
panel.model_changed
UI.drain
check.call('model changes discard stale measurements and return to root-only reading') { dialog.last_data['tree_token'] != token && dialog.last_data['tree_measured'] == 0 && dialog.last_data['definition_count'] == 1 }
dialog.event('expand', { 'token' => token, 'path' => first.persistent_id.to_s })
check.call('expansion requests from an obsolete document version are rejected') { dialog.last_data['error'].include?('组件树已更新') }
dialog.close
check.call('closing the panel cancels timers and removes all observers') { UI.timer_count == 0 && model.observer_count == 0 && Sketchup.observer_count == 0 }

# 3700 definitions behind one root must not be visited merely to open a panel.
huge = TestModel.new
outer = TestDefinition.new(9000, '外层群组', 64)
3700.times do |number|
  definition = TestDefinition.new(10_000 + number, "nested #{number}", 1)
  outer.entities << Sketchup::ComponentInstance.new(definition)
  huge.definitions << definition
  def definition.instances; raise 'Global instance index must never be read'; end
end
huge.entities << Sketchup::Group.new(outer)
huge.definitions << outer
def outer.instances; raise 'Global instance index must never be read'; end
huge.definitions.define_singleton_method(:each) { raise 'Global definition catalog must never be enumerated' }
fast = tree_class.new(huge)
fast.step until fast.complete?
check.call('3700 descendant definitions do not delay first root-level reading') { fast.definitions == [outer] && fast.entry_count == 1 && outer.entities.grep_calls.empty? && huge.entities.grep_calls.length == 2 }
fast.request('9000')
check.call('reading a wide child level yields before all 3700 rows are built') { !fast.step(100) && fast.entry_count > 1 && fast.entry_count <= 101 }
fast.step until fast.complete?
check.call('reading one level does not enter its 3700 child definitions') { fast.definitions.length == 3701 && fast.scanned_definitions == 1 && !fast.all_loaded? }
check.call('sibling paging data retains all objects without expanding their geometry') { fast.payload[:definitions]['9000'][:children].length == 3700 }
Sketchup.active_model = huge
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
huge_token = dialog.last_data['tree_token']
huge_path = huge.entities.first.persistent_id.to_s
dialog.event('expand', { 'token' => huge_token, 'path' => huge_path })
UI.tick
dialog.event('cancel')
check.call('a wide lazy branch can be stopped between timer slices') { !dialog.last_data['busy'] && !dialog.last_data['tree_complete'] && UI.timer_count == 0 }
dialog.event('expand', { 'token' => huge_token, 'path' => huge_path })
UI.drain
check.call('reopening a paused branch resumes its read without exporting any definitions') { dialog.last_data['tree_complete'] && dialog.last_data['definition_count'] == 3701 && outer.exports == 0 }
dialog.close

# A fast export batch should yield to the UI after at most twenty files, with
# no fixed 80-ms wait attached to each individual definition.
batch_model = TestModel.new
batch_definitions = 45.times.map { |number| TestDefinition.new(20_000 + number, "batch #{number}", 1) }
batch_model.definitions.concat(batch_definitions)
batch_definitions.each { |definition| batch_model.entities << Sketchup::ComponentInstance.new(definition) }
nested = TestDefinition.new(21_000, 'nested request', 1)
batch_definitions.first.entities << Sketchup::Group.new(nested)
batch_model.definitions << nested
Sketchup.active_model = batch_model
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
UI.timer_intervals = []
dialog.event('measure')
UI.tick
finished = batch_definitions.sum(&:exports)
check.call('exports run in bounded batches and retain a cancel opportunity') { finished > 0 && finished <= 20 && dialog.last_data['busy'] }
dialog.event('cancel')
UI.drain
check.call('stopping a batch preserves completed file measurements') { dialog.last_data['tree_measured'] == finished && !dialog.last_data['busy'] }
dialog.event('measure')
dialog.event('expand', { 'token' => dialog.last_data['tree_token'], 'path' => batch_model.entities.first.persistent_id.to_s })
UI.drain
check.call('continuing a batch skips already measured definitions') { batch_definitions.all? { |definition| definition.exports == 1 } && dialog.last_data['tree_measured'] == 45 }
check.call('expansion queued during exports runs afterwards without canceling measurements') { dialog.last_data['definition_count'] == 46 && dialog.last_data['pending_count'] == 1 && dialog.last_data['tree_complete'] }
check.call('export timers no longer impose an 80-ms gap per definition') { UI.timer_intervals.all? { |seconds| seconds <= 0.001 } }
panel.model_changed
UI.drain
exports_before_cancel = batch_definitions.sum(&:exports)
batch_definitions.first.define_singleton_method(:save_copy) do |path|
  result = super(path)
  dialog.event('cancel')
  result
end
dialog.event('measure')
UI.tick
check.call('a cancellation arriving inside an export prevents the rest of its batch') { batch_definitions.sum(&:exports) == exports_before_cancel + 1 && !dialog.last_data['busy'] && dialog.last_data['tree_measured'] == 1 && UI.timer_count == 0 }
dialog.close

empty = TestModel.new
Sketchup.active_model = empty
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
check.call('an empty model completes immediately without an export job') { dialog.last_data['tree_complete'] && dialog.last_data['tree_all_loaded'] && dialog.last_data['definition_count'] == 0 && UI.timer_count == 0 }
dialog.close

# Per-row calculation must not turn a parent request into a recursive export.
item_model = TestModel.new
item_parent = TestDefinition.new(30_000, '父组件', 8192)
item_child = TestDefinition.new(30_001, '子组件', 1024)
item_other = TestDefinition.new(30_002, '独立组件', 2048)
child_instance = Sketchup::ComponentInstance.new(item_child, '子项')
item_parent.entities << child_instance
parent_instance = Sketchup::Group.new(item_parent, '父项 A')
shared_instance = Sketchup::ComponentInstance.new(item_parent, '父项 B')
other_instance = Sketchup::ComponentInstance.new(item_other, '独立项')
item_model.entities.concat([parent_instance, shared_instance, other_instance])
item_model.definitions.concat([item_parent, item_child, item_other])
item_model.selection << parent_instance
Sketchup.active_model = item_model
item_panel = ModelFootprintTools::SizeInfo::Panel.new
item_panel.show
item_dialog = item_panel.instance_variable_get(:@dialog)
item_dialog.event('ready')
UI.drain
check.call('a fresh panel defaults to hierarchy reading even with a selected component') { item_dialog.last_data['scope'] == 'tree' && item_dialog.last_data['tree_measured'] == 0 && item_parent.exports == 0 && item_child.exports == 0 }
item_token = item_dialog.last_data['tree_token']
parent_request = { 'token' => item_token, 'path' => parent_instance.persistent_id.to_s, 'force' => false }
item_dialog.event('locate', parent_request)
check.call('selecting a tree item leaves every size uncomputed') { item_parent.exports == 0 && item_child.exports == 0 && item_other.exports == 0 }
item_dialog.event('measure_item', parent_request)
check.call('a row request exposes the definition being calculated') { item_dialog.last_data['tree_measuring_id'] == '30000' && item_dialog.last_data['busy'] }
item_dialog.event('measure_item', parent_request)
UI.drain
item_analyzer = item_panel.instance_variable_get(:@analyzer)
check.call('a parent calculation exports one full definition without reading or exporting descendants') { item_parent.exports == 1 && item_child.exports == 0 && item_other.exports == 0 && item_parent.entities.grep_calls.empty? && item_analyzer.cached_by_id('30000')[:bytes] == 8192 }
item_dialog.event('measure_item', { 'token' => item_token, 'path' => shared_instance.persistent_id.to_s, 'force' => false })
UI.drain
check.call('another instance reuses the same cached size without exporting again') { item_parent.exports == 1 && item_dialog.last_data['tree_measuring_id'].nil? && !item_dialog.last_data['busy'] }
item_dialog.event('measure_item', { 'token' => item_token, 'path' => other_instance.persistent_id.to_s, 'force' => false })
UI.drain
item_parent.payload_bytes = 12_288
item_dialog.event('measure_item', parent_request.merge('force' => true))
UI.drain
check.call('recalculating one definition preserves other cached results') { item_parent.exports == 2 && item_other.exports == 1 && item_analyzer.cached_by_id('30000')[:bytes] == 12_288 && item_analyzer.cached_by_id('30002')[:bytes] == 2048 }
item_parent.fail_save = true
item_dialog.event('measure_item', parent_request.merge('force' => true))
UI.drain
check.call('a failed single recalculation clears only its own outdated result') { item_analyzer.cached_by_id('30000').nil? && item_analyzer.cached_by_id('30002')[:bytes] == 2048 && item_dialog.last_data['tree_errors'] == 1 && !item_dialog.last_data['busy'] }
item_parent.fail_save = false
item_dialog.event('measure_item', parent_request)
UI.drain
check.call('a row retry clears its error without recalculating unrelated definitions') { item_parent.exports == 4 && item_other.exports == 1 && item_child.exports == 0 && item_dialog.last_data['tree_errors'] == 0 && item_dialog.last_data['error'].nil? }

item_dialog.event('load_all')
item_dialog.event('cancel')
queries_before_single = item_parent.entities.grep_calls.length
item_dialog.event('measure_item', parent_request.merge('force' => true))
UI.drain
check.call('a single calculation does not resume a directory read that the user stopped') { !item_dialog.last_data['tree_complete'] && item_parent.entities.grep_calls.length == queries_before_single && UI.timer_count == 0 }
item_dialog.event('load_all')
UI.drain
parent_exports_before_child = item_parent.exports
item_dialog.event('measure_item', { 'token' => item_token, 'path' => "#{parent_instance.persistent_id}.#{child_instance.persistent_id}", 'force' => false })
UI.drain
check.call('a nested child can be calculated separately without exporting its parent again') { item_child.exports == 1 && item_parent.exports == parent_exports_before_child && item_analyzer.cached_by_id('30001')[:bytes] == 1024 }
item_dialog.event('measure_item', parent_request.merge('force' => true))
item_dialog.event('cancel')
UI.drain
check.call('canceling a queued row calculation preserves other definition sizes') { item_parent.exports == parent_exports_before_child && item_analyzer.cached_by_id('30001')[:bytes] == 1024 && item_dialog.last_data['tree_measuring_id'].nil? && UI.timer_count == 0 }
item_panel.model_changed
UI.drain
item_dialog.event('measure_item', parent_request)
check.call('a calculation request from a stale tree is rejected after an edit') { item_dialog.last_data['error'].include?('组件树已更新') && item_parent.exports == parent_exports_before_child }
item_dialog.close
puts "#{passed.length} tree checks passed."
