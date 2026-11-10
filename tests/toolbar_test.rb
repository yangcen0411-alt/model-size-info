# encoding: UTF-8
# Exercise main.rb registration and callbacks without launching SketchUp.
$LOADED_FEATURES << 'sketchup.rb'
$toolbar_test_loaded_files = {}
TB_NEVER_SHOWN = -1
TB_HIDDEN = 0
TB_VISIBLE = 1

def file_loaded?(path)
  $toolbar_test_loaded_files.key?(path)
end

def file_loaded(path)
  $toolbar_test_loaded_files[path] = true
end

module Sketchup
  class SelectionObserver; end
  class ModelObserver; end
  class MaterialsObserver; end
  class EntitiesObserver; end
  class AppObserver; end
  class << self
    attr_accessor :platform
    def version; '26.0'; end
  end
end

module UI
  class Command
    attr_accessor :small_icon, :large_icon, :tooltip, :status_bar_text
    attr_reader :name
    def initialize(name, &callback)
      @name, @callback = name, callback
    end
    def invoke; @callback.call; end
  end

  class Menu
    attr_reader :items
    def initialize; @items = []; end
    def add_item(command); @items << command; end
  end

  class Toolbar
    class << self
      attr_accessor :next_state
      def instances; @instances ||= []; end
    end
    attr_reader :name, :items, :show_count, :restore_count
    def initialize(name)
      @name, @last_state = name, self.class.next_state
      @items, @show_count, @restore_count = [], 0, 0
      self.class.instances << self
    end
    def add_item(command); @items << command; end
    def get_last_state; @last_state; end
    def show; @show_count += 1; @visible = true; end
    def restore; @restore_count += 1; @visible = @last_state == TB_VISIBLE; end
    def visible?; !!@visible; end
  end

  class << self
    def menu(name); (@menus ||= {})[name] ||= Menu.new; end
    def context_handlers; @context_handlers ||= []; end
    def add_context_menu_handler(&callback); context_handlers << callback; end
  end
end

checks = 0
check = lambda do |name, &block|
  raise "FAIL: #{name}" unless block.call
  checks += 1
  puts "PASS: #{name}"
end
entry = File.expand_path('../src/model_size_info/main.rb', __dir__)
Sketchup.platform = :platform_win
UI::Toolbar.next_state = TB_NEVER_SHOWN
load entry
toolbar = UI::Toolbar.instances.last
command = toolbar.items.first
check.call('registration creates one named toolbar with one tool button') { toolbar.name == '模型占用信息' && toolbar.items.length == 1 }
check.call('first installation displays the toolbar') { toolbar.visible? && toolbar.show_count == 1 && toolbar.restore_count == 0 }
check.call('Windows toolbar icons use the packaged SVG asset') { command.small_icon == command.large_icon && command.small_icon.end_with?('.svg') && File.file?(command.small_icon) }
check.call('the button provides an informative tooltip and status text') { command.tooltip.include?('SKP') && command.status_bar_text.include?('按需计算') }
context_menu = UI::Menu.new
UI.context_handlers.first.call(context_menu)
check.call('toolbar, extension menu and context menu share one command') { UI.menu('Extensions').items.first.equal?(command) && context_menu.items.first.equal?(command) }

fake_panel = Object.new
def fake_panel.show; @show_count = (@show_count || 0) + 1; end
def fake_panel.show_count; @show_count; end
constructed = 0
ModelFootprintTools::SizeInfo::Panel.define_singleton_method(:new) do
  constructed += 1
  fake_panel
end
command.invoke
command.invoke
check.call('clicking the tool opens and reuses the panel through its normal entry point') { constructed == 1 && fake_panel.show_count == 2 }
load entry
check.call('loading the extension twice keeps a single toolbar and command') { UI::Toolbar.instances.length == 1 && UI.menu('Extensions').items.length == 1 }

$toolbar_test_loaded_files.clear
Sketchup.platform = :platform_osx
UI::Toolbar.next_state = TB_VISIBLE
load entry
mac_toolbar = UI::Toolbar.instances.last
check.call('a previously visible toolbar restores its saved placement') { mac_toolbar.restore_count == 1 && mac_toolbar.show_count == 0 && mac_toolbar.visible? }
mac_icon = mac_toolbar.items.first.small_icon
check.call('macOS toolbar icons use the packaged PDF vector asset') { mac_icon.end_with?('.pdf') && File.binread(mac_icon, 5) == '%PDF-' }

$toolbar_test_loaded_files.clear
Sketchup.platform = :platform_win
UI::Toolbar.next_state = TB_HIDDEN
load entry
hidden_toolbar = UI::Toolbar.instances.last
check.call('a previously hidden toolbar restores its hidden preference') { hidden_toolbar.restore_count == 1 && hidden_toolbar.show_count == 0 && !hidden_toolbar.visible? }
puts "#{checks} toolbar checks passed."
