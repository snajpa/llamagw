#!/usr/bin/env crystal

require "yaml"
require "json"
require "http/client"
require "uri"
require "option_parser"
require "kemal"

require "jennifer"
require "jennifer/adapter/mysql"

# Require model files
require_relative "models/model"
require_relative "models/backend"
require_relative "models/gpu"
require_relative "models/llama_instance"
require_relative "models/llama_instance_slot"

# Simple HTML UI
require_relative "lib/ui"

# -----------------------------------------------------------------------------
# Load config from config-frontend.yml
# -----------------------------------------------------------------------------
CONFIG_FILE = "./config-frontend.yml"

$config = Hash(String, JSON::Type).new

OptionParser.parse! do |parser|
  parser.banner = "Usage: server-frontend.cr [options]"
  parser.on("-c FILE", "--config=FILE", "Path to config file") do |file|
    # Overwrite if user passes `-c something.yml`
    $config["config_file"] = file
  end
end

# If user gave `-c`, override
if $config["config_file"]?
  config_file = $config["config_file"].as_s
else
  config_file = CONFIG_FILE
end

begin
  raw_yaml   = File.read(config_file)
  parsed_yaml= YAML.parse(raw_yaml).as_h
  parsed_json= JSON.parse(parsed_yaml.to_json).as_h
  $config    = parsed_json
rescue ex
  puts "Failed to load config file #{config_file}: #{ex.message}"
  exit 1
end

# Grab DB config from $config
db_conf = $config["database"].as_h
Jennifer::Config.configure do |conf|
  conf.adapter  = db_conf["adapter"].as_s      # "mysql"
  conf.host     = db_conf["host"].as_s         # "localhost"
  conf.database = db_conf["name"].as_s         # "llamagw"
  conf.user     = db_conf["user"].as_s         # "llamagw"
  conf.password = db_conf["password"].as_s     # "abc"
  conf.pool     = db_conf["pool"]?.as_i || 150
end

# Default update_interval if not given
$config["update_interval"] ||= 60

# -----------------------------------------------------------------------------
# DB seed-like methods
# -----------------------------------------------------------------------------
def load_config_into_db
  # 1) Update Models from $config["models"]
  if $config.has_key?("models")
    $config["models"].as_a.each do |model_conf|
      name = model_conf["name"].as_s
      model = Model.query.where { name == name }.first
      unless model
        model = Model.new
        model.name = name
      end
      model.config = model_conf.as_h
      model.save
    end
  end

  # 2) Update Backends from $config["backends"]
  if $config.has_key?("backends")
    $config["backends"].as_a.each do |backend_conf|
      name = backend_conf["name"].as_s
      url  = backend_conf["url"].as_s

      backend = Backend.query.where { name == name }.first
      unless backend
        backend = Backend.new
        backend.name = name
      end
      backend.url = url
      backend.save

      begin
        backend.post_model_list(Model.all.to_a)
        backend.sync_complete_state
      rescue ex
        puts "Error syncing backend #{name}: #{ex.message}"
      end
    end
  end
end

def model_ready_on_all_backends?(model_name : String) : Bool
  model = Model.query.where { name == model_name }.first
  return false unless model

  Backend.all.each do |backend|
    arr = backend.models_from_backend.try(&.as_a) || [] of JSON::Any
    found = arr.find { |m| m["name"].as_s == model_name }
    unless found && found["ready"].as_bool
      return false
    end
  end
  true
end

# -----------------------------------------------------------------------------
# Load config into DB
# -----------------------------------------------------------------------------
load_config_into_db

# -----------------------------------------------------------------------------
# Background tasks
# -----------------------------------------------------------------------------
spawn do
  loop do
    puts "Updating backends..."
    Backend.all.each do |backend|
      previous_status = backend.available?
      backend.sync_complete_state
      if previous_status && !backend.available?
        puts "Backend #{backend.name} goes offline"
        # remove all LlamaInstances for this backend
        LlamaInstance.query.where { backend_id == backend.id }.delete_all
      elsif !previous_status && backend.available?
        puts "Backend #{backend.name} becomes available"
        backend.post_model_list(Model.all.to_a)
      end
    end
    puts "Updating done."
    sleep $config["update_interval"].as_i.seconds
  end
end

spawn do
  loop do
    # any cleanup logic
    sleep 5.seconds
  end
end

# -----------------------------------------------------------------------------
# Kemal Routes
# -----------------------------------------------------------------------------

# GET /v1/models
get "/v1/models" do |env|
  models = Model.all.map do |m|
    {
      "id"        => m.name,
      "object"    => "model",
      "created"   => Time.now.to_unix,
      "owned_by"  => "organization",
      "permission"=> [] of String
    }
  end
  env.response.content_type = "application/json"
  {"data" => models}.to_json
end

# POST /*
post "/*" do |env|
  begin
    body_str = env.request.body.not_nil!
    request_data = JSON.parse(body_str).as_h
    route = env.request.path.not_nil!

    model_name = request_data["model"].as_s?
    unless model_name
      env.response.status_code = 404
      return %({"error":"Model not found in request"})
    end

    model = Model.query.where { name == model_name }.first
    unless model
      env.response.status_code = 404
      return %({"error":"Model not found in DB"})
    end

    puts "Looking for available backend for model #{model_name}"
    backend = Backend.query.where { available == true }.first
    unless backend
      env.response.status_code = 503
      return %({"error":"No available backends"})
    end

    instance_data = nil

    # Try existing instances
    LlamaInstance.query.includes(:backend).where do
      model_id == model.id && backend_id == backend.id && backend.available == true
    end.each do |instance|
      instance.ensure_loaded
      next unless instance.ready?
      if instance.slots_free <= 0
        next
      end
      slot = instance.occupy_slot
      if slot
        instance_data = {"instance" => instance, "slot" => slot}
        break
      end
    end

    # Create a new instance if none found
    if instance_data.nil?
      puts "Creating new instance for model #{model_name} on backend #{backend.name}"
      new_inst = LlamaInstance.new
      new_inst.backend_id = backend.id.not_nil!
      new_inst.model_id   = model.id.not_nil!
      new_inst.save
      new_inst.setup

      if new_inst.nil?
        env.response.status_code = 503
        return %({"error":"Failed while creating new instance of model"})
      end

      new_inst.wait_loaded
      unless new_inst.ready?
        env.response.status_code = 503
        return %({"error":"Failed while launching new instance of model"})
      end

      slot = new_inst.occupy_slot
      unless slot
        env.response.status_code = 503
        return %({"error":"No usable instance or backend"})
      end

      instance_data = {"instance" => new_inst, "slot" => slot}
    end

    inst = instance_data["instance"] as LlamaInstance
    slot = instance_data["slot"] as LlamaInstanceSlot

    # Forward request to the backend
    target_url = "#{inst.backend.url}:#{inst.port}#{route}"
    forward_body = request_data.dup
    forward_body["id_slot"] = slot.slot_number

    forward_res = HTTP::Client.post(
      target_url,
      headers: {"Content-Type" => "application/json"},
      body: forward_body.to_json
    )

    result = forward_res.body

    # release slot
    slot.release

    env.response.content_type = "application/json"
    result
  rescue ex
    puts "Error: #{ex.message}"
    env.response.status_code = 500
    %({"error":"#{ex.message}"})
  end
end

# The "root" route => see `lib/ui.cr` for the HTML rendering
get "/" do |env|
  env.response.content_type = "text/html"
  render_ui
end

# -----------------------------------------------------------------------------
# Launch server
# -----------------------------------------------------------------------------
Kemal.run
