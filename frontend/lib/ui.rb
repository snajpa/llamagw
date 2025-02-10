# Web UI
get '/' do
  content_type 'text/html'

  css = <<~BLOCK
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
  BLOCK

  backends_html = <<~BLOCK
    <h2>Backend Servers</h2>
    <table>
      <tr>
        <th>Name</th>
        <th>URL</th>
        <th>Status</th>
      </tr>
  BLOCK

  Backend.all.each do |backend|
    backends_html += <<~RBLK
      <tr>
        <td>#{backend.name}</td>
        <td>#{backend.url}</td>
        <td>#{backend.available ? 'Available' : 'Unavailable'}</td>
      </tr>
    RBLK
  end
  backends_html += "</table>"

  gpus_html = <<~BLOCK
    <h2>Gpus Across All Backends</h2>
    <table>
      <tr>
        <th>Backend</th>
        <th>Gpu idx</th>
        <th>Vendor</th>
        <th>VRAM Total</th>
        <th>VRAM Free</th>
        <th>VRAM Used</th>
        <th>Power Usage</th>
        <th>Compute Usage</th>
        <th>MemBW Usage</th>
        <th>Temperature</th>
        <th>Status</th>
      </tr>
  BLOCK

  Gpu.all.each do |gpu|
    backend = gpu.reload_backend
    gpus_html += <<~GBLK
      <tr>
        <td>#{backend.name}</td>
        <td>#{gpu.index}</td>
        <td>#{gpu.vendor}</td>
        <td>#{gpu.memory_total} MB</td>
        <td>#{gpu.memory_free} MB</td>
        <td>#{gpu.memory_used} MB</td>
        <td>#{gpu.power_usage}W</td>
        <td>#{gpu.compute_usage}%</td>
        <td>#{gpu.membw_usage}%</td>
        <td>#{gpu.temperature}C</td>
        <td>#{backend.available ? 'Available' : 'Unavailable'}</td>
      </tr>
    GBLK
  end
  gpus_html += "</table>"

  models_html = <<~BLOCK
    <h2>Available Models</h2>
    <table>
      <tr>
        <th>Name</th>
        <th>Slots per instance</th>
        <th>Context Size</th>
        <th>Files</th>
        <th>Status</th>
      </tr>
  BLOCK

  Model.all.each do |model|
    conf = model.config
    files = conf['files'] || []
    models_html += <<~MBLK
      <tr>
        <td>#{model.name}</td>
        <td>#{conf['slots']}</td>
        <td>#{conf['ctx']}</td>
        <td>#{files.join(', ')}</td>
        <td>#{model_ready_on_all_backends?(model.name) ? 'Ready' : 'Unavailable'}</td>
      </tr>
    MBLK
  end
  models_html += "</table>"

  instances_html = <<~BLOCK
    <h2>Instances</h2>
    <table>
      <tr>
        <th>Backend</th>
        <th>Model</th>
        <th>Slots In Use</th>
        <th>Slots Free</th>
        <th>Capacity</th>
        <th>Port</th>
        <th>Running</th>
        <th>Loaded</th>
        <th>Active</th>
      </tr>
  BLOCK

  LlamaInstance.all.each do |instance|
    used = instance.slots_capacity - instance.slots_free
    instances_html += <<~IBLK
      <tr>
        <td>#{instance.backend&.name}</td>
        <td>#{instance.model&.name}</td>
        <td>#{used}</td>
        <td>#{instance.slots_free}</td>
        <td>#{LlamaInstanceSlot.where(llama_instance: instance).count}</td>
        <td>#{instance.port}</td>
        <td>#{instance.running ? 'Yes' : '-'}</td>
        <td>#{instance.loaded ? 'Yes' : '-'}</td>
        <td>#{instance.active ? 'Yes' : '-'}</td>
      </tr>
    IBLK
  end
  instances_html += "</table>"

  <<~HTML
    <html>
      <head><title>LLM Gateway Status</title>#{css}</head>
      <body>
        #{backends_html}
        #{gpus_html}
        #{models_html}
        #{instances_html}
        <script>
          setTimeout(function() { window.location.reload(); },
                     #{$config["update_interval"] * 1000});
        </script>
      </body>
    </html>
  HTML
end