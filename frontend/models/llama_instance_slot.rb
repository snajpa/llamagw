class LlamaInstanceSlot < ActiveRecord::Base
  belongs_to :llama_instance
  belongs_to :model
  
  validates :slot_number, presence: true
  validates :occupied, inclusion: [true, false]
  
  def update_last_token(token)
    update!(last_token: token)
  end
end