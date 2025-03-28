# frontend/models/user.rb
require 'bcrypt'

class User < ActiveRecord::Base
  has_secure_password
  
  has_many :auth_tokens, dependent: :destroy
  has_many :usage_logs, dependent: :destroy

  validates :email, presence: true, 
                   uniqueness: true,
                   format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :external_id, presence: true, uniqueness: true

  def total_usage_for_model(model, start_date = nil, end_date = nil)
    scope = usage_logs.where(model: model)
    scope = scope.where("created_at >= ?", start_date) if start_date
    scope = scope.where("created_at <= ?", end_date) if end_date
    scope.sum(:total_tokens)
  end

  def self.find_or_create_from_auth(auth_data)
    User.find_or_create_by!(
      external_id: auth_data['id']
    ) do |user|
      user.email = auth_data['email']
      user.admin = auth_data['admin'] || false
    end
  end
end