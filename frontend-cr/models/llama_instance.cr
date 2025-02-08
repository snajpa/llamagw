# models/llama_instance.cr
require "jennifer"
require_relative "llama_instance_slot"

class LlamaInstance < Jennifer::Model::Base
  table :llama_instances
  with_timestamps

  mapping(
    id: Primary32,
    backend_id: Int32,
    model_id: Int32,
    name: String?,
    slots_capacity: Int32?,
    slots_free: Int32?,
    port: Int32?,
    running: Bool?,
    loaded: Bool?,
    active: Bool?,
    created_at: Time?,
    updated_at: Time?
  )

  belongs_to backend : Backend, foreign_key: "backend_id"
  belongs_to model   : Model,   foreign_key: "model_id"
  has_many   llama_instance_slots : LlamaInstanceSlot, foreign_key: "llama_instance_id"

  def setup
    model_conf = self.model.not_nil!.config
    if self.slots_capacity.nil?
      self.slots_capacity = model_conf["slots"]?.as_i || 1
    end

    unless self.name
      self.name = "#{self.model.not_nil!.name}-#{Time.now.to_unix}"
    end

    if self.running?
      self.save
      return
    end

    self.active  = false
    self.running = true
    self.loaded  = false
    self.save

    puts "Launching instance #{self.name} on #{self.backend.not_nil!.name}"
    response = self.backend.not_nil!.post("instances", {
      "name" => self.name,
      "model"=> self.model.not_nil!.name,
      "gpus" => [] of Int32
    })

    if response.nil? || (response.as_h? && response.as_h.has_key?("error"))
      puts "Instance #{self.name} on #{self.backend.not_nil!.name} failed to launch"
      self.running = false
      self.save
      return
    end

    self.port   = response.as_h["port"].as_i
    self.active = true
    self.loaded = false
    self.running= true
    self.save

    # Create the slots
    if self.slots_capacity
      (0...self.slots_capacity).each do |i|
        slot = LlamaInstanceSlot.query.where do
          llama_instance_id == self.id && slot_number == i
        end.first

        unless slot
          slot = LlamaInstanceSlot.new
          slot.llama_instance_id = self.id.not_nil!
          slot.model_id = self.model_id
          slot.slot_number = i
          slot.occupied = false
          slot.save
        end
      end
    end
  end

  def ready? : Bool
    !!(self.backend.available? && self.active? && self.running? && self.loaded?)
  end

  def update_status(response : Hash(String, JSON::Any)? = nil)
    puts "Updating status for instance #{self.name} on #{self.backend.not_nil!.name}"
    unless response
      instance_info = self.backend.not_nil!.get("instances/#{self.name}")
      if instance_info
        response = instance_info.as_h
      end
    end

    if response.nil?
      puts "Instance #{self.name} not available"
      self.active = false
      self.save
      return
    end
    if response.has_key?("error")
      puts "Instance #{self.name} returned error: #{response["error"].as_s}"
      self.active  = false
      self.running = false
      self.loaded  = false
      self.save
      return
    end

    self.loaded  = response["loaded"].as_bool
    self.running = response["running"].as_bool
    self.active  = true
    self.save
  end

  def wait_loaded(timeout = 300)
    timeout.times do
      self.reload
      break if ready?
      sleep 1.second
    end
    self.loaded?
  end

  def ensure_loaded(timeout = 300) : Bool
    return true if ready?
    return false unless self.backend.not_nil!.available?

    puts "Instance #{self.name} on #{self.backend.not_nil!.name} not ready, waiting"
    self.setup unless self.running?
    self.wait_loaded(timeout)
  end

  def slots_free : Int32
    LlamaInstanceSlot.query.where do
      llama_instance_id == self.id && occupied == false
    end.count
  end

  def occupy_slot : LlamaInstanceSlot?
    slot = nil
    Jennifer::Model::Base.transaction do |tx|
      self.reload
      slot = LlamaInstanceSlot.query.where do
        llama_instance_id == self.id && occupied == false
      end.first
      if slot.nil?
        tx.rollback
        return nil
      end
      slot.occupied = true
      slot.save
      self.save
    end
    slot
  end

  def shutdown : Bool
    begin
      resp = self.backend.not_nil!.get("instances/#{self.name}", {"_method" => "DELETE"})
      self.delete
      resp != nil
    rescue ex
      puts ex.message
      false
    end
  end
end
