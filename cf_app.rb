#!/usr/bin/env ruby

#########################
# Monitoring cf app output
# INPUT: ARGV[0] = user, ARGV[1] = pass, ARGV[2] = org, ARGV[3] = space, ARGV[4] = app
# OUTPUT: CPU Usage, Mem Usage, Instance Count, Errors
#########################


#TODO:
# Aufräumen
# Versschiedene Output zulassen
## Nagios output
### /=5165MB;42827;45206;0;47586 /data=607675MB;598043;631268;0;664493 /boot=26MB;401;423;0;446
###https://nagios-plugins.org/doc/guidelines.html#AEN200
## Elk output ( elasticsearch, Logstash, Kibana )
### Sollte als Json automatisch gehen, prüfen
# Performance prüfen, verbessern ( vlt. durch cache file )
## CF_TRACE=true cf app blabla
### Sowas wie try if not present relogin, try again
# Mehrere apps in dem gleichen space erlauben
# send_to_log ist aktuell output channel sollte, mehre optionen zulassen
## send_to_tcp umbennen
## send_to_stdout
## Eventuell mit config datei
# Sollte threasholds beherschen
# git repo für anlegen, nicht so faul wie der admin sein!
# Mit paramsparser arbeiten --organization anynines --space nagios --app teste1
COMPONENTS=["cf"]
API="api.de.a9s.eu"
SKIP_SSL_VERIFICATION=false
BAD_STATES=["error"]
FORMAT=:JSON
COUNT_PARAMETER=4
USAGE_STRING = "Usage: cf_app.rb <USER> <PASS> <ORG> <SPACE> <APP>"

def how_to_use
  puts USAGE_STRING
end

def validate_input
  (0..COUNT_PARAMETER).to_a.each do |index|
    if ARGV[index].nil? or ARGV[index].empty?
      how_to_use
      return_false "Not enough information provided"
      exit 2
    end
  end
  configure
end

def configure
  @user                   = ARGV[0]
  @pass                   = ARGV[1]
  @org                    = ARGV[2]
  @space                  = ARGV[3]
  @app                    = ARGV[4]
  @app_state              = nil
  @instances_present      = nil
  @instances_expected     = nil
  @instances_information  = nil
  @output                 = ""
end

def validate_environment
  unless COMPONENTS.nil?
    COMPONENTS.each do |prog|
      return_false "Program #{prog} not installed or not in PATH" if check_if_program_exists?(prog)
    end
  end
end

def check_if_program_exists?(name)
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
  run_command "cf target #{API} #{--skip-ssl-validation if SKIP_SSL_VERIFICATION}"
end

def login
  run_command "cf auth '#{@user}' '#{@pass}'"
end

def run_command(com)
  ret = `#{com};echo $?`
end

def run_command_with_return(com)
  `#{com}`
end

def choose_space_and_org
  run_command "cf t -o #{@org} -s #{@space}"
end

def app_exists?
  run_command "cf app #{@app}"
end

def retrieve_app_stats
  ret = run_command_with_return "cf app #{@app}"
  return ret
end

def parse_app_stats
  @app_state = retrieve_app_stats
  parse_instances_summary
  parse_instance_with_index
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
def parse_instance_with_index
  @instances_information = {}
  (0..(@instances_expected.to_i - 1)).each do |instance|
    @app_state.each_line do |line|
      if line.start_with?("##{instance}")
        _t, state, _t, _t, _t, cpu, memory, _t, memory_max, disk, _t, disk_max = line.split
      else
        next
      end
      @instances_information.merge!({ instance => { :state => state, :cpu => cpu, :memory => memory, :memory_max => memory_max, :disk => disk, :disk_max => disk_max } })
    end
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
    @instances_information.each do |k,v| # why k?
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
  if FORMAT.eql?(:JSON)
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

def run()
  validate_input
  validate_environment
  target
  login
  choose_space_and_org
  app_exists?
  parse_app_stats
  validate_results
  format_output
  send_to_log
  puts @output
end

run
