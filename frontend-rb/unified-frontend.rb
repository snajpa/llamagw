# ./server-frontend.rb
#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'csv'
require 'net/http'
require 'uri'
require 'thread'
require 'optparse'
require 'sinatra/base'
require 'rainbow/refinement'
using Rainbow

config_file = './config-frontend.yml'
OptionParser.new do |opts|
  opts.banner = "Usage: server-frontend.rb [options]"
  opts.on('-c', '--config=FILE', 'Path to config file') do |file|
    config_file = file
  end
end.parse!

unless config_file
  puts "Error: Configuration file must be specified with --config/-c"
  exit 1
end

$config = YAML.load_file(config_file)
$config["update_interval"] ||= 60

class Model
  @@models = []

  attr_accessor :name, :config

  def initialize(name, config = {})
    @name = name
    @config = config
  end

  def self.load_from_config(models)
    @@models = models.map { |m| new(m['name'], m) }
  end

  def self.all
    @@models
  end

  def self.find_by_name(name)
    @@models.find { |m| m.name == name }
  end
end

class Backend
  @@backends = []

  attr_accessor :name, :url, :available, :models

  def initialize(name, url)
    @name = name
    @url = url
    @available = true
    @models = []
  end

  def self.load_from_config(backends)
    @@backends = backends.map { |b| new(b['name'], b['url']) }
  end

  def self.all
    @@backends
  end

  def self.available
    @@backends.select(&:available)
  end

  def find_or_create_instance(model)
    instance = LlamaInstance.all.find { |i| i.model == model && i.backend == self }
    return instance if instance

    puts "Creating new instance for model #{model.name} on backend #{name}".bright.magenta
    new_instance = LlamaInstance.new(self, model)
    @@instances << new_instance
    new_instance
  end
end

class LlamaInstance
  @@instances = []

  attr_accessor :backend, :model, :slots, :active, :running, :loaded

  def initialize(backend, model)
    @backend = backend
    @model = model
    @slots = Array.new(model.config['slots'] || 1) { LlamaInstanceSlot.new(self) }
    @active = true
    @running = true
    @loaded = false
    @@instances << self
  end

  def self.all
    @@instances
  end

  def occupy_slot
    slot = @slots.find(&:available?)
    if slot
      puts "Acquired slot on instance for model #{model.name}".bright.green
      slot.occupy
    else
      puts "No free slots for model #{model.name}".bright.red
    end
    slot
  end

  def slots_free
    @slots.count { |slot| !slot.occupied }
  end
end

class LlamaInstanceSlot
  attr_accessor :llama_instance, :occupied

  def initialize(llama_instance)
    @llama_instance = llama_instance
    @occupied = false
  end

  def available?
    !@occupied
  end

  def occupy
    @occupied = true
  end

  def release
    puts "Slot released for model #{llama_instance.model.name}".bright.green
    @occupied = false
  end
end

Model.load_from_config($config['models'] || [])
Backend.load_from_config($config['backends'] || [])

Thread.new do
  loop do
    puts "Updating backends"
    Backend.all.each(&:available)
    puts "Updating done"
    sleep $config["update_interval"]
  end
end

Thread.new do
  loop do
    sleep 5
  end
end

class ServerFrontend < Sinatra::Base
  set :server, 'puma'
  set :environment, :production

  get '/' do
    content_type 'text/html'
    css = """
    <style>
      table {
        border-collapse: collapse;
        width: 100%;
        margin-bottom: 20px;
      }
      th, td {
        border: 1px solid #ddd;
        padding: 8px;
        text-align: left;
      }
      th {
        background-color: #f2f2f2;
      }
      tr:nth-child(even) {
        background-color: #f9f9f9;
      }
    </style>
    """
    
    backends_html = "<h2>Backend Servers</h2><table><tr><th>Name</th><th>URL</th><th>Status</th></tr>"
    Backend.all.each do |backend|
      backends_html += "<tr><td>#{backend.name}</td><td>#{backend.url}</td><td>#{backend.available ? 'Available' : 'Unavailable'}</td></tr>"
    end
    backends_html += "</table>"
    
    models_html = "<h2>Available Models</h2><table><tr><th>Name</th></tr>"
    Model.all.each do |model|
      models_html += "<tr><td>#{model.name}</td></tr>"
    end
    models_html += "</table>"
    
    "<html><head><title>LLM Gateway Status</title>#{css}</head><body>#{backends_html}#{models_html}</body></html>"
  end

  get '/v1/models' do
    models = Model.all.map do |m|
      {
        id: m.name,
        object: 'model',
        created: Time.now.to_i,
        owned_by: 'organization',
        permission: []
      }
    end
    { data: models }.to_json
  end
end

ServerFrontend.run! if __FILE__ == $PROGRAM_NAME
