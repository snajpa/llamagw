#!/usr/bin/env crystal

# init_db.cr
#
# 1) Read DB config from config-frontend.yml
# 2) Drop the old DB if it exists
# 3) Create a fresh DB
# 4) Use a single Jennifer migration to build all tables

require "yaml"
require "json"
require "db"
require "mysql"
require "jennifer"
require "jennifer/adapter/mysql"
require "jennifer/migration"

# We won't require all models here unless you want them,
# but we DO want the same DB config that the main server uses.
# Instead of requiring them, we can define a config struct:

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
CONFIG_FILE = "./config-frontend.yml"

config_data = YAML.parse(File.read(CONFIG_FILE)).as_h
config_json = JSON.parse(config_data.to_json).as_h

db_conf = config_json["database"].as_h
DB_HOST = db_conf["host"].as_s
DB_USER = db_conf["user"].as_s
DB_PASS = db_conf["password"].as_s
DB_NAME = db_conf["name"].as_s

Jennifer::Config.configure do |conf|
  conf.adapter  = db_conf["adapter"].as_s        # "mysql"
  conf.host     = DB_HOST
  conf.database = DB_NAME
  conf.user     = DB_USER
  conf.password = DB_PASS
  conf.pool     = db_conf["pool"]?.as_i || 150
end

# -----------------------------------------------------------------------------
# 1) Drop & Create the DB using raw MySQL commands
# -----------------------------------------------------------------------------
def drop_and_create_database
  # Connect without specifying DB_NAME in the URI
  DB.open "mysql://#{DB_USER}:#{DB_PASS}@#{DB_HOST}" do |conn|
    puts "Dropping database #{DB_NAME} if it exists..."
    conn.exec "DROP DATABASE IF EXISTS #{DB_NAME}"
    puts "Creating database #{DB_NAME}..."
    conn.exec "CREATE DATABASE #{DB_NAME}"
  end
end

# -----------------------------------------------------------------------------
# 2) Single "init" migration describing all tables
# -----------------------------------------------------------------------------
class InitMigration < Jennifer::Migration::Base
  def up
    # TABLE: models
    create_table :models do
      primary_key :id
      add :name, String
      add :config_json, String, null: true
      add_timestamps
    end

    # TABLE: backends
    create_table :backends do
      primary_key :id
      add :name, String
      add :url,  String
      add :models_json, String, null: true
      add :available,   Bool,   default: false
      add :last_seen_at, Time,  null: true
      add_timestamps
    end

    # TABLE: llama_instances
    create_table :llama_instances do
      primary_key :id
      add_reference :backend_id, foreign_key: :backends, on_delete: :cascade
      add_reference :model_id,   foreign_key: :models,   on_delete: :cascade
      add :name,          String
      add :slots_capacity, Int32, null: true
      add :slots_free,     Int32, null: true
      add :port,           Int32, null: true
      add :running, Bool,  default: false
      add :loaded,  Bool,  default: false
      add :active,  Bool,  default: false
      add_timestamps
    end

    # TABLE: llama_instance_slots
    create_table :llama_instance_slots do
      primary_key :id
      add_reference :llama_instance_id, foreign_key: :llama_instances, on_delete: :cascade
      add_reference :model_id,          foreign_key: :models,          on_delete: :cascade
      add :slot_number, Int32
      add :last_token,  String, default: ""
      add :occupied,    Bool,   default: false
      add_timestamps
    end

    # TABLE: gpus
    create_table :gpus do
      primary_key :id
      add_reference :backend_id,        foreign_key: :backends,       on_delete: :cascade
      add_reference :llama_instance_id, foreign_key: :llama_instances, on_delete: :set_null, null: true
      add :index,        Int32
      add :vendor_index, Int32
      add :vendor,       String
      add :model,        String
      add :memory_total, Int32
      add :memory_free,  Int32
      add :compute_usage, Int32, null: true
      add :membw_usage,   Int32, null: true
      add :power_usage,   Int32, null: true
      add :temperature,   Int32, null: true
      add_timestamps
    end

    # Unique index matching your Ruby code
    add_index :llama_instances, [:backend_id, :name], unique: true
  end

  def down
    drop_table :gpus
    drop_table :llama_instance_slots
    drop_table :llama_instances
    drop_table :backends
    drop_table :models
  end
end

# -----------------------------------------------------------------------------
# Main routine
# -----------------------------------------------------------------------------
if __FILE__ == $PROGRAM_NAME
  drop_and_create_database

  # Reconnect Jennifer to the new DB
  Jennifer::Config.configure do |conf|
    conf.adapter  = db_conf["adapter"].as_s
    conf.host     = DB_HOST
    conf.database = DB_NAME
    conf.user     = DB_USER
    conf.password = DB_PASS
    conf.pool     = db_conf["pool"]?.as_i || 150
  end

  # Run the migration to create all tables
  puts "Running InitMigration..."
  InitMigration.new.run(:up)
  puts "Database #{DB_NAME} is now initialized!"
end
