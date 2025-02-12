class Gpu
  attr_reader :vendor, :device, :status, :vendor_id
  UPDATE_IN = 1
  def initialize(vendor, device, vendor_id)
    @vendor = vendor
    @device = device
    @vendor_id = vendor_id
    @status = { :pstate => "",
                :memory_total => 0,
                :memory_free => 0,
                :memory_used => 0,
                :utilization_gpu => 0,
                :utilization_memory => 0,
                :clocks_current_graphics => 0,
                :clocks_current_memory => 0,
                :temperature_gpu => 0,
                :temperature_memory => 0,
                :fan_speed => 0,
                :power_draw_average => 0,
                :power_draw_instant => 0,
                :power_limit => 0
              } 
    start_monitoring
  end

  def to_json(*args)
    {
      vendor: @vendor,
      vendor_index: @vendor_id.to_i,
      model: @device,
    }.merge(@status).to_json(*args)
  end

  def start_monitoring
    case @vendor
    when "NVIDIA"
      start_monitoring_nvidia
    when "AMD"
      start_monitoring_amd
    when "Intel"
      start_monitoring_intel
    end
  end

  def start_monitoring_nvidia
    fields = "pstate,"
    fields += "memory.total,memory.free,memory.used,"
    fields += "utilization.gpu,utilization.memory,"
    fields += "clocks.current.graphics,clocks.current.memory,"
    fields += "temperature.gpu,temperature.memory,"
    fields += "fan.speed,"
    fields += "power.draw.average,power.draw.instant,power.limit"

    nvidia_smi_cmd = "nvidia-smi "
    nvidia_smi_cmd += "-i #{@vendor_id} "
    nvidia_smi_cmd += "--query-gpu #{fields} "
    nvidia_smi_cmd += "--format=csv,noheader,nounits "
    nvidia_smi_cmd += "--loop=#{UPDATE_IN}"

    Thread.new do
      loop do
        Open3.popen3(nvidia_smi_cmd) do |stdin, stdout, stderr, wait_thr|
          ios = [stdout, stderr]
          threads = []
          ios.each do |io|
            threads << Thread.new do
              until io.eof?
                line = io.gets
                puts "#{@vendor_id} #{line}" if VERBOSE
                if io == stdout
                  data = line.split(", ")
                  @status[:pstate] = data[0]
                  @status[:memory_total] = data[1].to_i
                  @status[:memory_free] = data[2].to_i
                  @status[:memory_used] = data[3].to_i
                  @status[:utilization_gpu] = data[4].to_i
                  @status[:utilization_memory] = data[5].to_i
                  @status[:clocks_current_graphics] = data[6].to_i
                  @status[:clocks_current_memory] = data[7].to_i
                  @status[:temperature_gpu] = data[8].to_i
                  @status[:temperature_memory] = data[9].to_i
                  @status[:fan_speed] = data[10].to_i
                  @status[:power_draw_average] = data[11].to_i
                  @status[:power_draw_instant] = data[12].to_i
                  @status[:power_limit] = data[13].to_i
                end
              end
            end
          end
          threads.each(&:join)
        end
        sleep UPDATE_IN
      end
    end
  end

  def start_monitoring_amd
    # TODO
  end

  def start_monitoring_intel
    # TODO
  end

  def self.enumerate
    id = 0
    gpus = {}
    blacklist = BLACKLIST
    puts "Enumerating Gpus:"
    `lspci -nn`.each_line do |line|
      next unless line =~ /VGA|3D/i
      vendor = if line =~ /NVIDIA/i
                 "NVIDIA"
               elsif line =~ /AMD/i
                 "AMD"
               elsif line =~ /Intel/i
                 "Intel"
               else
                 "Unknown"
               end
      
      # Skip if vendor is blacklisted
      next if blacklist.include?(vendor.upcase)
    
      pci_id = line.split(" ")[0]
      vendor_id = extract_vendor_id(line, vendor)
      puts "Gpu #{id}: #{vendor} Vendor ID: #{vendor_id} #{line.strip}"
      gpus[id] = Gpu.new(vendor, line.strip, vendor_id)
      id += 1
    end
    gpus
  end

  def self.extract_vendor_id(match, vendor)
    case vendor
    when "NVIDIA"
      `nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits`.each_line do |line|
        index, bus_id = line.split(",")
        domain, bus, device, function = bus_id.split(":")
        lspci_line = `lspci -nn -s #{domain}:#{bus}:#{device}.#{function}`
        return index.strip if lspci_line == match
      end
      raise "NVIDIA Gpu not found"
    when "AMD"
      # TODO
      return 0
    when "Intel"
      # TODO
      return 0
    end
    "Unknown"
  end
end