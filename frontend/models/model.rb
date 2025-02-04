class Model < ActiveRecord::Base
  has_many :llama_instances

  def config
    JSON.parse(self.config_json || '{}')
  end

  def config=(val)
    self.config_json = val.to_json
  end
end
