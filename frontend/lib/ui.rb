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
        <th>Gpu ID</th>
        <th>Vendor</th>
        <th>VRAM Total</th>
        <th>VRAM Used</th>
        <th>Power Usage</th>
        <th>Status</th>
      </tr>
  BLOCK

  Backend.all.each do |backend|
    backend.gpus.each do |id, gpu|
      gpus_html += <<~GBLK
        <tr>
          <td>#{backend.name}</td>
          <td>#{id}</td>
          <td>#{gpu['vendor']}</td>
          <td>#{gpu.dig('status','vram_total')} MB</td>
          <td>#{gpu.dig('status','vram_used')} MB</td>
          <td>#{gpu.dig('status','power_usage')}W</td>
          <td>#{backend.available ? 'Available' : 'Unavailable'}</td>
        </tr>
      GBLK
    end
  end
  gpus_html += "</table>"

  models_html = <<~BLOCK
    <h2>Available Models</h2>
    <table>
      <tr>
        <th>Name</th>
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
        <td>#{conf['name']}</td>
        <td>#{conf['ctx']}</td>
        <td>#{files.join(', ')}</td>
        <td>#{model_ready_on_all_backends?(model.name) ? 'Ready' : 'Downloading'}</td>
      </tr>
    MBLK
  end
  models_html += "</table>"

  instances_html = <<~BLOCK
    <h2>Active Instances</h2>
    <table>
      <tr>
        <th>Backend</th>
        <th>Model</th>
        <th>Slots In Use</th>
        <th>Capacity</th>
        <th>Port</th>
      </tr>
  BLOCK

  LlamaInstance.where(active: true).each do |instance|
    instances_html += <<~IBLK
      <tr>
        <td>#{instance.backend&.name}</td>
        <td>#{instance.model&.name}</td>
        <td>#{instance.slots_in_use}</td>
        <td>#{instance.slots_capacity}</td>
        <td>#{instance.port}</td>
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
          setTimeout(function() { window.location.reload(); }, 5000);
        </script>
      </body>
    </html>
  HTML
end