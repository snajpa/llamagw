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
    puts Rainbow(e.message).bright.red
    #puts e.backtrace
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
    puts Rainbow(e.message).bright.red
    #puts e.backtrace
    nil
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
    sync_models
    return unless self.available
    sync_gpus
    sync_instances
  end

  def sync_gpus
    response = get('gpus')
    if response.nil? || response.include?('error')
      self.available = false
      return save
    end

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

      # Remove Gpus that no longer exist
      gpus.where.not(id: current_gpu_ids).destroy_all
      
      self.available = true
      self.last_seen_at = Time.now
      save
    end    
  end

  def sync_models
    response = get('models')
    if response.nil? || response.include?('error')
      self.available = false
      return save
    end

    self.models_from_backend = response
    self.available = true
    self.last_seen_at = Time.now
    save
  end

  def sync_instances
    response = get('instances')
    if response.nil? || response.include?('error')
      self.available = false
      return save
    end

    current_instance_ids = []
    response.each do |inst_data|
      puts Rainbow("Processing instance #{inst_data['name']} on #{self.name}").bright.yellow
      model = Model.find_by(name: inst_data['model'])
      model_config = model.config
      instance = LlamaInstance.find_or_create_by!(
        backend: self,
        model: model,
        slots_capacity: model_config['slots'],
        name: inst_data['name'],
        running: inst_data['running'],
        loaded: inst_data['loaded'],
        port: inst_data['port'],
        active: true,
      )
      instance.update_status
      current_instance_ids << instance.id
      inst_data['slots_capacity'].times do |i|
        LlamaInstanceSlot.find_or_create_by!(
          llama_instance: instance,
          slot_number: i,
          model: model,
          occupied: false
        )
      end        
    end
    LlamaInstance.where.not(id: current_instance_ids).destroy_all
    LlamaInstanceSlot.where.not(llama_instance_id: current_instance_ids).destroy_all
    
    self.available = true
    self.last_seen_at = Time.now
  save
  end
end
