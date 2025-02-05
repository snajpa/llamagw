class LlamaInstance < ActiveRecord::Base
  belongs_to :backend
  belongs_to :model
  has_many :llama_instance_slots, dependent: :destroy
  has_many :gpus

  after_initialize :setup

  def setup
    #puts caller
    model_config = self.model.config
    unless self.slots_free
      self.slots_free = model_config['slots']
    end
    unless self.slots_capacity
      self.slots_capacity = model_config['slots']
    end
    unless self.name
      self.name = "#{self.model.name}-#{Time.now.to_i}"
    end
    if self.running
      return save
    end
    self.active = false
    self.running = false
    self.loaded = false
    save

    puts Rainbow("Launching instance #{self.name} on #{self.backend.name}").bright.magenta
    response = self.backend.post('instances', {
      name: self.name,
      model: self.model.name,
      gpus: self.gpus.map(&:index)
    })

    if response.nil? || response.include?('error')
      puts Rainbow("Instance #{self.name} on #{self.backend.name} failed to launch").bright.red
      return
    end

    puts Rainbow("Model #{model.name} launched on #{self.backend.name}").bright.green
    self.port = response['port']
    self.active = true
    self.running = true
    self.loaded = false
    save
  end

  def ready?
    self.backend.available && self.active && self.running && self.loaded
  end

  def update_status
    puts Rainbow("Updating status for instance #{self.name} on #{self.backend.name}").bright.magenta
    response = self.backend.get("instances/#{self.name}")
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
    puts Rainbow("Instance #{self.name} on #{self.backend.name} is loaded: #{self.loaded}, running: #{self.running}").bright
    save    
  end

  def wait_loaded(i = 300)
    i.times do
      update_status
      if ready?
        break
      end
      sleep 1
    end
    self.loaded
  end

  def ensure_loaded(i = 300)
    update_status
    return true if ready?
    return false if !self.backend.available

    puts Rainbow("Instance #{self.name} on #{self.backend.name} is not ready, waiting").bright.red
    setup if !self.running
    wait_loaded(i)
  end

  def occupy_slot
    transaction do
      reload
      free_slot = LlamaInstanceSlot.find_by(llama_instance: self, occupied: false)
      return nil if free_slot.nil?

      free_slot.update!(occupied: true)
      self.slots_free -= 1
      save
      free_slot
    end
  end

  def release_slot(slot)
    transaction do
      reload
      slot.update!(occupied: false, last_token: "")
      self.slots_free += 1
      save
    end
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