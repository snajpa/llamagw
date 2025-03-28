# frontend/models/auth_token.rb
require 'securerandom'

class AuthToken < ActiveRecord::Base
  belongs_to :user
  has_many :usage_logs, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :token_digest, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  def self.find_by_token(token)
    return nil if token.blank?
    find_by(token_digest: Digest::SHA256.hexdigest(token))
  end

  def self.verify(token)
    auth_token = find_by_token(token)
    return nil unless auth_token&.active?
    auth_token
  end

  private

  def generate_token
    return if token_digest.present?
    raw_token = SecureRandom.hex(32)
    self.token_digest = Digest::SHA256.hexdigest(raw_token)
    @raw_token = raw_token
  end

  def raw_token
    @raw_token
  end
end