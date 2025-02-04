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
#require 'sinatra/reloader' if true

require_relative 'models/model'
require_relative 'models/backend'
require_relative 'models/gpu'
require_relative 'models/llama_instance'  

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
$config[:update_interval] ||= 60

def load_config_into_db(config_file)
  ActiveRecord::Base.transaction do
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
          backend.sync_complete_state
          backend.post_model_list(Model.all)
        rescue => e
          puts "Error syncing backend: #{e.message}"
        end
      end
    end
  end
end

def model_ready_on_all_backends?(model_name)
  return false unless Model.find_by(name: model_name)
  Backend.all.each do |backend|
    return false unless
      backend.models_from_backend.include?(model_name) &&
      backend.models_from_backend[model_name]['ready'] &&
      backend.available
  end
  true
end

# Acquire an instance
def acquire_slot(model_name)
  model = Model.find_by(name: model_name)
  return nil unless model

  puts "Looking for available backend for model #{model_name}"
  backend = Backend.where(available: true).first
  return nil unless backend

  puts "Acquiring instance for model #{model_name} on backend #{backend.name}"
  
  LlamaInstance.where(model: model, backend: backend, cached_active: true).each do |instance|
    if slot = instance.occupy_slot
      return {instance: instance, slot: slot}
    end
  end
  
  # No available slots found, create new instance
  puts "Creating new instance for model #{model_name} on backend #{backend.name}"
  new_inst = LlamaInstance.new(
    model: model,
    backend: backend,
    gpus: []
  )

  if new_inst.nil?
    puts "Failed to create new instance for model #{model_name} on backend #{backend.name}"
    return nil
  end
  
  new_inst.launch

  if new_inst.cached_active
    puts "Instance for model #{model_name} on backend #{backend.name} is active"
  else
    puts "Instance for model #{model_name} on backend #{backend.name} is not active"
    return nil
  end
  if slot = new_inst.occupy_slot
    puts "Slot acquired for model #{model_name} on backend #{backend.name}"
    return {instance: new_inst, slot: slot}
  end
  puts "Failed to acquire slot for model #{model_name} on backend #{backend.name}"
  nil
end

# Release an instance
def release_slot(instance_data)
  return unless instance_data && instance_data[:instance] && instance_data[:slot]
  instance_data[:instance].release_slot(instance_data[:slot])
end

# Route the request
def route_request(request_data, route)
  model_name = request_data['model']
  instance_data = acquire_slot(model_name)
  halt 503, { error: 'No usable instance or backend' }.to_json if instance_data.nil?

  uri = URI.parse("#{instance_data[:instance].backend.url}#{route}")
  uri.port = instance_data[:instance].port

  puts "Forwarding request to #{uri}"
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
    Backend.all.each do |backend|
      previous_status = backend.available
      backend.update_status
      if !previous_status && backend.available && backend.updated_at > $config[:update_interval].second.ago
        backend.post_model_list(Model.all)
      end
    end
    sleep $config[:update_interval]
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