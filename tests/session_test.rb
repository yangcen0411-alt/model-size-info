# encoding: UTF-8
# Integration test using a saved test fixture and the installed C API.
require_relative '../src/model_size_info/analyzer'
require 'digest'

source = ENV.fetch('MODEL_SIZE_TEST_SKP')
api = ENV.fetch('MODEL_SIZE_TEST_API')
fixture_directory = Dir.mktmpdir('model-size-ruby-中文 & ')
copy = File.join(fixture_directory, "模型 & (saved 'copy').skp")
FileUtils.cp(source, copy)
source = copy
session = ModelFootprintTools::SizeInfo::BackgroundSession.new(source, api)
before = Digest::SHA256.file(source).hexdigest

def receive(session)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
  loop do
    value = session.poll
    return value if value
    raise 'Background result timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep(0.02)
  end
end

begin
  session.start
  raise 'Startup performed blocking work' if session.ready?
  raise 'Missing startup response' unless receive(session)['ready']
  session.request('list')
  roots = receive(session)
  raise 'Background roots missing' unless roots['ok'] && roots['nodes'].length > 0
  id = roots['nodes'].first.fetch('definition_id')
  session.request('measure', id)
  result = receive(session)
  raise 'Real component byte measurement missing' unless result['bytes'].is_a?(Integer) && result['bytes'] > 100
  raise 'Source modified' unless Digest::SHA256.file(source).hexdigest == before
  directory = session.directory
  Process.kill('KILL', session.instance_variable_get(:@pid))
  begin
    receive(session)
    raise 'Terminated worker was not detected'
  rescue RuntimeError => error
    raise unless error.message.include?('后台程序已退出')
    raise 'Reaped PID must not be retained' unless session.instance_variable_get(:@pid).nil?
  end
ensure
  session.close
  FileUtils.remove_entry(fixture_directory)
end
raise 'Session folder was not cleaned' if directory && File.directory?(directory)
puts 'Ruby-to-worker startup, Unicode arguments, paged reading, real export, source preservation, reaped PID handling and cleanup passed.'
