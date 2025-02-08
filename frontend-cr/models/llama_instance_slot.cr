# models/llama_instance_slot.cr
require "jennifer"

class LlamaInstanceSlot < Jennifer::Model::Base
  table :llama_instance_slots
  with_timestamps

  mapping(
    id: Primary32,
    llama_instance_id: Int32,
    model_id: Int32,
    slot_number: Int32,
    last_token: String?,
    occupied: Bool?,
    created_at: Time?,
    updated_at: Time?
  )

  belongs_to llama_instance : LlamaInstance, foreign_key: "llama_instance_id"
  belongs_to model : Model, foreign_key: "model_id"

  def release
    Jennifer::Model::Base.transaction do
      self.reload
      self.occupied = false
      self.last_token = ""
      self.save
    end
  end

  def update_last_token(token : String)
    self.last_token = token
    self.save
  end
end
