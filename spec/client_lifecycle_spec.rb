require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'

describe 'DevCycle::Client lifecycle' do
  let(:config_url) { %r{\Ahttps://config-cdn\.devcycle\.com/config/v2/server/} }
  let(:events_url) { 'https://events.devcycle.com/v1/events/batch' }
  let(:user) { DevCycle::User.new(user_id: 'lifecycle-user') }

  def config_with_string_value(value)
    config = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'config.json')))
    config['features'][0]['variations'][0]['variables'][0]['value'] = value
    JSON.generate(config)
  end

  def stub_config(sdk_key, value)
    stub_request(:get, "https://config-cdn.devcycle.com/config/v2/server/#{sdk_key}.json")
      .to_return(status: 200, body: config_with_string_value(value),
                 headers: { 'Etag' => "etag-#{value}", 'Last-Modified' => 'Wed, 21 Oct 2026 12:00:00 GMT' })
  end

  def quiet_options(**kwargs)
    options = DevCycle::Options.new(disable_realtime_updates: true, **kwargs)
    options.instance_variable_set(:@logger, Logger.new(nil))
    options
  end

  def custom_event_types_sent_with(sdk_key)
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                            .select { |signature| signature.uri.path == '/v1/events/batch' }
                            .select { |signature| signature.headers['Authorization'] == sdk_key }
                            .flat_map { |signature| JSON.parse(signature.body)['batch'] }
                            .flat_map { |record| record['events'] }
                            .select { |event| event['type'] == 'customEvent' }
                            .map { |event| event['customType'] }
                            .uniq
  end

  def rss_kb
    `ps -o rss= -p #{Process.pid}`.to_i
  end

  before do
    WebMock.disable_net_connect!
    stub_request(:post, events_url).to_return(status: 201, body: '{}')
  end

  after do
    WebMock.allow_net_connect!
  end

  describe 'requiring the gem' do
    it 'does not create a WASM engine or start any threads' do
      script = <<~RUBY
        require 'devcycle-ruby-server-sdk'
        engines = ObjectSpace.each_object(Wasmtime::Engine).count
        puts [engines, Thread.list.size].join(',')
      RUBY
      lib = File.expand_path('../lib', __dir__)
      out, status = Open3.capture2(RbConfig.ruby, '-I', lib, '-e', script)
      expect(status).to be_success
      expect(out.strip.split("\n").last).to eq('0,1')
    end
  end

  describe 'WASM runtime ownership' do
    it 'gives each client its own store and instance built from a shared compiled module' do
      wasm = DevCycle::BucketingWasm.new
      stub_config('dvc_server_owner_a', 'a')
      stub_config('dvc_server_owner_b', 'b')
      client_a = DevCycle::Client.new('dvc_server_owner_a', quiet_options(bucketing_wasm: wasm), true)
      client_b = DevCycle::Client.new('dvc_server_owner_b', quiet_options(bucketing_wasm: wasm), true)

      runtime_a = client_a.instance_variable_get(:@local_bucketing)
      runtime_b = client_b.instance_variable_get(:@local_bucketing)
      %i[@store @linker @instance @memory].each do |ivar|
        expect(runtime_a.instance_variable_get(ivar)).not_to be_nil
        expect(runtime_a.instance_variable_get(ivar)).not_to equal(runtime_b.instance_variable_get(ivar))
      end
      expect(DevCycle::LocalBucketing.class_variables).to be_empty
    ensure
      client_a&.close
      client_b&.close
    end

    it 'uses BucketingWasm.default when no module is given' do
      expect(DevCycle::BucketingWasm.default).to equal(DevCycle::BucketingWasm.default)
      expect(quiet_options.bucketing_wasm).to be_nil
    end
  end

  describe 'multiple clients in one process' do
    it 'evaluates two clients with different SDK keys concurrently without cross-talk' do
      stub_config('dvc_server_multi_a', 'value-a')
      stub_config('dvc_server_multi_b', 'value-b')
      client_a = DevCycle::Client.new('dvc_server_multi_a', quiet_options, true)
      client_b = DevCycle::Client.new('dvc_server_multi_b', quiet_options, true)

      results = Queue.new
      threads = 8.times.map do |i|
        Thread.new do
          client, expected = i.even? ? [client_a, 'value-a'] : [client_b, 'value-b']
          200.times do |n|
            u = DevCycle::User.new(user_id: "user-#{i}-#{n}")
            results << [expected, client.variable_value(u, 'test-string-variable', 'default')]
            client.track(u, DevCycle::Event.new(type: "event-#{expected}"))
          end
        end
      end
      threads.each(&:join)

      outcomes = []
      outcomes << results.pop until results.empty?
      expect(outcomes.size).to eq(1600)
      expect(outcomes).to all(satisfy { |expected, actual| expected == actual })

      client_a.close
      client_b.close

      expect(custom_event_types_sent_with('dvc_server_multi_a')).to eq(['event-value-a'])
      expect(custom_event_types_sent_with('dvc_server_multi_b')).to eq(['event-value-b'])
    end

    it 'allows two clients with the same SDK key to hold different configs' do
      stub_request(:get, 'https://config-cdn.devcycle.com/config/v2/server/dvc_server_same_key.json')
        .to_return(status: 200, body: config_with_string_value('first'), headers: { 'Etag' => '1' })
        .then.to_return(status: 200, body: config_with_string_value('second'), headers: { 'Etag' => '2' })

      first = DevCycle::Client.new('dvc_server_same_key', quiet_options, true)
      second = DevCycle::Client.new('dvc_server_same_key', quiet_options, true)

      expect(first.variable_value(user, 'test-string-variable', 'default')).to eq('first')
      expect(second.variable_value(user, 'test-string-variable', 'default')).to eq('second')
    ensure
      first&.close
      second&.close
    end

    it 'does not leak threads or grow memory without bound when clients are created and closed repeatedly' do
      stub_request(:get, config_url).to_return(status: 200, body: config_with_string_value('loop'), headers: { 'Etag' => 'loop' })
      wasm = DevCycle::BucketingWasm.new
      cycle = lambda do |n|
        n.times do |i|
          client = DevCycle::Client.new("dvc_server_loop_#{i}", quiet_options(bucketing_wasm: wasm), true)
          expect(client.variable_value(user, 'test-string-variable', 'default')).to eq('loop')
          client.track(user, DevCycle::Event.new(type: 'loop'))
          client.close
        end
        GC.start
        sleep 0.2
      end

      cycle.call(10)
      threads_after_warmup = Thread.list.size
      rss_after_warmup = rss_kb

      cycle.call(40)
      expect(Thread.list.size).to be <= threads_after_warmup
      expect(ObjectSpace.each_object(Wasmtime::Store).count).to be <= 2
      expect(rss_kb - rss_after_warmup).to be < 32 * 1024
    end
  end

  describe 'close' do
    it 'is idempotent, stops background work and makes the client inert' do
      stub_config('dvc_server_close', 'on')
      threads_before = Thread.list
      client = DevCycle::Client.new('dvc_server_close', quiet_options, true)
      expect(client.closed?).to be(false)
      client.track(user, DevCycle::Event.new(type: 'before-close'))

      client.close
      expect(client.close).to be_nil
      expect(client.closed?).to be(true)
      expect(a_request(:post, events_url)).to have_been_made.once

      variable = client.variable(user, 'test-string-variable', 'default')
      expect(variable.value).to eq('default')
      expect(variable.isDefaulted).to be(true)
      expect(client.all_variables(user)).to eq({})
      client.track(user, DevCycle::Event.new(type: 'after-close'))
      expect(client.flush_events).to be_nil
      expect(a_request(:post, events_url)).to have_been_made.once

      sleep 0.2
      expect(Thread.list - threads_before).to all(satisfy { |t| t.name.to_s.start_with?('worker-') || !t.alive? })
    end

    it 'closes the realtime updates connection' do
      config = JSON.parse(config_with_string_value('sse'))
      config['sse'] = { 'hostname' => 'https://sse.devcycle.example', 'path' => '/stream' }
      stub_request(:get, 'https://config-cdn.devcycle.com/config/v2/server/dvc_server_sse.json')
        .to_return(status: 200, body: JSON.generate(config), headers: { 'Etag' => 'sse' })
      stub_request(:get, 'https://sse.devcycle.example/stream')
        .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

      options = DevCycle::Options.new
      options.instance_variable_set(:@logger, Logger.new(nil))
      client = DevCycle::Client.new('dvc_server_sse', options, true)
      config_manager = client.instance_variable_get(:@local_bucketing).instance_variable_get(:@config_manager)
      sse_client = config_manager.instance_variable_get(:@sse_client)
      expect(sse_client).not_to be_nil
      expect(sse_client.closed?).to be(false)

      client.close
      expect(sse_client.closed?).to be(true)
      expect(config_manager.closed?).to be(true)
    end

    it 'releases the WASM instance' do
      stub_config('dvc_server_release', 'on')
      client = DevCycle::Client.new('dvc_server_release', quiet_options, true)
      local_bucketing = client.instance_variable_get(:@local_bucketing)
      client.close
      expect(local_bucketing.instance_variable_get(:@instance)).to be_nil
      expect { local_bucketing.check_event_queue_size }.to raise_error(DevCycle::ClientClosedError)
    end
  end

  describe 'fork' do
    def run_in_fork
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        result = begin
          yield
        rescue Exception => e
          { error: "#{e.class}: #{e.message}" }
        end
        writer.write(Marshal.dump(result))
        writer.close
        exit!(0)
      end
      writer.close
      result = Marshal.load(reader.read)
      reader.close
      Process.wait(pid)
      result
    end

    before do
      skip 'fork is not available on this platform' unless Process.respond_to?(:fork)
    end

    it 'lets a child process build a fresh client while the parent client keeps working' do
      # Wasmtime on macOS handles traps with Mach ports, which do not survive
      # fork, and wasmtime-rb does not expose Config#macos_use_mach_ports.
      # Once a process has created an engine, its forked children can only
      # run WASM on threads that already did so before the fork.
      skip 'Wasmtime cannot run WASM on new threads after fork on macOS' if RUBY_PLATFORM.include?('darwin')

      stub_config('dvc_server_fork_parent', 'parent')
      parent = DevCycle::Client.new('dvc_server_fork_parent', quiet_options, true)
      parent.track(user, DevCycle::Event.new(type: 'parent-event'))

      result = run_in_fork do
        WebMock::RequestRegistry.instance.reset!
        stub_config('dvc_server_fork_child', 'child')

        inherited_error = begin
          parent.variable_value(user, 'test-string-variable', 'default')
          nil
        rescue DevCycle::ForkedClientError => e
          e.class.name
        end
        forked = parent.forked?
        parent.close
        events_sent_by_close = WebMock::RequestRegistry.instance.times_executed(
          WebMock::RequestPattern.new(:post, events_url)
        )

        child = DevCycle::Client.new('dvc_server_fork_child', quiet_options, true)
        value = child.variable_value(user, 'test-string-variable', 'default')
        child.close
        { inherited_error: inherited_error, forked: forked, events_sent_by_close: events_sent_by_close, value: value }
      end

      expect(result).to eq(
        inherited_error: 'DevCycle::ForkedClientError',
        forked: true,
        events_sent_by_close: 0,
        value: 'child'
      )
      expect(parent.forked?).to be(false)
      expect(parent.variable_value(user, 'test-string-variable', 'default')).to eq('parent')
      parent.close
      expect(a_request(:post, events_url)).to have_been_made.once
    end

    it 'lets a child build a client when the parent only required the gem' do
      script = <<~RUBY
        require 'devcycle-ruby-server-sdk'
        require 'webmock'
        include WebMock::API
        WebMock.enable!
        WebMock.disable_net_connect!
        pid = fork do
          stub_request(:get, %r{config-cdn}).to_return(status: 200, body: File.read(ARGV[0]))
          stub_request(:post, %r{events}).to_return(status: 201, body: '{}')
          options = DevCycle::Options.new(disable_realtime_updates: true)
          options.instance_variable_set(:@logger, Logger.new(nil))
          client = DevCycle::Client.new('dvc_server_clean_parent', options, true)
          value = client.variable_value(DevCycle::User.new(user_id: 'u'), 'test-string-variable', 'default')
          client.close
          exit!(value == 'on' ? 0 : 1)
        end
        Process.wait(pid)
        exit($?.exitstatus)
      RUBY
      lib = File.expand_path('../lib', __dir__)
      # libcurl touches Objective-C classes on macOS, which the runtime refuses
      # to initialize in a forked child unless this is set.
      env = { 'OBJC_DISABLE_INITIALIZE_FORK_SAFETY' => 'YES' }
      out, status = Open3.capture2e(env, RbConfig.ruby, '-I', lib, '-e', script, File.join(__dir__, 'fixtures', 'config.json'))
      expect(status).to be_success, out
    end
  end
end
