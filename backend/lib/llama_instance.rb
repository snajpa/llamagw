class LlamaInstance
  attr_reader :name, :command, :gpus, :bind, :port, :process, :stdout, :loaded, :running
  attr_accessor :slots_in_use, :slots_capacity, :model, :process

  def initialize(name, model, bind, port, gpus)
    @name = name
    @model = model
    @gpus = gpus || []
    @bind = bind
    @port = port
    @stdout = []
    @command = ""
    @process = nil
    @running = false
    @loaded = false
    @slots_capacity = model.slots
    @slots_in_use = 0
  end

  def to_json(*args)
    {
      name: @name,
      model: @model.name,
      slots_in_use: @slots_in_use,
      slots_capacity: @slots_capacity,
      port: @port,
      bind: @bind,
      running: @running,
      loaded: @loaded,
      command: @command,
      pid: @process&.pid,
      gpus: @gpus
    }.to_json(*args)
  end

  def start
    return "Instance already running" if @running
    #puts Rainbow(caller.join("\n")).green
    @command = "#{LLAMA_BIN} -m #{@model.path} "
    @command += "-ngl 99 --host #{@bind} --port #{@port} "
    @command += "-c #{@model.context_length * @model.slots} "
    @command += "-np #{@model.slots} "
    @command += "--no-mmap "
    @command += @model.extra_args.join(' ') if @model.extra_args.is_a?(Array)
    @command += @model.extra_args if @model.extra_args.is_a?(String)

    env = {}
    gpu_ids = @gpus.map(&:vendor_id)
    puts Rainbow("GPU IDs: #{gpu_ids}").green
    env_cuda_visible_devices = []
    env_rocm_visible_devices = []
    syscl_device_filter = []
    gpu_ids.each_with_index do |gpu_id, i|
      case @gpus[i].vendor
      when "NVIDIA"
        env_cuda_visible_devices = (env["CUDA_VISIBLE_DEVICES"] || "").split(",")
        env_cuda_visible_devices << gpu_id.to_s
        env["CUDA_VISIBLE_DEVICES"] = env_cuda_visible_devices.sort.uniq.join(",")
      when "AMD"
        env_rocm_visible_devices = (env["ROCM_VISIBLE_DEVICES"] || "").split(",")
        env_rocm_visible_devices << gpu_id.to_s
        env["ROCM_VISIBLE_DEVICES"] = env_rocm_visible_devices.sort.uniq.join(",")
      when "Intel"
        syscl_device_filter = (env["SYCL_DEVICE_FILTER"] || "").split(":")&.last&.split(",") || []
        syscl_device_filter << gpu_id.to_s
        env["SYCL_DEVICE_FILTER"] = "gpu:#{syscl_device_filter.join(',')}"
      end
    end
    #puts "Starting instance with command: #{@command}"
    #puts "Environment:\n#{env}"
    env.merge!(ENV)
    @thread = Thread.new do
      Open3.popen3(env, @command) do |stdin, stdout, stderr, wait_thr|
        @process = wait_thr
        @running = true
        ios = [stdout, stderr]

        until ios.empty?
          ready = IO.select(ios) # Wait for readable IO streams
      
          ready[0].each do |io|
            begin
              line = io.gets
              if line.nil?  # Stream is closed
                ios.delete(io)
                next
              end
              # Maintain only the last 100 lines
              @stdout << line.chomp
              if !@loaded && @stdout.join("\n").include?("main: server is listening on")
                @loaded = true
              end
              @stdout.shift if @stdout.size > 100
      
              # Print output in real-time
              if io == stdout
                puts line
              else
                warn line
              end
            rescue EOFError
              ios.delete(io) # Remove closed stream
            end
          end
        end
      end
      @running = false
    end
    puts "Thread started"
    to_json
  end

  def stop
    return "No instance running" unless @process
    Process.kill("TERM", @process.pid)
    @process = nil
    @running = false
    @loaded = false
    "Llama.cpp instance '#{@name}' stopped"
  end
end
