class Gpu < ActiveRecord::Base
  belongs_to :backend

  def available?
    llama_instance_slot.nil?
  end

  def to_h
    {
      backend_id: backend_id,
      backend_name: backend.name,
      id: id,
      index: index,
      vendor_index: vendor_index,
      vendor: vendor,
      model: model,
      pstate: pstate,
      memory_total: memory_total,
      memory_free: memory_free,
      memory_used: memory_used,
      utilization_gpu: utilization_gpu,
      utilization_memory: utilization_memory,
      clocks_current_graphics: clocks_current_graphics,
      clocks_current_memory: clocks_current_memory,
      temperature_gpu: temperature_gpu,
      temperature_memory: temperature_memory,
      fan_speed: fan_speed,
      power_draw_average: power_draw_average,
      power_draw_instant: power_draw_instant,
      power_limit: power_limit,
      backend_available: backend.available ? 1 : 0,
    }
  end
end