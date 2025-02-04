# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2025_02_02_225908) do
  create_table "models", force: :cascade do |t|
    t.string     "name"
    t.integer    "slots"
    t.integer    "timeout"
    t.text       "config_json"
    t.timestamps
  end

  create_table "backends", force: :cascade do |t|
    t.string     "name"
    t.string     "url"
    t.text       "models_json"
    t.boolean    "available", default: false
    t.timestamps
  end

  create_table "gpus", force: :cascade do |t|
    t.references :backend, null: false, foreign_key: true
    t.references :llama_instance, null: true, foreign_key: true
    t.integer    "index"
    t.integer    "vendor_index"
    t.string     "vendor"
    t.string     "model"
    t.integer    "memory_total"
    t.integer    "memory_free"
    t.integer    "compute_usage"
    t.integer    "membw_usage"
    t.integer    "power_usage"
    t.integer    "temperature"
    t.timestamps
  end

  create_table "llama_instances", force: :cascade do |t|
    t.references :backend, null: false, foreign_key: true
    t.references :model, null: false, foreign_key: true
    t.string     "name"
    t.integer    "slots_capacity"
    t.integer    "slots_free"
    t.integer    "port"
    t.boolean    "cached_active", default: false
    t.timestamps
  end

  create_table "llama_instance_slots" do |t|
    t.references :llama_instance, null: false, foreign_key: true
    t.references :model, null: false, foreign_key: true
    t.integer    "slot_number", null: false
    t.string     "last_token", default: ""
    t.boolean    "occupied", default: false
    t.timestamps
  end  
end
