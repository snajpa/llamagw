class Gpu < ActiveRecord::Base
  belongs_to :backend
  has_one :llama_instance, dependent: :nullify

  def available?
    llama_instance_slot.nil?
  end

  def memory_used
    memory_total - memory_free if memory_total && memory_free
  end
end