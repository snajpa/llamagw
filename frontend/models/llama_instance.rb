class LlamaInstance < ActiveRecord::Base
  belongs_to :backend
  belongs_to :model
  has_many :llama_instance_slots, dependent: :destroy
  has_many :gpus

  #after_initialize :launch

  def launch
    instance_name = "#{model.name}-#{Time.now.to_i}"
    
    puts "Launching instance #{instance_name} on #{backend.name}"
    response = backend.post('instances', {
      name: instance_name,
      model: model.name,
      gpus: gpus
    })
    return nil unless response

    self.name = instance_name
    self.port = response['port']
    
    puts "Model #{model.name} launched on #{backend.name}"
    model_config = model.config
    self.slots_capacity = model_config['slots']
    self.slots_free = model_config['slots']
    self.cached_active = false
    save!
    puts "Little info about model launch: #{self.inspect}"
    puts "Little info about model launch: #{self.model.inspect}"
    300.times do
      break if query_active?
      sleep 1
    end

    return nil unless self.cached_active
    
    self.slots_capacity.times do |i|
      LlamaInstanceSlot.create!(
        llama_instance: self,
        model: model,
        slot_number: i,
        last_token: "",
        occupied: false
      )
    end

    self
  end

  def occupy_slot
    reload
    transaction do
      free_slot = llama_instance_slots.find_by(llama_instance: self, occupied: false)
      return nil unless free_slot
      
      free_slot.update!(occupied: true)
      self.slots_free -= 1
      save!
      free_slot
    end
  end

  def release_slot(slot)
    reload
    transaction do
      slot.update!(occupied: false, last_token: "")
      self.slots_free += 1
      save!
    end
  end

  def shutdown
    begin
      response = backend.get("instances/#{name}", _method: 'DELETE')
      return !!response
    rescue => e
      puts e.message
      puts e.backtrace
      false
    ensure
      destroy
    end
  end

  def query_active?
    response = backend.get("instances/#{name}")
    if response
      self.cached_active = response['active']
    else
      self.cached_active = false
    end
    save!
    self.cached_active
  end
end

class LlamaInstanceSlot < ActiveRecord::Base
  belongs_to :llama_instance
  belongs_to :model
  
  validates :slot_number, presence: true
  validates :occupied, inclusion: [true, false]
  
  def update_last_token(token)
    update!(last_token: token)
  end
end