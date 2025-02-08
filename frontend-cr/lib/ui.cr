# lib/ui.cr
require "kemal"
require "json"

require_relative "../models/backend"
require_relative "../models/gpu"
require_relative "../models/model"
require_relative "../models/llama_instance"
require_relative "../server-frontend" # for $config and model_ready_on_all_backends?

# Helper method for rendering the page
def render_ui : String
  String.build do |sb|
    sb << %(<html><head><title>LLM Gateway Status</title><style>
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
</style></head><body>)

    # Backends
    sb << "<h2>Backend Servers</h2><table>"
    sb << "<tr><th>Name</th><th>URL</th><th>Status</th></tr>"
    Backend.all.each do |backend|
      sb << "<tr>"
      sb << "<td>#{backend.name}</td>"
      sb << "<td>#{backend.url}</td>"
      sb << "<td>#{backend.available? ? "Available" : "Unavailable"}</td>"
      sb << "</tr>"
    end
    sb << "</table>"

    # GPUs
    sb << "<h2>Gpus Across All Backends</h2>"
    sb << %(<table><tr>
      <th>Backend</th><th>Gpu idx</th><th>Vendor</th>
      <th>VRAM Total</th><th>VRAM Free</th><th>VRAM Used</th>
      <th>Power Usage</th><th>Compute Usage</th>
      <th>MemBW Usage</th><th>Temperature</th><th>Status</th>
    </tr>)
    Gpu.all.each do |gpu|
      the_backend = gpu.reload_backend
      sb << "<tr>"
      sb << "<td>#{the_backend.name}</td>"
      sb << "<td>#{gpu.index}</td>"
      sb << "<td>#{gpu.vendor}</td>"
      sb << "<td>#{gpu.memory_total} MB</td>"
      sb << "<td>#{gpu.memory_free} MB</td>"
      sb << "<td>#{gpu.memory_used} MB</td>"
      sb << "<td>#{gpu.power_usage}W</td>"
      sb << "<td>#{gpu.compute_usage}%</td>"
      sb << "<td>#{gpu.membw_usage}%</td>"
      sb << "<td>#{gpu.temperature}C</td>"
      sb << "<td>#{the_backend.available? ? "Available" : "Unavailable"}</td>"
      sb << "</tr>"
    end
    sb << "</table>"

    # Models
    sb << "<h2>Available Models</h2><table>"
    sb << "<tr><th>Name</th><th>Slots</th><th>Context Size</th><th>Files</th><th>Status</th></tr>"
    Model.all.each do |model|
      conf   = model.config
      name   = model.name
      slots  = conf["slots"]?.as_i || 0
      ctx    = conf["ctx"]?.as_i   || 0
      files  = conf["files"]?.as_a? || [] of JSON::Any
      status = model_ready_on_all_backends?(name.not_nil!) ? "Ready" : "Unavailable"

      sb << "<tr>"
      sb << "<td>#{name}</td>"
      sb << "<td>#{slots}</td>"
      sb << "<td>#{ctx}</td>"
      sb << "<td>#{files.map(&.to_s).join(", ")}</td>"
      sb << "<td>#{status}</td>"
      sb << "</tr>"
    end
    sb << "</table>"

    # Instances
    sb << "<h2>Instances</h2><table>"
    sb << "<tr>"
    sb << "<th>Backend</th><th>Model</th><th>Slots In Use</th>"
    sb << "<th>Slots Free</th><th>Capacity</th>"
    sb << "<th>Port</th><th>Running</th><th>Loaded</th><th>Active</th>"
    sb << "</tr>"
    LlamaInstance.all.each do |inst|
      used = (inst.slots_capacity || 0) - inst.slots_free
      sb << "<tr>"
      sb << "<td>#{inst.backend&.name}</td>"
      sb << "<td>#{inst.model&.name}</td>"
      sb << "<td>#{used}</td>"
      sb << "<td>#{inst.slots_free}</td>"
      sb << "<td>#{inst.slots_capacity}</td>"
      sb << "<td>#{inst.port}</td>"
      sb << "<td>#{inst.running? ? "Yes" : "-"}</td>"
      sb << "<td>#{inst.loaded?  ? "Yes" : "-"}</td>"
      sb << "<td>#{inst.active?  ? "Yes" : "-"}</td>"
      sb << "</tr>"
    end
    sb << "</table>"

    # Auto-refresh
    interval_ms = ($config["update_interval"]?.as_i || 60) * 1000
    sb << %(<script>setTimeout(function(){ window.location.reload(); }, #{interval_ms});</script>)

    sb << "</body></html>"
  end
end
