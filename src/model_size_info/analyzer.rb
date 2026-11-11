# encoding: UTF-8
require 'json'
require 'tmpdir'
require 'fileutils'

module ModelFootprintTools
  module SizeInfo
    # Only small protocol files are read by SketchUp. SKP copying, parsing and
    # exporting happen in a separate process, against a private saved snapshot.
    class BackgroundSession
      MAX_PACKET_BYTES = 1_048_576
      STARTUP_TIMEOUT = 300
      TASK_TIMEOUT = 180
      attr_reader :directory, :source_bytes

      def initialize(source, api_path = nil, launcher = nil)
        @source = source
        @api_path = api_path
        @launcher = launcher
        @request_id = 0
        @ready = false
        @pending = nil
        @pid = nil
      end

      def start
        raise '后台已经启动。' if @pid
        raise '请先保存模型，再刷新读取。' if @source.to_s.empty?
        api = @api_path || Sketchup.find_support_file('SketchUpAPI.dll')
        executable = File.join(__dir__, 'worker', 'ModelSizeWorker.exe')
        raise '后台读取需要 Windows 桌面版 SketchUp 2022 或更新版本。' unless api && File.file?(api) && File.file?(executable)
        @directory = Dir.mktmpdir('su-model-size-bg-')
        arguments = [executable, @directory, api, @source, Process.pid.to_s]
        @pid = if @launcher
                 @launcher.call(arguments)
               else
                 Process.spawn(*arguments, out: File::NULL, err: File::NULL, new_pgroup: true)
               end
        @started = monotonic
        self
      rescue StandardError
        close
        raise
      end

      def ready?
        @ready
      end

      def pending?
        !@pending.nil?
      end

      def request(operation, definition_id = '', offset = 0, force = false)
        raise '后台尚未就绪。' unless @ready
        raise '后台正在处理上一项任务。' if @pending
        raise '后台任务无效。' unless %w[list measure].include?(operation)
        @request_id += 1
        command = { request_id: @request_id, operation: operation,
          definition_id: definition_id, offset: offset, force: force == true }
        temp = File.join(@directory, 'request.tmp')
        File.write(temp, JSON.generate(command), mode: 'w', encoding: 'UTF-8')
        File.rename(temp, File.join(@directory, 'request.json'))
        @pending = command
        @started = monotonic
      end

      def poll
        raise '后台尚未启动。' unless @pid
        path = File.join(@directory, 'response.json')
        if File.file?(path)
          raise '后台结果过大，请减少读取范围。' if File.size(path) > MAX_PACKET_BYTES
          data = JSON.parse(File.read(path, encoding: 'UTF-8'))
          File.delete(path)
          if data['ready']
            raise '后台返回了意外的启动结果。' if @ready || @pending
            @ready = true
            @source_bytes = data.fetch('source_bytes')
            raise '后台文件大小无效。' unless @source_bytes.is_a?(Integer) && @source_bytes >= 0
          elsif @pending
            raise '后台结果已过期。' unless data['request_id'] == @pending[:request_id]
            @pending = nil
          elsif data['ok'] == true
            raise '后台返回了意外结果，请刷新。'
          end
          raise(data['error'] || '后台读取失败。') unless data['ok'] == true
          return data
        end
        exited = Process.waitpid(@pid, Process::WNOHANG)
        if exited
          @pid = nil
          raise '后台程序已退出，请刷新后重试。'
        end
        timeout = @ready ? TASK_TIMEOUT : STARTUP_TIMEOUT
        if (!@ready || @pending) && monotonic - @started >= timeout
          close
          raise '后台任务耗时过长，已停止。可保存模型后重试或计算更小的子组件。'
        end
        nil
      rescue Errno::ECHILD, Errno::ESRCH
        @pid = nil
        raise '后台程序已退出，请刷新后重试。'
      end

      def close
        pid, directory = @pid, @directory
        @pid = @directory = nil
        @ready = false
        @pending = nil
        if pid
          begin
            Process.kill('KILL', pid)
            Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD, Errno::ESRCH
          end
        end
        # The directory is created by this session, never supplied by a packet.
        if directory && File.dirname(directory) == Dir.tmpdir && File.basename(directory).start_with?('su-model-size-bg-')
          begin
            FileUtils.remove_entry(directory) if File.directory?(directory)
          rescue SystemCallError
            # A just-terminated process can hold its last file handle briefly.
            if defined?(UI)
              UI.start_timer(0.2, false) do
                begin
                  FileUtils.remove_entry(directory) if File.directory?(directory)
                rescue SystemCallError
                end
              end
            end
          end
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
