#!/usr/bin/ruby

pwd = File.expand_path(File.join(File.dirname(__FILE__), ".."))
Dir.chdir(pwd)

NERVE_PORT = 4567
DATA_DIR_BASE = "/tmp/nervetest"

require './lib/nerve'
require 'open3'
include Nerve

class NerveInstance
  attr_reader :port

  class << self
    def register(nerve)
      @all_nerves ||= []
      @all_nerves << nerve
    end

    def all
      @all_nerves || []
    end
  end

  def initialize(port=NERVE_PORT)
    self.class.register(self)
    @port = port
  end

  def datadir
    File.expand_path(File.join(DATA_DIR_BASE, "nerve-#{@port}"))
  end

  def run!
    puts "Starting nerve on port #{@port}..."
    FileUtils.mkdir_p(datadir) unless File.exists?(datadir)
    cmd = "rackup -p #{@port}"
    @stdin, @stdout, @stderr, @wait_thr =
      Open3.popen3({"DATADIR" => datadir}, cmd)
    monitor
    wait_for_ready
  end

  def stop
    return unless alive?
    puts "Stopping nerve on port #{@port}, PID #{@wait_thr.pid}..."
    Process.kill("KILL", @wait_thr.pid)

    @stdout.close
    @stderr.close
    wait_for(5) { !alive? }
  end

  def restart
    stop if alive?
    run!
  end

  def monitor
    Thread.new do
      monitor_stream(@stdout) do |msg|
        print msg.light_black
      end
    end

    Thread.new do
      monitor_stream(@stderr) do |msg|
        print msg.light_black
      end
    end
  end

  def monitor_stream(stream)
    begin
      while alive? && !stream.eof?
        s = ""
        begin
          s = stream.read_nonblock(1024)
          yield(s)
        rescue IO::WaitReadable
        end
      end
    rescue IOError
    end
  end

  def wait_for_ready(max_time=30)
    wait_for(30) { ready? }
  end

  def alive?
    return false unless @wait_thr
    begin
      Process.kill(0, @wait_thr.pid)
      true
    rescue Errno::ESRCH
      false
    end
  end

  def ready?
    return false unless alive?
    begin
      request(:get, "endpoints", nil,
        silent:true,
        max_attempts:1,
        log_error:false)
    rescue Exception => exc
      false
    end
  end

  def base_url
    "http://localhost:#{port}"
  end

  def url(endpoint)
    endpoint = endpoint[1..-1] while endpoint[0] == '/'
    "#{base_url}/#{endpoint}"
  end

  def request(method, endpoint, data=nil, params={})
    log "#{method.to_s.upcase} #{endpoint}".green.bold unless params[:silent]
    web(method, url(endpoint), data, params)
  end

  def requestj(method, endpoint, data=nil, params={})
    JSON.parse(request(method, endpoint, data, params), symbolize_names:true)
  end
end

def wait_for(max, delay=0.1)
  deadline = Time.now + max
  while Time.now < deadline
    value = yield
    return value if value
    sleep delay
  end

  false
end

def clear_data!
  puts "Clearing nerve data..."
  FileUtils.rm_rf(DATA_DIR_BASE)
end

def check!(msg="check failed")
  exception = nil
  begin
    return if yield
  rescue Exception => exc
    exception = exc
  end

  log_error("Check failed at " + caller[0])
  if exception then
    log_error(msg, exception)
  else
    log_error(msg)
  end

  exit 1
end

at_exit do
  NerveInstance.all.each { |nerve| nerve.stop }
end

clear_data!
$nerve = NerveInstance.new
$nerve.run!



###
# make sure we have a blank slate
check! { $nerve.requestj(:get, "endpoints").empty? }



###
# set a value
check! { $nerve.request(:post, "foo/bar", "example") }

# check that the value and endpoint were created and persist through restarts
2.times do |n|
  check! { $nerve.request(:get, "foo/bar") == "example" }
  check! { $nerve.requestj(:get, "endpoints").select { |ep| ep[:path] == "foo/bar" } }
  check! { $nerve.requestj(:get, "endpoints").select { |ep| ep[:id] == "1" } }
  $nerve.restart if n == 0
end

# change the value
check! { $nerve.request(:post, "foo/bar", "changed") }
check! { $nerve.request(:get, "foo/bar") == "changed" }

# try deleting the value
check! { $nerve.request(:delete, "foo/bar") }
check! { $nerve.requestj(:get, "endpoints").empty? }
check! do
  $nerve.request(:get, "foo/bar", nil, tolerate_error:true).is_a?(RestClient::NotFound)
end



###
# set up a logged value
$nerve.request(:put, "logged", {logged:true, datatype:"integer"}.to_json)
ep = $nerve.requestj(:get, "endpoints").first
check! { ep[:path] == "/logged" }
check! { ep[:datatype] == "integer" }

# fill up the log
count = 10
count.times do |n|
  $nerve.request(:post, "logged", n.to_s)
  check! { $nerve.request(:get, "logged") == n.to_s }
end

# now see if the table actually has that data...
db = SQLite3::Database.new(File.join($nerve.datadir, "logged_log.db"))
db.type_translation = true
rows = db.execute("select value from logged_log order by log_id asc")
check! { rows.count == count }
count.times do |n|
  check! { rows[n].first == n }
end
db.close



###
# clear it out and make another one that autoprunes on count
max_log_count = 5
$nerve.request(:delete, "/logged")
$nerve.request(:put, "logged", {logged:true, datatype:"real", max_log_count:max_log_count}.to_json)

count.times do |n|
  $nerve.request(:post, "logged", (0.1*n).to_s)
  check! { $nerve.request(:get, "logged") == (0.1*n).to_s }
end

# table should only have the most recent values
db = SQLite3::Database.new(File.join($nerve.datadir, "logged_log.db"))
db.type_translation = true
rows = db.execute("select value from logged_log order by log_id asc")
puts rows.count
check! { rows.count == max_log_count }
check! { rows.last.first == 0.1*(count-1) }
db.close



###
# now let's do one that autoprunes on time
max_log_age_ms = 100
$nerve.request(:delete, "/logged")
$nerve.request(:put, "logged", {logged:true, datatype:"text", max_log_age_ms:max_log_age_ms}.to_json)

count.times do |n|
  sleep 0.001*(max_log_age_ms + 1) if n == count - 1
  $nerve.request(:post, "logged", "%value-#{n}")
  check! { $nerve.request(:get, "logged") == "%value-#{n}" }
end

# table should only have the most recent value
db = SQLite3::Database.new(File.join($nerve.datadir, "logged_log.db"))
db.type_translation = true
rows = db.execute("select value from logged_log order by log_id asc")
puts rows.count
check! { rows.count == 1 }
check! { rows.last.first == "%value-#{count-1}" }
db.close
$nerve.request(:delete, "/logged")


###
# now let's try a GET-through
nerve2 = NerveInstance.new(NERVE_PORT+1)
nerve2.run!
nerve2.request(:post, "test", "hello world")
$nerve.request(:put, "getthru", {source: nerve2.url("test")}.to_json)
check! { $nerve.requestj(:get, "endpoints").first[:source] == nerve2.url("test") }
check! { $nerve.request(:get, "getthru") == "hello world" }
nerve2.stop
$nerve.request(:delete, "getthru")


###
# and a script
script = "echo -n test output"
$nerve.request(:put, "script", {source:script}.to_json)
check! { $nerve.requestj(:get, "endpoints").first[:source] == script }
check! { $nerve.request(:get, "script") == "test output" }
$nerve.request(:delete, "script")



###
# and a POSTback...
nerve2 = NerveInstance.new(NERVE_PORT+1)
nerve2.run!

$nerve.request(:put, "postback", {}.to_json)
$nerve.request(:post, "callbacks", {
  path:"/postback",
  url:nerve2.url("copy")
}.to_json)

ep = $nerve.requestj(:get, "endpoints").first
check! { ep[:source] == "keystore" }
puts ep.to_json
check! { ep[:callbacks].count == 1 }
check! { ep[:callbacks].first[:url] == nerve2.url("copy") }
check! { ep[:callbacks].first[:method] == "post" }
check! { ep[:callbacks].first[:type] == "update" }

$nerve.request(:post, "postback", "carbon copy")
check! { $nerve.request(:get, "postback") == "carbon copy" }
check! { nerve2.request(:get, "copy") == "carbon copy" }

# we should get it on a repeat, too
nerve2.request(:delete, "copy")
$nerve.request(:post, "postback", "carbon copy")
check! { $nerve.request(:get, "postback") == "carbon copy" }
check! { nerve2.request(:get, "copy") == "carbon copy" }

$nerve.request(:delete, "postback")
nerve2.stop



###
# now a change-only postback...
nerve2 = NerveInstance.new(NERVE_PORT+1)
nerve2.run!

$nerve.request(:put, "postback", {}.to_json)
$nerve.request(:post, "callbacks", {
  path:"/postback",
  url:nerve2.url("copy"),
  type:"change"
}.to_json)

ep = $nerve.requestj(:get, "endpoints").first
check! { ep[:source] == "keystore" }
puts ep.to_json
check! { ep[:callbacks].count == 1 }
check! { ep[:callbacks].first[:url] == nerve2.url("copy") }
check! { ep[:callbacks].first[:method] == "post" }
check! { ep[:callbacks].first[:type] == "change" }

$nerve.request(:post, "postback", "carbon copy")
check! { $nerve.request(:get, "postback") == "carbon copy" }
check! { nerve2.request(:get, "copy") == "carbon copy" }

# this time we should NOT see the repeat!
nerve2.request(:delete, "copy")
$nerve.request(:post, "postback", "carbon copy")
check! { $nerve.request(:get, "postback") == "carbon copy" }
check! { nerve2.request(:get, "copy", nil, tolerate_error:true).is_a? RestClient::NotFound }

$nerve.request(:delete, "postback")
nerve2.stop


###
# Check to see if poll intervals work

poll_interval_ms = 100
slop_ms = 50 # updates will come slightly slower than interval; how much extra time to allow?
num_ideal_polls = 10

total_time_ms = num_ideal_polls * poll_interval_ms
max_time_per_poll = poll_interval_ms + slop_ms
min_expected_polls = (total_time_ms / max_time_per_poll).floor

$nerve.request(:put, "polled", {
  poll_interval_ms:poll_interval_ms,
  source:"date +%H:%M:%S.%N",
  logged:true
}.to_json)
sleep 0.001*total_time_ms

PollMonitor.shared.stop!
wait_for(30) { PollMonitor.shared.stopped? }

db = SQLite3::Database.new(File.join($nerve.datadir, "polled_log.db"))
db.type_translation = true
rows = db.execute("select value from polled_log order by log_id asc")
check! { rows.count >= min_expected_polls }
check! { rows.count <= num_ideal_polls }
db.close
