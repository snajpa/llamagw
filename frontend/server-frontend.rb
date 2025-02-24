#!/usr/bin/env ruby
#RACK_ENV=production rake db:drop DISABLE_DATABASE_ENVIRONMENT_CHECK=1; RACK_ENV=production rake db:create; RACK_ENV=production rake db:schema:load
require 'mysql2'
require 'yaml'
require 'json'
require 'csv'
require 'net/http'
require 'uri'
require 'thread'
require 'optparse'
require 'sinatra/activerecord'  
require 'sinatra/base'

require 'rainbow/refinement'
using Rainbow

#require 'sinatra/reloader' if true

require_relative 'models/model'
require_relative 'models/backend'
require_relative 'models/gpu'
require_relative 'models/llama_instance'
require_relative 'models/llama_instance_slot'

config_file = './config-frontend.yml'
OptionParser.new do |opts|
  opts.banner = "Usage: server-frontend.rb [options]"
  opts.on('-c', '--config=FILE', 'Path to config file') do |file|
    config_file = file
  end
end.parse!

unless config_file
  puts "Error: Configuration file must be specified with --config/-c"
  exit 1
end

$config = YAML.load_file(config_file)
$config["update_interval"] ||= 60
$config["instance_timeout"] ||= 300
$config["backend_timeout"] ||= 5
$config["verbose"] ||= false

def load_config_into_db(config_file)
  # Update models while preserving existing records
  if $config['models']
    $config['models'].each do |model_conf|
      Model.import_from_config(model_conf)
    end
  end

  # Update backends while preserving state
  if $config['backends']
    $config['backends'].each do |backend_conf|
      backend = Backend.find_or_initialize_by(name: backend_conf['name'])
      backend.name = backend_conf['name']
      backend.url  = backend_conf['url']
      backend.save!
      begin
        backend.post_model_list(Model.all)
        backend.sync_complete_state
      rescue => e
        puts "Error syncing backend: #{e.message}"
      end
    end
  end
end

def model_ready_on_all_backends?(model_name)
  return false unless Model.find_by(name: model_name)
  Backend.all.each do |backend|
    models = backend.models_from_backend
    model = models.find { |m| m['name'] == model_name }
    return false unless model
    return false unless model['ready']
  end
  true
end

require 'sinatra'

set :traps, false

# Configure ActiveRecord (using a local SQLite file)
#set :database, { adapter: 'sqlite3', database: './db/db.sqlite3' }
set :database, {
  adapter: 'mysql2',
  host: 'localhost',
  database: 'llamagw',
  username: 'llamagw',
  password: 'abc',
  pool: 150,
}


set :server, 'puma' # Tell Sinatra to use Puma
set :environment, :production
set :puma_config do
  {
    workers: 8,
    threads: [1, 1],
    environment: :production,
    workers_timeout: 1,
    queue_requests: false,
  }
end



return unless __FILE__ == $PROGRAM_NAME

load_config_into_db(config_file)

Thread.new do
  using Rainbow
  loop do
    puts "Updating backends" if $config["verbose"]
    Backend.all.each do |backend|
      previous_status = backend.available
      backend.sync_complete_state
      if previous_status && !backend.available
        puts "Backend #{backend.name} goes offline".bright.red
        backend.llama_instances.destroy_all
      elsif !previous_status && backend.available
        puts "Backend #{backend.name} becomes available".bright.green
        backend.post_model_list(Model.all)
      end
    end
    puts "Updating done" if $config["verbose"]
    sleep $config["update_interval"]
  end
end

Thread.new do
  loop do
    # any cleanup logic
    sleep 5
  end
end

before do
  response.headers['Access-Control-Allow-Origin'] = '*'
  response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD'
  response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Requested-With'
end

# Catch-all for preflight OPTIONS requests
options '*' do
  200
end

def list_models
  Model.all.map do |m|
    {
      id: m.id,
      name: m.name,
      created: m.created_at ? m.created_at.to_i : Time.now.to_i,
      updated: m.updated_at ? m.updated_at.to_i : Time.now.to_i,
      object: 'model',
      owned_by: 'organization',
      permission: []
    }
  end
end

def find_model(model_identifier)
  # Try to locate the model by name first
  model = Model.find_by(name: model_identifier)
  # If not found and the provided identifier is numeric, use it as an index (0-based)
  if model.nil? && model_identifier.to_s.strip.match?(/^\d+$/)
    index = model_identifier.to_i - 1
    model = Model.all.order(:name).to_a[index]
  end
  model
end

def pick_backend_for_new_instance(model)
  Backend.where(available: true).each do |backend|
    if backend.models_from_backend.any? { |m| m['name'] == model.name }
      return backend
    end
  end
  nil
end

def pick_gpus_for_new_instance(backend, model)
  needed_memory = model.est_memory_mb
  selected_gpus = []
  backend.gpus.sort_by(&:memory_free).reverse.select do |gpu|
    if needed_memory > 0
      selected_gpus << gpu
      needed_memory -= gpu.memory_free
      puts "GPU #{gpu.vendor_index} on #{backend.name} selected".bright.green
    end
  end
  if needed_memory > 0
    return [[], 'Not enough memory on available GPUs']
  end
  [selected_gpus, nil]
end

def allocate_new_instance(model)
  backend = pick_backend_for_new_instance(model)
  return [nil, 'No available backends'] unless backend

  gpus, msg = pick_gpus_for_new_instance(backend, model)
  return [nil, msg] if gpus.empty?

  new_inst = LlamaInstance.new(
    model: model,
    backend: backend,
    gpus: gpus
  )

  return [nil, 'Failed while creating new instance of model'] if new_inst.nil?

  new_inst.wait_loaded

  return [nil, 'Failed while launching new instance of model'] unless new_inst.ready?

  [new_inst, nil]
end

def acquire_instance_slot(model)
  backend = Backend.where(available: true).first
  return [nil, 'No available backends'] unless backend

  instance_data = nil
  LlamaInstance.joins(:backend).
                where(model: model,
                      backend: { id: backend.id, available: true }).each do |instance|
    puts "Instance for model #{model.name} on instance #{backend.name}.#{instance.name} is evaluated".bright.green if $config['verbose']
    instance.ensure_loaded
    if !instance.ready?
      next
    end

    if instance.slots_free <= 0
      puts "Instance for model #{model.name} on instance #{backend.name}.#{instance.name} has no free slots, next".bright.red
      next
    end

    if slot = instance.occupy_slot
      puts "Slot #{slot.slot_number} acquired for model #{model.name} on instance #{backend.name}.#{instance.name}".bright.green
      instance_data = {instance: instance, slot: slot}
      break
    else
      puts "Failed to acquire slot for model #{model.name} on instance #{backend.name}.#{instance.name}".bright.red
      next
    end
  end

  if instance_data.nil?
    new_inst, msg = allocate_new_instance(model)
    if new_inst.nil?
      return [nil, msg]
    end

    new_inst.wait_loaded

    return [nil, 'Failed while launching new instance of model'] unless new_inst.ready?

    puts "Instance for model #{model.name} on instance #{backend.name}.#{new_inst.name} is active".bright.green

    if slot = new_inst.occupy_slot
      puts "Slot acquired for model #{model.name} on instance #{backend.name}.#{new_inst.name}".bright.green
      instance_data = {instance: new_inst, slot: slot}
    else
      return [nil, 'No usable instance or backend']
    end
  end
  [instance_data, nil]
end

def process_request(route)
  request_data = JSON.parse(request.body.read)
  model_identifier = request_data['model']

  model = find_model(model_identifier)
  halt 404, { error: 'Model not found' }.to_json unless model

  puts "Looking for available backend for model #{model.name}".bright.magenta if $config['verbose']
  instance_data, error = acquire_instance_slot(model)

  if error
    puts error.bright.red
    halt 503, { error: error }.to_json
  end

  http, req, uri = forward_request(instance_data, route, request_data)
  stream_response(http, req, instance_data)
rescue => e
  puts Rainbow(e.message).bright.red
  puts e.backtrace
  if instance_data && instance_data[:instance] && instance_data[:slot]
    instance_data[:slot].release
  end
  halt 500, { error: e.message }.to_json
end

def forward_request(instance_data, route, request_data)
  uri = URI.parse("#{instance_data[:instance].backend.url}#{route}")
  uri.port = instance_data[:instance].port

  puts "Forwarding request to #{uri}".bright.magenta
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
  req_body = request_data.merge({
    'id_slot' => instance_data[:slot].slot_number,
  })
  req_body.delete('model')
  req.body = req_body.to_json
  [http, req, uri]
end

def stream_response(http, req, instance_data)
  stream do |out|
    begin
      http.request(req) do |res|
        # Forward status and headers (if needed)
        status res.code.to_i
        headers res.to_hash.transform_values(&:first)
        res.read_body do |chunk|
          out << chunk
        end
      end
    rescue => e
      out <<({ error: e.message }.to_json)
    ensure
      # Ensure the slot is released once streaming ends
      instance_data[:slot].release if instance_data && instance_data[:slot]
      puts "Slot #{instance_data[:slot].slot_number} released for model #{instance_data[:instance].model.name} on backend #{instance_data[:instance].backend.name}".bright.green
    end
  end
end

# OpenAI-like routes (nested under /v1)
get '/v1/models' do
  { data: list_models }.to_json
end

options '/v1/models' do
  { data: list_models }.to_json
end

post '/v1/*' do
  process_request(request.path_info)
end

# Ollama-specific routes
get '/api/tags' do
  # TODO: Implement listing of available models in Ollama format
  # This should return a JSON array of model tags.
  # Example: [{"name":"llama2", "modified_at": "...", "size": 1234567890}]
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/pull' do
  # TODO: Implement pulling a model from a remote source.
  # This might involve downloading the model and making it available.
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/create' do
  # TODO: Implement creating a model.  This likely involves
  # taking a name and FROM instructions to build a new model
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/chat' do
    # This is the main chat completion endpoint, similar to OpenAI's /v1/chat/completions
    # It should accept a request with messages and return a streaming response
    # that yields deltas.
    # The request body will look something like this:
    # {
    #   "model": "llama2",
    #   "messages": [
    #     {"role": "user", "content": "Why is the sky blue?"}
    #   ],
    #   "stream": true
    # }
    # The response should be a series of JSON objects, one per chunk, like this:
    # {
    #   "model": "llama2",
    #   "created_at": "2023-08-04T17:52:35.410901Z",
    #   "message": {"role": "assistant", "content": "The sky is blue because..."},
    #   "done": false
    # }
    # The final chunk should have "done": true.
    # You'll need to adapt the existing proxy logic to handle this format.
    route = '/v1/chat/completions'
    process_request(route)
end

post '/api/embeddings' do
  # TODO: Implement embeddings generation.
  # This endpoint should accept a request with input text and return embeddings.
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/generate' do
  # TODO: Implement generate completion.
  # This endpoint should accept a request with prompt and return completion.
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/show' do
  # TODO: Implement show model info.
  # This endpoint should accept a request with model name and return model information.
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/copy' do
  # TODO: Implement copy model.
  # This endpoint should accept a request with source and destination model names and copy the model.
  halt 501, { error: 'Not Implemented' }.to_json
end

delete '/api/delete' do
  # TODO: Implement delete model.
  # This endpoint should accept a request with model name and delete the model.
  halt 501, { error: 'Not Implemented' }.to_json
end

post '/api/push' do
  # TODO: Implement push model.
  # This endpoint should accept a request with model name and push the model to a remote registry.
  halt 501, { error: 'Not Implemented' }.to_json
end

get '/api/list' do
  # TODO: Implement list local models.
  # This endpoint should return a list of local models.
  halt 501, { error: 'Not Implemented' }.to_json
end

get '/api/health' do
  # TODO: Implement health check.
  # This endpoint should return the health status of the server.
  halt 501, { error: 'Not Implemented' }.to_json
end

# Pass any POST route along
post '/api/*' do
  route = request.path_info
  # strip the /api prefix
  route = route[4..-1]
  process_request()
end

require_relative 'lib/ui'

get '/favicon.ico' do
  content_type 'image/svg+xml'
  <<-SVG
  <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
    <!-- Gate posts -->
    <rect x="10" y="16" width="4" height="32" fill="black" />
    <rect x="50" y="16" width="4" height="32" fill="black" />
    <!-- Gate bar -->
    <rect x="10" y="32" width="44" height="4" fill="black" />
    <!-- Llama face: Eyes -->
    <circle cx="22" cy="20" r="2" fill="black" />
    <circle cx="42" cy="20" r="2" fill="black" />
    <!-- Llama face: Mouth -->
    <line x1="26" y1="40" x2="38" y2="40" stroke="black" stroke-width="2" />
  </svg>
  SVG
end
