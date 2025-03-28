
require 'rainbow'
using Rainbow

def list_models
  Model.all.map do |m|
    {
      id: m.id,
      name: m.name,
      created: m.created_at ? m.created_at.to_i : Time.now.to_i,
      updated: m.updated_at ? m.updated_at.to_i : Time.now.to_i,
      object: 'model',
      owned_by: 'organization',
      permission: []
    }
  end
end

def find_model(model_identifier)
  # Try to locate the model by name first
  model = Model.find_by(name: model_identifier)
  # If not found and the provided identifier is numeric, use it as an index (0-based)
  if model.nil? && model_identifier.to_s.strip.match?(/^\d+$/)
    index = model_identifier.to_i - 1
    model = Model.all.order(:name).to_a[index]
  end
  model
end

def pick_backend_for_new_instance(model)
  Backend.where(available: true).each do |backend|
    if backend.models_from_backend.any? { |m| m['name'] == model.name }
      return backend
    end
  end
  nil
end

def pick_gpus_for_new_instance(backend, model)
  needed_memory = model.est_memory_mb
  selected_gpus = []
  backend.gpus.sort_by(&:memory_free).reverse.select do |gpu|
    if needed_memory > 0
      selected_gpus << gpu
      needed_memory -= gpu.memory_free
      puts "GPU #{gpu.vendor_index} on #{backend.name} selected".bright.green
    end
  end
  if needed_memory > 0
    return [[], 'Not enough memory on available GPUs']
  end
  [selected_gpus, nil]
end

def allocate_new_instance(model)
  backend = pick_backend_for_new_instance(model)
  return [nil, 'No available backends'] unless backend

  gpus, msg = pick_gpus_for_new_instance(backend, model)
  return [nil, msg] if gpus.empty?

  new_inst = LlamaInstance.new(
    model: model,
    backend: backend,
    gpus: gpus
  )

  return [nil, 'Failed while creating new instance of model'] if new_inst.nil?

  new_inst.wait_loaded

  return [nil, 'Failed while launching new instance of model'] unless new_inst.ready?

  [new_inst, nil]
end

def acquire_instance_slot(model)
  backend = Backend.where(available: true).first
  return [nil, 'No available backends'] unless backend

  instance_data = nil
  LlamaInstance.joins(:backend).
                where(model: model,
                      backend: { id: backend.id, available: true }).each do |instance|
    puts "Instance for model #{model.name} on instance #{backend.name}.#{instance.name} is evaluated".bright.green if $config['verbose']
    instance.ensure_loaded
    if !instance.ready?
      next
    end

    if instance.slots_free <= 0
      puts "Instance for model #{model.name} on instance #{backend.name}.#{instance.name} has no free slots, next".bright.red
      next
    end

    if slot = instance.occupy_slot
      puts "Slot #{slot.slot_number} acquired for model #{model.name} on instance #{backend.name}.#{instance.name}".bright.green
      instance_data = {instance: instance, slot: slot}
      break
    else
      puts "Failed to acquire slot for model #{model.name} on instance #{backend.name}.#{instance.name}".bright.red
      next
    end
  end

  if instance_data.nil?
    new_inst, msg = allocate_new_instance(model)
    if new_inst.nil?
      return [nil, msg]
    end

    new_inst.wait_loaded

    return [nil, 'Failed while launching new instance of model'] unless new_inst.ready?

    puts "Instance for model #{model.name} on instance #{backend.name}.#{new_inst.name} is active".bright.green

    if slot = new_inst.occupy_slot
      puts "Slot acquired for model #{model.name} on instance #{backend.name}.#{new_inst.name}".bright.green
      instance_data = {instance: new_inst, slot: slot}
    else
      return [nil, 'No usable instance or backend']
    end
  end
  [instance_data, nil]
end

def process_request(route)
  request_data = JSON.parse(request.body.read)
  model_identifier = request_data['model']

  model = find_model(model_identifier)
  halt 404, { error: 'Model not found' }.to_json unless model

  puts "Looking for available backend for model #{model.name}".bright.magenta if $config['verbose']
  instance_data, error = acquire_instance_slot(model)

  if error
    puts error.bright.red
    halt 503, { error: error }.to_json
  end

  http, req, uri = forward_request(instance_data, route, request_data)
  stream_response(http, req, instance_data)
rescue => e
  puts Rainbow(e.message).bright.red
  puts e.backtrace
  if instance_data && instance_data[:instance] && instance_data[:slot]
    instance_data[:slot].release
  end
  halt 500, { error: e.message }.to_json
end

def forward_request(instance_data, route, request_data)
  uri = URI.parse("#{instance_data[:instance].backend.url}#{route}")
  uri.port = instance_data[:instance].port

  puts "Forwarding request to #{uri}".bright.magenta
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
  req_body = request_data.merge({
    'id_slot' => instance_data[:slot].slot_number,
  })
  req_body.delete('model')
  req.body = req_body.to_json
  [http, req, uri]
end

def stream_response(http, req, instance_data)
  stream do |out|
    begin
      http.request(req) do |res|
        # Forward status and headers (if needed)
        status res.code.to_i
        headers res.to_hash.transform_values(&:first)
        res.read_body do |chunk|
          out << chunk
        end
      end
    rescue => e
      out <<({ error: e.message }.to_json)
    ensure
      # Ensure the slot is released once streaming ends
      instance_data[:slot].release if instance_data && instance_data[:slot]
      puts "Slot #{instance_data[:slot].slot_number} released for model #{instance_data[:instance].model.name} on backend #{instance_data[:instance].backend.name}".bright.green
    end
  end
end
