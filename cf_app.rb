#!/usr/bin/env ruby

#########################
# Monitoring cf app output
# INPUT: cf_app.rb -u <USER> -p <PASS> -o <ORG> -s <SPACE> -a <APP>
# OUTPUT: CPU Usage, Mem Usage, Instance Count, Errors
#########################
require 'optparse'
require 'yaml'
require "yaml/store"
require 'json'

API="api.de.a9s.eu"
BAD_STATES=["error"]
CONFIG_FILE_NAME="config.yml"
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
  @host = config["host"]
  @port = config["port"]
  @format = config["format"]
  @skip_ssl_verification = config["skip_ssl_verification"]
  @commands = config["commands"]
  @output_channels = config["output_channels"]
  @thresholds = config["thresholds"]
end

def check_param(param)
  if param.nil? or param.empty?
    return_false "Not enough information provided"
    puts USAGE_STRING
    exit 2
  end
end
def valid_params
  @options.each do |k, v|
    check_param(v)
  end
end

def configure
  @cache = YAML::Store.new("cache.yml")
  init_attributes
  load_config
end

def init_attributes
  @app_state              = nil
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
  run_command_with_return "cf target #{API} #{--skip-ssl-validation if @skip_ssl_verification}"
end

def login
  run_command "cf auth '#{@options[:user]}' '#{@options[:pass]}'"
end

def get_stats(guid)
  run_command "cf curl /v2/apps/#{guid}/stats"
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
  @app_state = run_command "cf app " + app
end

def retrieve_app_stats(app)
  run_command_with_return "cf app " + app
end

def parse_app_stats(app)
  parse_instances_summary
  parse_instance_with_index(app)
end

def get_apps
  run_command_with_return "cf curl /v2/apps"
end

def validate_instances
  @instances_information.each do |index, info|
    state_check(index,info)
    cpu_allocation(index,info,(@thresholds["cpu"]["warning"]).to_i,
                  (@thresholds["cpu"]["critical"]).to_i)
    memory_allocation(index,info, (@thresholds["memory"]["warning"]).to_i,
                  (@thresholds["memory"]["critical"]).to_i)
    disk_allocation(index,info, (@thresholds["disk"]["warning"]).to_i,
                  (@thresholds["disk"]["critical"]).to_i )
  end
end

def memory_allocation(index,info, warning, critical)
  calc(info[:memory], info[:memory_max],"MB", "MEM", warning, critical)
end

def cpu_allocation(index,info, warning, critical)
  calc(info[:cpu], 100, "%", "CPU", warning, critical)
end

def calc(current, max, unit, type, warning, critical)
  begin
    if current > critical
      return_false "[CRITICAL] Process is using more than #{critical}#{unit} #{type};"
    elsif current > warning
      return_true "[WARNING] Process is using more than #{warning}#{unit} #{type};"
    else
      return_true "[INFO] #{type}:#{current}#{unit};"
    end
  rescue
    return_false "Calculation not possible #{current} #{type} not valid"
  end
end

def disk_allocation(index,info, warning, critical)
  calc(info[:disk], info[:disk_max],"MB", "DISK", warning, critical)
end

def state_check(index,info)
  if BAD_STATES.include?(info[:state])
    return_false "Instance: #{index} in bad state (#{info[:state]}) "
  end
end

def format_output
  case @format
  when /\AJSON\Z/
    @output = @instances_information
  when /\ANAGIOS\Z/
    format_to_nagios
  end
end

def format_to_nagios
  @output= ""
  @instances_information.each do |k, v|
    @output+= "APP #{v[:name]} CPU Usage #{v[:cpu]}% "+
    "MEM USAGE #{v[:memory]}MB DISK USAGE #{v[:disk]}MB|"+
    "CPU=#{v[:cpu]}%;#{@thresholds['cpu']['warning']};"+
    "#{@thresholds['cpu']['critical']} MEM=#{v[:memory]}MB;"+
    "#{@thresholds['memory']['warning']};#{@thresholds['memory']['critical']}"+
    ";;#{v[:memory_max]} DISK=#{v[:disk]}MB;#{@thresholds['disk']['warning']};"+
    "#{@thresholds['disk']['critical']};;#{v[:disk_max]}"
  end
end

def send_to_tcp(msg)
  begin
    require 'socket'
    s = TCPSocket.open @host, @port
    s.print(msg)
    s.close
  rescue
  end
end

def send_to_stdout(msg)
  puts msg
end

def send_to_output(msg)
  @output_channels.each do |output|
    case output
    when /\ATCP\Z/
        send_to_tcp(msg)
    when /\ASTDOUT\Z/
        send_to_stdout(msg)
    else
        puts "Undefined Output Channel"
    end
  end

end

def store_guid(k, v)
  @cache.transaction {
    @cache[:guids] ||= {}
    @cache[:guids].merge!({k => v})
  }
end

def get_guid(app_name)
  @cache.transaction {
    guids = @cache[:guids]
    guids[app_name] unless guids.nil?
  }
end

def check_app(app_name)
  guid = get_guid(app_name)
  if guid.nil? or guid.empty?
    update_guid(app_name)
  end
  init_app_state(guid, app_name)
  parse_instance_result(app_name)
  validate_instances
  send_to_output(@output)
  format_output
  send_to_output(@output)
end

def init_app_state(guid, app_name)
  @app_state = get_stats(guid)
  if @app_state["error_code"]
    guid = update_guid(app_name)
    @app_state = get_stats(guid)
  end
  @app_state = JSON.parse(@app_state.strip.slice!(0..-2))
end

def update_guid(app)
  guid = fetch_guid(app)
  if guid.eql?(-1)
    init_app(app)
    guid = fetch_guid(app)
    if guid.eql?(-1)
      return_false("App does not exist")
    end
  end
  guid
end

def parse_instance_result(app)
  @instances_information = {}
  @app_state.each do |k, v|
    parse_json_app_stats(k, v, app)
  end
end

def parse_json_app_stats(instance, data, app)
  state = data["state"]
  memory_max = convert_byte_to_megabyte(data["stats"]["mem_quota"].to_i)
  memory = convert_byte_to_megabyte(data["stats"]["usage"]["mem"].to_i)
  cpu = (data["stats"]["usage"]["cpu"].to_f).floor
  disk = convert_byte_to_megabyte(data["stats"]["usage"]["disk"].to_i)
  disk_max = convert_byte_to_megabyte(data["stats"]["disk_quota"].to_i)

  @instances_information.merge!({ instance => { :name => app, :state => state,
    :cpu => cpu, :memory => memory, :memory_max => memory_max, :disk => disk,
    :disk_max => disk_max } })
end

def convert_byte_to_megabyte(byte)
  byte / 1024 / 1024
end

def fetch_guid(app)
  guid = -1
  result = JSON.parse(get_apps)
  result["resources"].each do |item|
    if item["entity"]["name"].eql?(app)
      guid = item["metadata"]["guid"]
      store_guid app, guid
    end
  end
  guid
end

def init_app(app_name)
  login
  choose_space_and_org
end

def run
  parse_input
  validate_environment
  target
  @options[:app].each do |app|
    check_app(app)
    init_attributes
  end
end

run
