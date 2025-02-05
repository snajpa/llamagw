#!/usr/bin/env ruby
require 'sqlite3'
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
  opts.banner = "Usage: server-frontend-ar.rb [options]"
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

def load_config_into_db(config_file)
  # Update models while preserving existing records
  if $config['models']
    $config['models'].each do |model_conf|
      model = Model.find_or_initialize_by(name: model_conf['name'])
      model.config = model_conf
      model.save!
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

# Acquire an instance
def acquire_slot(model_name)
  model = Model.find_by(name: model_name)
  return nil unless model

  puts "Looking for available backend for model #{model_name}".bright.magenta
  backend = Backend.where(available: true).first
  if backend.nil?
    puts "No available backends found for model #{model_name}".bright.red
    return nil
  end

  puts "Acquiring instance for model #{model_name} on backend #{backend.name}".bright.magenta
  
  LlamaInstance.joins(:backend).
                where(model: model,
                      backend: { id: backend.id, available: true }).each do |instance|
    puts "Instance for model #{model_name} on backend #{backend.name} is evaluated".bright.green
    instance.ensure_loaded(5)
    unless instance.ready?
      puts "Instance for model #{model_name} on backend #{backend.name} is not ready, next".bright.red
      next
    end

    slot = instance.occupy_slot
    unless slot.nil?
      puts "Slot #{slot.slot_number} acquired for model #{model_name} on backend #{backend.name}".bright.green
      return {instance: instance, slot: slot}
    end
    puts "Failed to acquire slot for model #{model_name} on backend #{backend.name}".bright.red
  end
  
  # No available slots found, create new instance
  puts "Creating new instance for model #{model_name} on backend #{backend.name}".bright.magenta
  new_inst = LlamaInstance.new(
    model: model,
    backend: backend,
    gpus: []
  )

  if new_inst.nil?
    puts "Failed to create new instance for model #{model_name} on backend #{backend.name}".bright.red
    return nil
  end

  new_inst.wait_loaded

  unless new_inst.ready?
    puts "Failed to launch new instance for model #{model_name} on backend #{backend.name}".bright.red
    return nil
  end

  puts "Instance for model #{model_name} on backend #{backend.name} is active".bright.green

  if slot = new_inst.occupy_slot
    puts "Slot acquired for model #{model_name} on backend #{backend.name}".bright.green
    return {instance: new_inst, slot: slot}
  end
  puts "Failed to acquire slot for model #{model_name} on backend #{backend.name}".bright.red
  nil
end

# Release an instance
def release_slot(instance_data)
  return unless instance_data && instance_data[:instance] && instance_data[:slot]
  instance_data[:instance].release_slot(instance_data[:slot])
  puts "Slot released for model #{instance_data[:instance].model.name} on backend #{instance_data[:instance].backend.name}".bright.green
end

# Route the request
def route_request(request_data, route)
  model_name = request_data['model']
  instance_data = acquire_slot(model_name)
  halt 503, { error: 'No usable instance or backend' }.to_json if instance_data.nil?

  uri = URI.parse("#{instance_data[:instance].backend.url}#{route}")
  uri.port = instance_data[:instance].port

  puts "Forwarding request to #{uri}".bright.magenta
  result = forward_request(uri, request_data)

  release_slot(instance_data)
  result
end

def forward_request(uri, request_data)
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
  req.body = request_data.to_json
  response = http.request(req)
  response.body
end

require 'sinatra'

set :traps, false

# Configure ActiveRecord (using a local SQLite file)
set :database, { adapter: 'sqlite3', database: './db/db.sqlite3' }

return unless __FILE__ == $PROGRAM_NAME

load_config_into_db(config_file)

Thread.new do
  loop do
    puts "Updating backends"
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
    puts "Updating done"
    sleep $config["update_interval"]
  end
end

Thread.new do
  loop do
    # any cleanup logic
    sleep 5
  end
end

# Model listing
get '/v1/models' do
  models = Model.all.map do |m|
    {
      id: m.name,
      object: 'model',
      created: Time.now.to_i,
      owned_by: 'organization',
      permission: []
    }
  end
  { data: models }.to_json
end

# Pass any POST route along
post '/*' do
  request_data = JSON.parse(request.body.read)
  route = request.path_info
  route_request(request_data, route)
end

require_relative 'lib/ui'