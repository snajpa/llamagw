class Model < ActiveRecord::Base
  has_many :llama_instances

  def config
    JSON.parse(self.config_json || '{}')
  end

  def config=(val)
    self.config_json = val.to_json
    save
  end

  def self.import_from_config(from_config)
    model = Model.find_or_initialize_by(name: from_config['name'])
    model.config = from_config
    model.est_memory_mb = from_config['est_memory_mb']
    model.slots = from_config['slots']
    model.context_length = from_config['context_length']
    model.max_output_tokens = from_config['max_output_tokens']

    model.save
    model
  end
end

class ModelBackend
end