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

require_relative 'lib/gpu'
require_relative 'lib/llama_instance'
require_relative 'lib/model'

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

VERBOSE   = CONFIG['verbose'] || false
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
    threads: [1, 1],
    environment: :production,
    queue_requests: false
  }
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
    $models[m[:name]] = Model.new(m[:name], m[:slots], m[:context_length], m[:url], m[:files], m[:extra_args])
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
  gpus = request_data[:gpus] || $gpus.keys
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
  if request.accept.include?("text/html") 
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
      gpus: $gpus.map { |id,  gpu| gpu },
      models: $models.map { |name, model| model }, 
      instances: $instances.map { |name, instance| instance } 
    }.to_json
  end
end
