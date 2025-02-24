class LlamaInstance < ActiveRecord::Base
  belongs_to :backend
  belongs_to :model
  has_many :llama_instance_slots, dependent: :destroy
  has_and_belongs_to_many :gpus

  after_initialize :setup

  def setup
    model_config = self.model.config
    if self.slots_capacity.nil?
      self.slots_capacity = model_config['slots']
    end
    unless self.name
      self.name = "#{self.model.name}-#{Time.now.to_i}"
    end
    if self.running
      return save
    end
    self.active = false
    self.running = true
    self.loaded = false
    save
    #puts Rainbow(caller).bright.red
  
    puts Rainbow("Launching instance #{self.name} on #{self.backend.name}").bright.magenta  if $config['verbose']
    response = self.backend.post('instances', {
      name: self.name,
      model: self.model.name,
      gpus: self.gpus.map(&:vendor_index),
    })
  
    if response.nil? || response.include?('error')
      puts Rainbow("Instance #{self.name} on #{self.backend.name} failed to launch").bright.red
      self.running = false
      save
      return
    end

    puts Rainbow("Model #{model.name} launched on #{self.backend.name}").bright.green if $config['verbose']
    self.port = response['port']
    self.active = true
    self.running = true
    self.loaded = false
    save
    instance = self
    self.slots_capacity.times do |i|
      slot = LlamaInstanceSlot.find_or_create_by!(
        llama_instance: instance,
        slot_number: i,
        model: instance.model,
      )
      slot.occupied = false
      slot.save
    end
  end

  def ready?
    self.backend.available && self.active && self.running && self.loaded
  end

  def update_status(response = nil)
    puts Rainbow("Updating status for instance #{self.name} on #{self.backend.name}").bright.magenta if $config['verbose']
    response = self.backend.get("instances/#{self.name}") unless response
    if response.nil?
      puts Rainbow("Instance #{self.name} on #{self.backend.name} is not available").bright.red
      self.active = false
      return save
    elsif response['error']
      puts Rainbow("Instance #{self.name} on #{self.backend.name} returned an error: #{response['error']}").bright.red
      self.active = false
      self.running = false
      self.loaded = false
      return save
    end

    self.loaded = !!response['loaded']
    self.running = !!response['running']
    self.active = true
    puts Rainbow("Instance #{self.name} on #{self.backend.name} is loaded: #{self.loaded}, running: #{self.running}").bright if $config['verbose']
    save    
  end

  def wait_loaded(i = $config["instance_timeout"])
    i.times do
      if ready?
        break
      end
      sleep 1
    end
    self.loaded
  end

  def ensure_loaded
    return true if ready?
    return false if !self.backend.available

    puts Rainbow("Instance #{self.name} on #{self.backend.name} is not ready, waiting").bright.red
    setup if !self.running
    wait_loaded
  end

  def slots_free
    self.llama_instance_slots.where(llama_instance: self, occupied: false).count
  end

  def occupy_slot
    slot = nil
    begin
      transaction do
        reload
        slot = LlamaInstanceSlot.find_by(llama_instance: self, occupied: false)
        if slot.nil?
          raise ActiveRecord::Rollback
        end

        slot.update(occupied: true)
        save
      end
    rescue => e
    end
    slot
  end

  def shutdown
    begin
      response = self.backend.get("instances/#{self.name}", _method: 'DELETE')
      return !!response
    rescue => e
      puts e.message
      puts e.backtrace
      false
    ensure
      destroy
    end
  end
end