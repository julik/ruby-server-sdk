# DevCycle Ruby Server SDK

Welcome to the the DevCycle Ruby SDK, initially generated via the [DevCycle Bucketing API](https://docs.devcycle.com/bucketing-api/#tag/devcycle).

## Installation

Install the gem

`gem install devcycle-ruby-server-sdk`
  

## Getting Started

Please follow the [installation](#installation) procedure and then run the following code:

```ruby
# Load the gem
require 'devcycle-ruby-server-sdk'

# Setup authorization
devcycle_client = DevCycle::Client.new(ENV['DEVCYCLE_SERVER_SDK_KEY'], DevCycle::Options.new, true)
user = DevCycle::User.new({ user_id: 'user_id_example' })

begin
  # Get all features for user data
  result = devcycle_client.all_features(user)
  p result
rescue DevCycle::ApiError => e
  puts "Exception when calling DevCycle::Client->all_features: #{e}"
end

```

## Usage

To find usage documentation, visit our [docs](https://docs.devcycle.com/docs/sdk/server-side-sdks/ruby#usage).
## Client lifecycle

In local bucketing mode each `DevCycle::Client` owns its own WASM instance, its config polling (and realtime updates connection) and its event flushing. `DevCycle::Client.new` builds the instance, starts fetching the config and starts the background work. `close` stops all of it, sends pending events once and releases the WASM instance. Calling `close` again does nothing, and `closed?` tells you whether it was called.

Requiring the gem does not compile or start anything. The compiled bucketing module is shared by all clients in a process through `DevCycle::BucketingWasm.default`, or you can pass your own with `DevCycle::Options.new(bucketing_wasm: DevCycle::BucketingWasm.new)`.

Several clients can be used in one process, for example one per SDK key. Each one costs a few MB of memory, depending on the size of your project config.

### Forking servers

Background threads do not survive `fork`, so create the client in each worker process after it has been forked. A client used in a process other than the one that created it raises `DevCycle::ForkedClientError`. `forked?` tells you whether that is the case. Calling `close` on an inherited client is safe and drops its pending events, because the parent process still holds and sends them.

```ruby
# Puma (config/puma.rb), including fork_worker
on_worker_boot do # before_worker_boot in Puma 7
  $devcycle_client&.close
  $devcycle_client = DevCycle::Client.new(ENV['DEVCYCLE_SERVER_SDK_KEY'], DevCycle::Options.new)
end

# Unicorn (config/unicorn.rb)
after_fork do |_server, _worker|
  $devcycle_client&.close
  $devcycle_client = DevCycle::Client.new(ENV['DEVCYCLE_SERVER_SDK_KEY'], DevCycle::Options.new)
end
```

Close the client when the process shuts down, for example with `at_exit { $devcycle_client&.close }`, so that pending events are sent.

On macOS, Wasmtime can only run WASM in a forked process if the parent never created a Wasmtime engine, so avoid creating clients in the parent process before forking there.
