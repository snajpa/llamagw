# models/backend.cr
require "jennifer"
require "http/client"
require "json"

class Backend < Jennifer::Model::Base
  table :backends
  with_timestamps

  mapping(
    id: Primary32,
    name: String?,
    url: String?,
    models_json: String?,
    available: Bool?,
    last_seen_at: Time?,
    created_at: Time?,
    updated_at: Time?
  )

  has_many llama_instances : LlamaInstance, foreign_key: "backend_id"
  has_many gpus : Gpu, foreign_key: "backend_id"

  def models_from_backend : JSON::Any
    return JSON.parse(models_json.not_nil!) rescue JSON.parse("{}")
  end

  def models_from_backend=(val : JSON::Type)
    self.models_json = val.to_json
  end

  def get(path : String, params = {} of String => String) : JSON::Any | Nil
    begin
      full = "#{self.url}/#{path}"
      uri  = URI.parse(full)
      unless params.empty?
        uri.query = URI.encode_www_form(params)
      end
      response = HTTP::Client.get(uri)
      JSON.parse(response.body)
    rescue ex
      puts "Error in GET(#{full}): #{ex.message}"
      nil
    end
  end

  def post(path : String, json_payload : JSON::Type) : JSON::Any | Nil
    begin
      full = "#{self.url}/#{path}"
      response = HTTP::Client.post(full,
        headers: {"Content-Type" => "application/json"},
        body: json_payload.to_json
      )
      JSON.parse(response.body)
    rescue ex
      puts "Error in POST(#{full}): #{ex.message}"
      nil
    end
  end

  def post_model_list(models : Array(Model))
    to_send = models.map(&.config)
    resp = post("models", to_send)
    return false unless resp
    true
  end

  def sync_complete_state
    sync_models
    return unless self.available?
    sync_gpus
    sync_instances
  end

  def sync_models
    response = get("models")
    if response.nil? || (response.as_h? && response.as_h.has_key?("error"))
      self.available = false
      self.save
      return
    end
    self.models_from_backend = response
    self.available = true
    self.last_seen_at = Time.now
    self.save
  end

  def sync_gpus
    response = get("gpus")
    if response.nil? || (response.as_h? && response.as_h.has_key?("error"))
      self.available = false
      self.save
      return
    end

    current_ids = [] of Int32
    response.as_a.each_with_index do |gpu_data, idx|
      gpu = Gpu.query.where do
        backend_id == self.id && index == idx
      end.first

      if gpu.nil?
        gpu = Gpu.new
        gpu.backend_id = self.id.not_nil!
        gpu.index = idx
      end

      gpu.vendor_index  = gpu_data["vendor_index"].as_i
      gpu.vendor        = gpu_data["vendor"].as_s
      gpu.model         = gpu_data["model"].as_s
      gpu.memory_total  = gpu_data["memory_total"].as_i
      gpu.memory_free   = gpu_data["memory_free"].as_i
      gpu.compute_usage = gpu_data["compute_usage"].as_i?
      gpu.membw_usage   = gpu_data["membw_usage"].as_i?
      gpu.power_usage   = gpu_data["power_usage"].as_i?
      gpu.temperature   = gpu_data["temperature"].as_i?
      gpu.save

      current_ids << gpu.id.not_nil!
    end

    # Clean out old GPUs
    Gpu.query.where do
      backend_id == self.id && id.not_in(current_ids)
    end.delete_all

    self.available = true
    self.last_seen_at = Time.now
    self.save
  end

  def sync_instances
    response = get("instances")
    if response.nil? || (response.as_h? && response.as_h.has_key?("error"))
      self.available = false
      self.save
      return
    end

    current_ids = [] of Int32
    response.as_a.each do |inst_data|
      puts "Processing instance #{inst_data["name"]} on #{self.name}"
      model_name = inst_data["model"].as_s
      model = Model.query.where { name == model_name }.first
      unless model
        next
      end

      instance = LlamaInstance.query.where do
        backend_id == self.id && name == inst_data["name"].as_s
      end.first

      unless instance
        instance = LlamaInstance.new
        instance.backend_id = self.id.not_nil!
        instance.model_id   = model.id.not_nil!
        instance.name       = inst_data["name"].as_s
        instance.port       = inst_data["port"].as_i?
        instance.save
      end

      instance.update_status(inst_data.as_h)
      current_ids << instance.id.not_nil!

      if inst_data["slots_capacity"]?
        cap = inst_data["slots_capacity"].as_i
        (0...cap).each do |i|
          slot = LlamaInstanceSlot.query.where do
            llama_instance_id == instance.id && slot_number == i
          end.first
          unless slot
            slot = LlamaInstanceSlot.new
            slot.llama_instance_id = instance.id.not_nil!
            slot.model_id = model.id.not_nil!
            slot.slot_number = i
            slot.occupied = false
            slot.save
          end
        end
      end
    end

    # Remove old instances
    LlamaInstance.query.where do
      backend_id == self.id && id.not_in(current_ids)
    end.delete_all

    LlamaInstanceSlot.query.where do
      llama_instance_id.not_in(current_ids)
    end.delete_all

    self.available = true
    self.last_seen_at = Time.now
    self.save
  end
end
