#!/usr/bin/env ruby
require 'sinatra'
require 'open3'
require 'fileutils'
require 'uri'
require 'json'
require 'yaml'
require 'thread'
require 'optparse'
require 'rainbow'

using Rainbow

config_file = './config-backend.yml'
cli_options = {}

OptionParser.new do |opts|
  opts.on('-cFILE', '--config=FILE', 'Path to config file') do |file|
    config_file = file
  end
  opts.on('-lNUM', '--log-lines=NUM', Integer, 'Number of log lines to keep') do |num|
    cli_options['log_lines'] = num
  end
  opts.on('-mDIR', '--model-dir=DIR', 'Path to model directory') do |dir|
    cli_options['model_dir'] = dir
  end
  opts.on('-uSEC', '--update-in=SEC', Integer, 'Gpu status update interval') do |sec|
    cli_options['update_in'] = sec
  end
  opts.on('-bBIN', '--llama-bin=BIN', 'Path to Llama.cpp binary') do |bin|
    cli_options['llama_bin'] = bin
  end
  opts.on('-hHOST', '--bind-host=HOST', 'Bind host') do |host|
    cli_options['bind_host'] = host
  end
  opts.on('-pPORT', '--bind-port=PORT', Integer, 'Bind port') do |port|
    cli_options['bind_port'] = port
  end
  opts.on('--blacklist=VENDOR', 'Blacklist Gpu vendor (can be specified multiple times)') do |vendor|
    cli_options['blacklist'] ||= []
    cli_options['blacklist'] << vendor
  end
end.parse!

file_config = if config_file && File.exist?(config_file)
  YAML.load_file(config_file)
else
  {}
end

CONFIG = file_config.merge(cli_options)

LOG_LINES = CONFIG['log_lines'] || 100
MODEL_DIR = CONFIG['model_dir'] || "models"
UPDATE_IN = CONFIG['update_in'] || 2
LLAMA_BIN = CONFIG['llama_bin'] || "./server"
BIND_HOST = CONFIG['bind_host'] || '0.0.0.0'
BIND_PORT = CONFIG['bind_port'] || 4567
BLACKLIST = CONFIG['blacklist'].map(&:upcase) if CONFIG['blacklist'].is_a?(Array)
BLACKLIST ||= []
LLAMA_PORT_RANGE = CONFIG['llama_port_range'][0]..CONFIG['llama_port_range'][1] if CONFIG['llama_port_range'].is_a?(Array)
LLAMA_PORT_RANGE ||= 8080..8099
$USED_PORTS = []

# Ensure model directory exists
FileUtils.mkdir_p(MODEL_DIR)

set :bind, BIND_HOST
set :port, BIND_PORT

set :server, 'puma'

set :puma_config do
  {
    workers: 32,
    threads: [1, 32],
    environment: :production,
    queue_requests: false
  }
end

class Model
  attr_reader :name, :slots, :ctx, :url, :files, :extra_args

  def initialize(name, slots, ctx, url, files, extra_args = [])
    @name = name
    @slots = slots || 1
    @ctx = ctx
    @url = url
    @files = files
    @extra_args = extra_args || []
    @downloading = false
  end

  def to_json(*args)
    {
      name: @name,
      slots: @slots,
      ctx: @ctx,
      files: @files,
      ready: ready?,
      url: @url,
      extra_args: @extra_args
    }.to_json(*args)
  end

  def ready?
    !@downloading #&&
     # @files.all? { |file| File.exist?(File.join(MODEL_DIR, file)) &&
     #                      File.size?(File.join(MODEL_DIR, file)) }
  end
  def download_missing_files
    @files.each do |file|
      filepath = File.join(MODEL_DIR, file)
      temp_filepath = "#{filepath}.tmp"
      unless File.exist?(filepath) && File.size?(filepath)
        puts "Downloading #{file}..."
        @downloading = true
        thread = Thread.new do
          url = format(@url, file)
          system("wget -O #{temp_filepath} #{url}")
          File.rename(temp_filepath, filepath) if File.size?(temp_filepath)
          @downloading = false
        end
      end
    end
  end

  def path
    File.join(MODEL_DIR, @files.first)
  end
end

class Gpu
  attr_reader :vendor, :device, :status, :vendor_id

  def initialize(vendor, device, vendor_id)
    @vendor = vendor
    @device = device
    @vendor_id = vendor_id
    @status = { vram_total: 0, vram_used: 0, power_usage: 0 }
    start_monitoring
  end

  def to_json(*args)
    {
      vendor: @vendor,
      vendor_index: @vendor_id,
      model: @device,
      memory_total: @status[:vram_total],
      memory_free: @status[:vram_total] - @status[:vram_used],
      compute_usage: 0,
      membw_usage: 0, 
      power_usage: @status[:power_usage],
      temperature: 0
    }.to_json(*args)
  end

  def start_monitoring
    Thread.new do
      loop do
        update_status
        sleep UPDATE_IN
      end
    end
  end

  def self.enumerate
    id = 0
    gpus = {}
    blacklist = BLACKLIST
    puts "Enumerating Gpus:"
    `lspci -nn`.each_line do |line|
      next unless line =~ /VGA|3D/i
      vendor = if line =~ /NVIDIA/i
                 "NVIDIA"
               elsif line =~ /AMD/i
                 "AMD"
               elsif line =~ /Intel/i
                 "Intel"
               else
                 "Unknown"
               end
      
      # Skip if vendor is blacklisted
      next if blacklist.include?(vendor.upcase)
    
      pci_id = line.split(" ")[0]
      vendor_id = extract_vendor_id(line, vendor)
      puts "Gpu #{id}: #{vendor} Vendor ID: #{vendor_id} #{line.strip}"
      gpus[id] = Gpu.new(vendor, line.strip, vendor_id)
      id += 1
    end
    gpus
  end

  def self.extract_vendor_id(match, vendor)
    case vendor
    when "NVIDIA"
      `nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits`.each_line do |line|
        index, bus_id = line.split(",")
        domain, bus, device, function = bus_id.split(":")
        lspci_line = `lspci -nn -s #{domain}:#{bus}:#{device}.#{function}`
        return index.strip if lspci_line == match
      end
      raise "NVIDIA Gpu not found"
    when "AMD"
      # TODO
      return 0
    when "Intel"
      # TODO
      return 0
    end
    "Unknown"
  end

  def update_status
    case @vendor
    when "NVIDIA"
      output = `nvidia-smi -i #{@vendor_id} --query-gpu=memory.total,memory.used,power.draw --format=csv,noheader,nounits`
      if $?.success?
        @status[:vram_total], @status[:vram_used], @status[:power_usage] = output.split(",").map(&:strip).map(&:to_i)
      else
        @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
      end
    when "AMD"
      output = `rocm-smi --showmeminfo vram --json`
      if $?.success?
        begin
          data = JSON.parse(output)
          @status[:vram_total] = data["VRAM_Total"]
          @status[:vram_used] = data["VRAM_Used"]
          @status[:power_usage] = data["Power_Usage"]
        rescue JSON::ParserError
          @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
        end
      else
        @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
      end
    when "Intel"
      output = `intel_gpu_top -d #{@vendor_id} -J 2>/dev/null`
      if $?.success?
        begin
          data = JSON.parse(output)
          @status[:vram_total] = data.dig("engines", 0, "memory", "total", "value") || 0
          @status[:vram_used] = data.dig("engines", 0, "memory", "used", "value") || 0
          @status[:power_usage] = data.dig("power", "gpu", "value") || 0
        rescue JSON::ParserError
          @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
        end
      else
        @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
      end
    else
      @status[:vram_total] = @status[:vram_used] = @status[:power_usage] = 0
    end
  end
end

class LlamaInstance
  attr_reader :name, :command, :gpus, :bind, :port, :process, :stdout, :loaded, :running
  attr_accessor :slots_in_use, :slots_capacity, :model

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
      running: @process ? true : false,
      loaded: @loaded,
      command: @command,
      gpus: @gpus.map(&:device)
    }.to_json(*args)
  end

  def start
    return "Instance already running" if @running
    #puts Rainbow(caller.join("\n")).green
    @command = "#{LLAMA_BIN} -m #{@model.path} "
    @command += "-ngl 99 --host #{@bind} --port #{@port} "
    @command += "-c #{@model.ctx * @model.slots} "
    @command += "-np #{@model.slots} "
    @command += @model.extra_args.join(' ')

    env = if @gpus.any? { |gpu| gpu.vendor == "Intel" }
            { "SYCL_DEVICE_FILTER" => "gpu:#{@gpus.map(&:device).join(',')}" }
          else
           # { "CUDA_VISIBLE_DEVICES" => @gpus.map(&:device).join(",") }
           {}
          end
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
              if line =~ /main: server is listening on/
                @loaded = true
              end
              # Maintain only the last 100 lines
              @stdout << line.chomp
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

$models = {}
$instances = {}
$gpus = Gpu.enumerate
$initialization_done = false

def initialize_models
  Thread.new do
    $models.each_value(&:download_missing_files)
    $initialization_done = true
    puts "Model initialization done"
  end
end

post '/models' do
  models = JSON.parse(request.body.read, symbolize_names: true) rescue []
  models.each do |m|
    $models[m[:name]] = Model.new(m[:name], m[:slots], m[:ctx], m[:url], m[:files], m[:extra_args])
  end
  $initialization_done = false
  puts "Model initialization started"
  initialize_models
  status 202
  { message: "Model initialization started" }.to_json
end

get '/models' do
  content_type :json
  $models.map { |name, model| model }.to_json
end

post '/instances' do
  if $instances[params['name']]
    halt 409, { error: "Instance name already exists" }.to_json
  end
  request_data = JSON.parse(request.body.read, symbolize_names: true)
  model = $models[request_data[:model]]
  halt 404, { error: "Model not found. #{request_data.inspect}" }.to_json if model.nil?

  instance_name = request_data[:name]
  gpus = request_data[:gpus] || []
  bind = BIND_HOST
  
  port = LLAMA_PORT_RANGE.find { |p| !$USED_PORTS.include?(p) }
  halt 503, { error: "No available ports" }.to_json if port.nil?
  
  $USED_PORTS << port
  instance = LlamaInstance.new(instance_name, model, bind, port, gpus.map { |gpu_id| $gpus[gpu_id.to_i] })
  $instances[instance_name] = instance
  
  result = instance.start
  halt 500, { error: "Failed to start instance" }.to_json unless result
  
  status 201
  instance.to_json
end

delete '/instances/:name' do
  instance_name = params['name']
  instance = $instances[instance_name]
  halt 404, { error: "Instance not found" }.to_json if instance.nil?
  instance.stop
  $USED_PORTS.delete(instance.port)
  $instances.delete(instance_name)
  status 200
  { message: $instances[instance_name].stop }.to_json
end

get '/instances' do
  content_type :json
  $instances.values.to_json
end

get '/instances/:name' do
  instance_name = params['name']
  instance = $instances[instance_name]
  halt 404, { error: "Instance not found" }.to_json if instance.nil?
  content_type :json
  instance.to_json
end

get '/instances/:name/logs' do
  instance_name = params['name']
  instance = $instances[instance_name]
  halt 404, { error: "Instance not found" }.to_json if instance.nil?
  content_type :json
  { logs: instance.stdout, active: instance.active, slots_in_use: instance.slots_in_use }.to_json
end

get '/gpus' do
  content_type :json
  $gpus.map { |id, gpu| gpu }.to_json
end

get '/' do
  puts "Request: #{request.accept}" 
  if true 
    gpus_html = "<table><tr><th>Vendor</th><th>Vendor ID</th><th>Device</th><th>VRAM Total</th><th>VRAM Used</th><th>Power Usage</th></tr>"
    $gpus.each do |id, gpu|
      gpus_html += "<tr><td>#{gpu.vendor}</td><td>#{gpu.vendor_id}</td><td>#{gpu.device}</td><td>#{gpu.status[:vram_total]}</td><td>#{gpu.status[:vram_used]}</td><td>#{gpu.status[:power_usage]}</td></tr>"
    end
    gpus_html += "</table>"

    models_html = "<table><tr><th>Name</th><th>URL Template</th><th>Files</th></tr>"
    $models.each_value do |model|
      models_html += "<tr><td>#{model.name}</td><td>#{model.url}</td><td>#{model.files.join(', ')}</td></tr>"
    end
    models_html += "</table>"

    instances_html = "<table><tr><th>Name</th><th>Command</th><th>Gpus</th><th>Bind</th><th>Port</th><th>Status</th></tr>"
    $instances.each_value do |instance|
      instances_html += "<tr><td>#{instance.name}</td><td>#{instance.command}</td><td>#{instance.gpus.map(&:device).join(', ')}</td><td>#{instance.bind}</td><td>#{instance.port}</td><td>#{instance.process ? 'Running' : 'Stopped'}</td></tr>"
    end
    instances_html += "</table>"

    "<html><body><h1>Gpus</h1>#{gpus_html}<h1>Models</h1>#{models_html}<h1>Instances</h1>#{instances_html}</body></html>"
  else
    content_type :json
    {
      gpus: $gpus.map { |id,  gpu| { vendor: gpu.vendor, device: gpu.device, status: gpu.status } },
      models: $models.map { |name, model| { name: name, url: model.url, files: model.files } },
      instances: $instances.map { |name, instance| { name: name, command: instance.command, gpus: instance.gpus.map(&:device), bind: instance.bind, port: instance.port, status: instance.process ? 'Running' : 'Stopped' } }
    }.to_json
  end
end