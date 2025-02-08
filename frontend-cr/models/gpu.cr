# models/gpu.cr
require "jennifer"

class Gpu < Jennifer::Model::Base
  table :gpus
  with_timestamps

  mapping(
    id: Primary32,
    backend_id: Int32,
    llama_instance_id: Int32?,
    index: Int32?,
    vendor_index: Int32?,
    vendor: String?,
    model: String?,
    memory_total: Int32?,
    memory_free: Int32?,
    compute_usage: Int32?,
    membw_usage: Int32?,
    power_usage: Int32?,
    temperature: Int32?,
    created_at: Time?,
    updated_at: Time?
  )

  belongs_to backend : Backend, foreign_key: "backend_id", primary_key: "id"

  def memory_used
    if memory_total && memory_free
      memory_total - memory_free
    else
      nil
    end
  end

  def reload_backend : Backend
    Backend.find(self.backend_id)
  end
end
