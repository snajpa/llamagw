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
  model_name = request_data['model']
  model = Model.find_by(name: model_name)
  halt 404, { error: 'Model not found' }.to_json unless model

  instance_data = nil
  backend = nil
  abort = false

  #ActiveRecord::Base.transaction do
  #  ActiveRecord::Base.after_rollback do
  #    abort = true
  #  end
  
  puts "Looking for available backend for model #{model_name}".bright.magenta
  backend = Backend.where(available: true).first
  if backend.nil?
    puts "No available backends found for model #{model_name}".bright.red
    halt 503, { error: 'No available backends' }.to_json
  end
  #halt 503, { error: 'No available backends' }.to_json

  puts "Acquiring instance for model #{model_name} on backend #{backend.name}".bright.magenta
  instance_data = nil
  LlamaInstance.joins(:backend).
                where(model: model,
                      backend: { id: backend.id, available: true }).each do |instance|
    puts "Instance for model #{model_name} on instance #{backend.name}.#{instance.name} is evaluated".bright.green
    instance.ensure_loaded
    if !instance.ready?
      next
    end

    if instance.slots_free <= 0
      puts "Instance for model #{model_name} on instance #{backend.name}.#{instance.name} has no free slots, next".bright.red
      next
    end

    if slot = instance.occupy_slot
      puts "Slot #{slot.slot_number} acquired for model #{model_name} on instance #{backend.name}.#{instance.name}".bright.green
      instance_data = {instance: instance, slot: slot}
      break
    else
      puts "Failed to acquire slot for model #{model_name} on instance #{backend.name}.#{instance.name}".bright.red
      next
    end
  end

  if abort
    puts "Transaction aborted".bright.red
    halt 503, { error: 'Transaction aborted' }.to_json
  end

  if instance_data.nil?
    #ActiveRecord::Base.transaction do
    #  ActiveRecord::Base.after_rollback do
    #    abort = true
    #  end

    puts "Creating new instance for model #{model_name} on backend #{backend.name}, free mem: #{(backend.available_gpu_memory/1024).round(2)} GB".bright.magenta
    new_inst = LlamaInstance.new(
      model: model,
      backend: backend,
      gpus: []
    )

    if new_inst.nil?
      puts "Failed to cre.;z< q=ate new instance for model #{model_name} on instance #{backend.name}.#{new_inst.name}".bright.red
      halt 503, { error: 'Failed while creating new instance of model' }.to_json
    end

    new_inst.wait_loaded

    unless new_inst.ready?
      puts "Failed to launch new instance for model #{model_name} on instance #{backend.name}.#{new_inst.name}".bright.red
      halt 503, { error: 'Failed while launching new instance of model' }.to_json
    end

    puts "Instance for model #{model_name} on instance #{backend.name}.#{new_inst.name} is active".bright.green

    if slot = new_inst.occupy_slot
      puts "Slot acquired for model #{model_name} on instance #{backend.name}.#{new_inst.name}".bright.green
      instance_data = {instance: new_inst, slot: slot}
    else
      puts "Failed to acquire slot for model #{model_name} on instance #{backend.name}.#{new_inst.name}".bright.red
      halt 503, { error: 'No usable instance or backend' }.to_json
    end
  end
  
  if abort
    puts "Transaction aborted".bright.red
    halt 503, { error: 'Transaction aborted' }.to_json
  end
  
  uri = URI.parse("#{instance_data[:instance].backend.url}#{route}")
  uri.port = instance_data[:instance].port

  puts "Forwarding request to #{uri}".bright.magenta
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
  req.body = request_data.merge({
    'id_slot' => instance_data[:slot].slot_number,
  }).to_json
  response = http.request(req)
  result = response.body

  if instance_data && instance_data[:instance] && instance_data[:slot]
    instance_data[:slot].release
  end
  puts "Slot #{instance_data[:slot].slot_number} released for model #{instance_data[:instance].model.name} on backend #{instance_data[:instance].backend.name}".bright.green

  result
rescue => e
  puts Rainbow(e.message).bright.red
  puts e.backtrace
  if instance_data && instance_data[:instance] && instance_data[:slot]
    instance_data[:slot].release
  end
  halt 500, { error: e.message }.to_json
end

require_relative 'lib/ui'