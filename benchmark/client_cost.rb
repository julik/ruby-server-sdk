# Measures what one local bucketing client costs: construction time, resident
# memory and threads, plus the one-off cost of compiling the WASM module.
#
#   bundle exec ruby -Ilib benchmark/client_cost.rb [number_of_clients] [config_json_path]
require 'devcycle-ruby-server-sdk'
require 'webmock'
require 'benchmark'

include WebMock::API

WebMock.enable!
WebMock.disable_net_connect!

CONFIG = File.read(ARGV[1] || File.expand_path('../spec/fixtures/config.json', __dir__))
stub_request(:get, %r{\Ahttps://config-cdn\.devcycle\.com/config/v2/server/})
  .to_return(status: 200, body: CONFIG, headers: { 'Etag' => 'bench' })
stub_request(:post, 'https://events.devcycle.com/v1/events/batch').to_return(status: 201, body: '{}')

def rss_mb
  if File.exist?("/proc/#{Process.pid}/status")
    File.read("/proc/#{Process.pid}/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
  else
    `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
  end
end

def options
  options = DevCycle::Options.new(disable_realtime_updates: true)
  options.instance_variable_set(:@logger, Logger.new(nil))
  options
end

count = (ARGV[0] || 20).to_i
user = DevCycle::User.new(user_id: 'bench')

GC.start
rss_start = rss_mb
compile_seconds = Benchmark.realtime { DevCycle::BucketingWasm.default }
GC.start
rss_compiled = rss_mb

threads_before = Thread.list.size
clients = []
construct_seconds = Benchmark.realtime do
  count.times { |i| clients << DevCycle::Client.new("dvc_server_bench_#{i}", options, true) }
end
clients.each { |c| c.variable_value(user, 'test-string-variable', 'default') }
GC.start
rss_clients = rss_mb
threads_with_clients = Thread.list.size

eval_seconds = Benchmark.realtime { 1000.times { clients.first.variable_value(user, 'test-string-variable', 'default') } }

close_seconds = Benchmark.realtime { clients.each(&:close) }
clients.clear
3.times { GC.start }
sleep 0.5
rss_closed = rss_mb
stores_left = ObjectSpace.each_object(Wasmtime::Store).count

puts "ruby #{RUBY_VERSION} #{RUBY_PLATFORM}, #{count} clients"
puts format('compile engine + module (once):  %8.1f ms  %+7.1f MB RSS', compile_seconds * 1000, rss_compiled - rss_start)
puts format('construct one client (avg):      %8.1f ms  %+7.1f MB RSS', construct_seconds * 1000 / count, (rss_clients - rss_compiled) / count)
puts format('threads per client:              %8.1f', (threads_with_clients - threads_before).fdiv(count))
puts format('variable_value (avg of 1000):    %8.1f us', eval_seconds * 1_000_000 / 1000)
puts format('close one client (avg):          %8.1f ms', close_seconds * 1000 / count)
puts format('RSS after closing all + GC:      %+8.1f MB vs. before clients', rss_closed - rss_compiled)
puts format('WASM stores alive after close:   %8d', stores_left)
