class Backend < ActiveRecord::Base
  has_many :llama_instances, dependent: :destroy
  has_many :gpus

  def available_gpu_memory
    gpus.sum(:memory_free)
  end

  def models_from_backend
    JSON.parse(self.models_json || '{}')
  end

  def models_from_backend=(val)
    self.models_json = val.to_json
  end

  def get(path, params = {})
    uri = URI.parse("#{self.url}/#{path}")
    uri.query = URI.encode_www_form(params)
    response = Net::HTTP.get_response(uri, 'Accept' => 'application/json')
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
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      http.request(request)
    end
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

  def sync_complete_state(first_sync = false)
    status = get('')
    if status.nil? || status['error']
      self.available = false
      return save
    end
    sync_models(status['models'], first_sync)
    sync_gpus(status['gpus'], first_sync)
    sync_instances(status['instances'], first_sync)
    self.available = true
    self.last_seen_at = Time.now
    save
  end

  def sync_gpus(gpus_response, first_sync = false)
    return unless gpus_response
    current_gpu_ids = []
    
    gpus_response.each_with_index do |gpu_data, idx|
      gpu = gpus.find_or_create_by!(
        backend: self,
        index: idx,
        vendor_index: gpu_data['vendor_index'],
        vendor: gpu_data['vendor'],
        model: gpu_data['model']
      )
      current_gpu_ids << gpu.id
      
      # Update the Gpu attributes
      gpu.update(gpu_data)      
    end

    # Remove Gpus that no longer exist
    gpus.where.not(id: current_gpu_ids).destroy_all    
  end

  def sync_models(models_response, first_sync = false)
    return unless models_response
    self.models_from_backend = models_response
  end

  def sync_instances(instances_response, first_sync = false)
    return unless instances_response
    current_instance_ids = []
    instances_response.each do |inst_data|
      puts Rainbow("Processing instance #{inst_data['name']} on #{self.name}").bright.yellow if $config['verbose']
      model = Model.find_by(name: inst_data['model'])
      if model.nil?
        puts Rainbow("Model #{inst_data['model']} om #{self.name} not found in db").bright.red
        next
      end
      instance = LlamaInstance.find_or_create_by!(
        backend: self,
        model: model,
        port: inst_data['port'],
        active: true,
      )
      instance.update!(
        running: inst_data['running'],
        loaded: inst_data['loaded'],
        name: inst_data['name'],
      )
      current_instance_ids << instance.id
      inst_data['slots_capacity'].times do |i|
        LlamaInstanceSlot.find_or_create_by!(
          llama_instance: instance,
          slot_number: i,
          model: model,
        )
      end        
    end
    LlamaInstance.where.not(id: current_instance_ids).destroy_all
    LlamaInstanceSlot.where.not(llama_instance_id: current_instance_ids).destroy_all
    save
  end
end
