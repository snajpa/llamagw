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
    t.datetime   "last_seen_at"
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
    t.boolean    "running", default: false
    t.boolean    "loaded", default: false
    t.boolean    "active", default: false
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

  add_index "llama_instances", ["backend_id", "name"], name: "index_llama_instances_on_backend_id_and_name", unique: true
end
