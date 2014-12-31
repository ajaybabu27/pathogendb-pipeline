require 'shellwords'

class LSFClient
  
  DEFAULT_OPTIONS = {
    :R => "rusage[mem=4000]",
    :m => "manda",
    :P => "acc_PBG",
    :W => "24:00",
    :L => "/bin/bash",
    :q => "premium",
    :R => "span[hosts=1]",
    :n => 16
  }
  
  def initialize(options=nil)
    options ||= {}
    @options = DEFAULT_OPTIONS.dup.merge(options)
  end
  
  attr_accessor :options
  
  def set_out_err(out, err)
    @options[:o] = out
    @options[:e] = err
  end
  
  def job_name(name)
    @options[:J] = name
  end
  
  def options_to_args(options=nil)
    options = @options.merge(options || {})
    args = []
    options.each do |opt, val|
      opt = opt.to_s
      if val
        args << "-#{opt}"
        args << Shellwords.escape(val) unless val == true
      end
    end
    args.join ' '
  end
  
  def bsub(script, options=nil)
    cmd = %Q<bsub #{options_to_args(options)}>
    output = nil
    IO.popen(cmd, 'w+') do |subprocess|
      subprocess.write(script)
      subprocess.close_write
      subprocess.read
    end
  end
  
  def bsub_interactive(script, options=nil)
    bsub(script, (options || {}).merge(:I => true, :tty => true))
  end
  
end