# frontend/models/usage_log.rb
class UsageLog < ActiveRecord::Base
  belongs_to :user
  belongs_to :auth_token  
  belongs_to :model

  validates :input_tokens, :output_tokens, :total_tokens,
            numericality: { greater_than_or_equal_to: 0 }

  scope :successful, -> { where(successful: true) }
  scope :failed, -> { where(successful: false) }
  scope :recent, -> { order(created_at: :desc) }
end