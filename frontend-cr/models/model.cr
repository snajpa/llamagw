# models/model.cr
require "jennifer"

class Model < Jennifer::Model::Base
  table :models
  with_timestamps

  # DB columns: name, config_json
  mapping(
    id: Primary32,
    name: String?,
    config_json: String?,
    created_at: Time?,
    updated_at: Time?
  )

  has_many llama_instances : LlamaInstance, foreign_key: "model_id"

  def config : Hash(String, JSON::Type)
    return Hash(String, JSON::Type).new unless config_json
    JSON.parse(config_json.not_nil!).as_h
  end

  def config=(val : Hash(String, JSON::Type) | Nil)
    if val
      self.config_json = val.to_json
    else
      self.config_json = "{}"
    end
  end
end
