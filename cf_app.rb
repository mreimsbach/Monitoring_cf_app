#!/usr/bin/env ruby

#########################
# Monitoring cf app output
# INPUT: ARGV[0] = user, ARGV[1] = pass, ARGV[2] = org, ARGV[3] = space, ARGV[4] = app
# OUTPUT: CPU Usage, Mem Usage, Instance Count, Errors
#########################
require 'optparse'
require 'yaml'

#TODO:
# + Aufräumen
# Versschiedene Output zulassen
## Nagios output
### /=5165MB;42827;45206;0;47586 /data=607675MB;598043;631268;0;664493 /boot=26MB;401;423;0;446
###https://nagios-plugins.org/doc/guidelines.html#AEN200
## Elk output ( elasticsearch, Logstash, Kibana )
### Sollte als Json automatisch gehen, prüfen: erwartet JSON
# Performance prüfen, verbessern ( vlt. durch cache file )
## CF_TRACE=true cf app blabla
### Sowas wie try if not present relogin, try again
# + Mehrere apps in dem gleichen space erlauben
# send_to_log ist aktuell output channel sollte, mehre optionen zulassen
## send_to_tcp umbennen
## send_to_stdout
## + Eventuell mit config datei
# Sollte threasholds beherschen
# + git repo für anlegen, nicht so faul wie der admin sein!
# + Mit paramsparser arbeiten --organization anynines --space nagios --app teste1

API="api.de.a9s.eu"
BAD_STATES=["error"]
CONFIG_FILE_NAME="config.yml"
COUNT_PARAMETER=4
USAGE_STRING = "Usage: cf_app.rb <USER> <PASS> <ORG> <SPACE> <APP>"

def parse_input
  @options = {:user => nil, :pass => nil, :org => nil, :space => nil, :app => nil}
  parser = OptionParser.new do|opts|
    opts.banner = USAGE_STRING
    opts.on('-u', '--user user', 'Username') do |user|
    	@options[:user] = user
    end
    opts.on('-p', '--pass pass', 'Password') do |pass|
      @options[:pass] = pass
    end
    opts.on('-o', '--org org', 'Organization') do |org|
      @options[:org] = org
    end
    opts.on('-s', '--space space', 'Space') do |space|
      @options[:space] = space
    end
    opts.on('-a', '--app app1,app2,app3',Array, 'Application name list with , separated and without spaces') do |app|
      @options[:app]  = []
      @options[:app] = app
    end
    opts.on('-h', '--help', 'Displays Help') do
    	puts opts
      exit
  	end
  end
  parser.parse!
  valid_params
  configure
end

def load_config
  config = YAML::load_file(CONFIG_FILE_NAME)
  @format = config["format"]
  @skip_ssl_verification = config["skip_ssl_verification"]
  @commands = config["commands"]
end

def check_param(param)
  if param.nil? or param.empty?
    return_false "Not enough information provided"
    puts USAGE_STRING
    exit 2
  end
end
def valid_params
  @options.each do |key, value|
    check_param(value)
  end
end

def configure
  init_attributes
  load_config
end

def init_attributes
  @app_state              = nil
  @instances_present      = nil
  @instances_expected     = nil
  @instances_information  = nil
  @output                 = ""
end

def validate_environment
  unless @commands.nil?
    @commands.each do |prog|
      return_false "Program #{prog} not installed or not in PATH" if program_exists?(prog)
    end
  end
end

def program_exists?(name)
  run_command("which #{name}").eql?(1)
end

def return_false(msg)
  puts msg
  exit 2
end

def return_true(msg)
  @output = @output+msg
end

def target
  run_command "cf target #{API} #{--skip-ssl-validation if @skip_ssl_verification}"
end

def login
  run_command "cf auth '#{@options[:user]}' '#{@options[:pass]}'"
end

def run_command(com)
  `#{com};echo $?`
end

def run_command_with_return(com)
  `#{com}`
end

def choose_space_and_org
  run_command "cf t -o #{@options[:org]} -s #{@options[:space]}"
end

def app_exists?(app)
  run_command "cf app " + app
end

def retrieve_app_stats(app)
  run_command_with_return "cf app " + app
end

def parse_app_stats(app)
  @app_state = retrieve_app_stats(app)
  parse_instances_summary
  parse_instance_with_index(app)
end

def parse_instances_summary
  begin
    @instances_present, @instances_expected = @app_state.match(/instances: ([0-9]*)\/([0-9]*)\n/).captures
  rescue
    return_false "App state not parseable"
  end
end

# #0   running   2015-08-19 12:15:45 PM   0.0%   77.8M of 256M   135.7M of 1G
# Parse out running, 0.0%, 77.8M, 256M, 135.7M, 1G
# _t is used for not required values
def parse_instance_with_index(app)
  @instances_information = {}
  (0..(@instances_expected.to_i - 1)).each do |instance|
    parse_instance(instance, app)
  end
end

def parse_instance(instance, app)
  @app_state.each_line do |line|
    parse_line(line, instance, app)
  end
end

def parse_line(line, instance, app)
  if line.start_with?("##{instance}")
    _t, state, _t, _t, _t, cpu, memory, _t, memory_max, disk, _t, disk_max = line.split
  #  if FORMAT.eql?(:NAGIOS)
  #    @instances_information.merge!("APP " + @output[:app] + " - STATE=" + state.to_s + ", CPU=" + cpu.to_s + ", MEMORY=" + memory.to_s + ", DISK=" + disk.to_s + ", DISK_MAX=" + disk_max.to_s)
  #  else
      @instances_information.merge!({ instance => { :name => app, :state => state, :cpu => cpu, :memory => memory, :memory_max => memory_max, :disk => disk, :disk_max => disk_max } })
  #  end
  end
end

def validate_results
  to_megabyte
  validate_instances_summary
  validate_instances
end

def validate_instances_summary
  if @instances_present ==  @instances_expected
    return_true "#{@instances_present}/#{@instances_expected} instances;"
  else
    return_false "Instance Count not matching #{@instances_present}/#{@instances_expected}"
  end
end

def to_megabyte
    @instances_information.each do |k, v|
    [ :cpu, :memory, :memory_max, :disk, :disk_max].each do |val|
      if v[val].include?("G")
        v[val] = v[val].to_f * 1024
      else
        v[val] = v[val].to_f
      end
    end
  end
end

def validate_instances
  @instances_information.each do |index, info|
    state_check(index,info)
    cpu_allocation(index,info)
    memory_allocation(index,info)
    disk_allocation(index,info)
  end
end

def memory_allocation(index,info)
  calc(info[:memory], info[:memory_max], "MEM")
end

def cpu_allocation(index,info)
  if info[:cpu].to_f > 80
    return_false "Process is using more than 80% CPU"
  else
    return_true "Index:#{index};CPU:#{info[:cpu]};"
  end
end

def calc(current, max, type)
  begin
    if (current / max * 100).round(2) > 80
      return_false "Process is using more than 80% #{type}"
    else
      return_true "#{type}:#{(current / max * 100).round(2)}%;"
    end
  rescue
    return_false "Calculation not possible #{current} #{type} not valid"
  end
end

def disk_allocation(index,info)
  calc(info[:disk], info[:disk_max], "DISK")
end

def state_check(index,info)
  if BAD_STATES.include?(info[:state])
    return_false "Instance: #{index} in bad state (#{info[:state]}) "
  end
end

def format_output()
  if @format.eql?(:JSON)
    @output = @instances_information
  end
end

def send_to_log()
  begin
    require 'socket'
    s = TCPSocket.open 'localhost', 5000
    s.print(@instances_information)
    s.close
  rescue
  end
end
def check_app(app)
  app_exists?(app)
  parse_app_stats(app)
  validate_results
  format_output
  send_to_log
end

def run()
  parse_input
  validate_environment
  target
  login
  choose_space_and_org
  @options[:app].each do |app|
    check_app(app)
    puts @output
    init_attributes
  end
end

run
