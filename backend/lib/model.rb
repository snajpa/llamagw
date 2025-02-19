
class Model
  attr_reader :name, :slots, :context_length, :url, :files, :extra_args

  def initialize(name, slots, context_length, url, files, extra_args = [])
    @name = name
    @slots = slots || 1
    @context_length = context_length
    @url = url
    @files = files
    @extra_args = extra_args || []
    @downloading = false
  end

  def to_json(*args)
    {
      name: @name,
      slots: @slots,
      context_length: @context_length,
      files: @files,
      ready: ready?,
      url: @url,
      extra_args: @extra_args
    }.to_json(*args)
  end

  def ready?
    !@downloading #&&
     # @files.all? { |file| File.exist?(File.join(MODEL_DIR, file)) &&
     #                      File.size?(File.join(MODEL_DIR, file)) }
  end
  def download_missing_files
    @files.each do |file|
      filepath = File.join(MODEL_DIR, file)
      temp_filepath = "#{filepath}.tmp"
      unless File.exist?(filepath) && File.size?(filepath)
        puts "Downloading #{file}..."
        @downloading = true
        thread = Thread.new do
          url = format(@url, file)
          system("wget -O #{temp_filepath} #{url}")
          File.rename(temp_filepath, filepath) if File.size?(temp_filepath)
          @downloading = false
        end
      end
    end
  end

  def path
    File.join(MODEL_DIR, @files.first)
  end
end
