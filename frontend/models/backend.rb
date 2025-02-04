class Backend < ActiveRecord::Base
  has_many :llama_instances
  has_many :gpus

  def models_from_backend
    JSON.parse(self.models_json || '{}')
  end

  def models_from_backend=(val)
    self.models_json = val.to_json
  end

  def get(path, params = {})
    uri = URI.parse("#{self.url}/#{path}")
    uri.query = URI.encode_www_form(params)
    response = Net::HTTP.get_response(uri)
    JSON.parse(response.body)
  rescue => e
    puts e.message
    puts e.backtrace
    nil
  end

  def post(path, json_payload)
    uri = URI.parse("#{self.url}/#{path}")
    request = Net::HTTP::Post.new(uri)
    request.body = json_payload.to_json
    request.content_type = 'application/json'
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    JSON.parse(response.body)
  rescue => e
    puts e.message
    puts e.backtrace
    nil
  end
  
  def enumerate_gpus
    response = get('gpus')
    puts "Enumerating GPUs: #{response.inspect}"
    return false unless response

    transaction do
      # Track which Gpus we've seen
      current_gpu_ids = []
      
      response.each_with_index do |gpu_data, idx|
        gpu = gpus.find_or_create_by!(
          backend: self,
          index: idx,
          vendor_index: gpu_data['vendor_index'],
          vendor: gpu_data['vendor'],
          model: gpu_data['model'],
          memory_total: gpu_data['memory_total'],
        )
        
        # Update the Gpu attributes
        gpu.update!(
          memory_free: gpu_data['memory_free'],
          compute_usage: gpu_data['compute_usage'],
          power_usage: gpu_data['power_usage'],
          temperature: gpu_data['temperature']
        )
        
        current_gpu_ids << gpu.id
      end

      puts "Current GPU IDs: #{current_gpu_ids.inspect}"
      # Remove Gpus that no longer exist
      gpus.where.not(id: current_gpu_ids).destroy_all
      
      self.available = true
      save
    end
    
    true
  rescue => e
    puts e.message
    puts e.backtrace
    false
  end

  def enumerate_models
    response = get('models')
    if response
      self.models_from_backend = response
      self.available = true
    else
      self.available = false
    end
    save
    self.available
  end

  def update_status
    self.available = enumerate_gpus && enumerate_models
    save
    self.available
  end

  def post_model_list(models)
    response = post('models', models.map(&:config))
    return false unless response
    true
  rescue => e
    puts e.message
    puts e.backtrace
    false
  end

  def sync_complete_state
    transaction do
      # Sync Gpu and model state (existing methods)
      enumerate_gpus
      enumerate_models
      
      # Sync running instances
      response = get('instances')
      30.times do
        puts "Syncing instances: #{response.inspect}"
      end
      puts "Syncing instances: #{response.inspect}"
      if response
        current_instance_ids = []
        
        response.each do |inst_data|
          model = Model.find_by(name: inst_data['model'])          
          instance = llama_instances.find_or_create_by!(
            name: inst_data['name'],
            model: model,
            backend: self
          )
          
          instance.update!(
            port: inst_data['port'],
            slots_capacity: inst_data['slots_capacity'],
            slots_free: inst_data['slots_capacity'],
            cached_active: true
          )
          
          current_instance_ids << instance.id
          
          # Handle slots
          current_slot_ids = []
          inst_data['slots_capacity'].times do |i|
            slot = instance.llama_instance_slots.find_or_create_by!(
              llama_instance: instance,
              model: model,
              slot_number: i
            )
            
            slot.update!(
              model: model,
              occupied: false,
            )
            
            current_slot_ids << slot.id
          end
          
          # Remove stale slots
          instance.llama_instance_slots.where.not(id: current_slot_ids).destroy_all
        end
        
        # Remove stale instances
        llama_instances.where.not(id: current_instance_ids).destroy_all
      end

      self.available = true
      save!
    end
    true
  rescue => e
    puts "Error syncing backend #{name}: #{e.message}"
    puts e.backtrace
    self.available = false
    save!
    false
  end
end
