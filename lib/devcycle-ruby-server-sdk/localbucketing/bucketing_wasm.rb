require 'wasmtime'

module DevCycle
  # Holds the Wasmtime engine and the compiled bucketing module.
  #
  # Both are immutable once built and safe to share between threads and
  # between clients, so several clients can reuse one BucketingWasm and only
  # pay the compilation cost once. Each client still creates its own store,
  # linker and instance from it, so clients never share WASM memory.
  #
  # Nothing is compiled when the gem is required. The engine and module are
  # built when a BucketingWasm is created, which for the default instance is
  # the first time a local bucketing client is constructed.
  #
  # @example Sharing one compiled module explicitly
  #   wasm = DevCycle::BucketingWasm.new
  #   options = DevCycle::Options.new(bucketing_wasm: wasm)
  #   client_a = DevCycle::Client.new(sdk_key_a, options)
  #   client_b = DevCycle::Client.new(sdk_key_b, options)
  class BucketingWasm
    DEFAULT_WASM_PATH = File.join(__dir__, 'bucketing-lib.release.wasm')

    attr_reader :engine
    attr_reader :wasm_module

    @default_mutex = Mutex.new

    class << self
      # The instance used by clients that are not given one through
      # Options#bucketing_wasm. It is created on first use and then reused
      # for the rest of the process.
      #
      # @return [BucketingWasm]
      def default
        @default_mutex.synchronize do
          @default ||= new
        end
      end
    end

    # @param wasm_path [String] path to the bucketing library WASM file
    def initialize(wasm_path: DEFAULT_WASM_PATH)
      # Parallel compilation is disabled so that compiling does not start a
      # thread pool, which could deadlock a process forked afterwards.
      @engine = Wasmtime::Engine.new(parallel_compilation: false)
      @wasm_module = Wasmtime::Module.from_file(@engine, wasm_path)
    end
  end
end
