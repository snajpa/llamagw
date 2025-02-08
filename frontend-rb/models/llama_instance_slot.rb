class LlamaInstanceSlot < ActiveRecord::Base
  belongs_to :llama_instance
  belongs_to :model
  
  validates :slot_number, presence: true
  validates :occupied, inclusion: [true, false]
  
  def release
    begin
      transaction do
        reload
        self.update(occupied: false, last_token: "")
        save
      end
    rescue => e
    end
  end

  def update_last_token(token)
    update!(last_token: token)
  end
end