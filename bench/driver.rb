# frozen_string_literal: true
#
# One long-running Ruby process under one allocator. Drives a workload from
# THREADS threads and samples RSS + GC.stat every SAMPLE_INTERVAL seconds.
#
#   WORKLOAD=rails|synth  DURATION=1200  THREADS=5  SAMPLE_INTERVAL=5
#   OUT=/results/jemalloc-r1.csv  LABEL=jemalloc
#
# Linux only: RSS comes from /proc/self/status.

WORKLOAD        = ENV.fetch("WORKLOAD", "rails")
DURATION        = Integer(ENV.fetch("DURATION", "1200"))
THREADS         = Integer(ENV.fetch("THREADS", "5"))
SAMPLE_INTERVAL = Float(ENV.fetch("SAMPLE_INTERVAL", "5"))
OUT             = ENV.fetch("OUT")
LABEL           = ENV.fetch("LABEL", WORKLOAD)

# Latency goes into a per-thread ring preallocated before the run, and p99 is
# computed once after the last sample. Sorting mid-run would allocate inside
# the very process whose RSS we are measuring.
RING = 16_384

# Captured once, before measuring, and stamped into every CSV. A report that
# cannot tell you which machine produced it is a report you cannot act on.
ENV_FACTS = {
  arch: RUBY_PLATFORM,
  nproc: `nproc`.strip,
  glibc: `ldd --version 2>/dev/null`.lines.first.to_s.strip[/[\d.]+\z/],
  thp: (File.read("/sys/kernel/mm/transparent_hugepage/enabled")[/\[(\w+)\]/, 1] rescue "n/a"),
  ruby: RUBY_VERSION,
  yjit: (defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?).to_s,
}.freeze

def rss_kb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
end

# --- workloads ---------------------------------------------------------------

def build_rails_work
  require "bundler/setup"
  require_relative "/app/benchmarks/railsbench/config/environment"

  app    = Rails.application
  routes = ["/posts", "/posts.json"] + (1..100).map { |i| "/posts/#{i}" }
  rng    = Random.new(0x1be52551fc152997)
  paths  = Array.new(2000) { routes.sample(random: rng) }

  lambda do |i|
    env = Rack::MockRequest.env_for("https://localhost#{paths[i % paths.size]}")
    status, _headers, body = app.call(env)
    raise "HTTP #{status} -- is railsbench seeded?" unless status == 200
    body.close
  end
end

# Rails-shaped churn without Rails: mostly short-lived strings/hashes, a small
# fraction promoted into a bounded long-lived pool. This is the workload that
# keeps running long enough to expose fragmentation.
def build_synth_work
  pool = Array.new(20_000)
  lambda do |i|
    rng  = Random.new(i)
    row  = { id: i, title: "post-#{i}-#{rng.bytes(24).unpack1('H*')}",
             body: "x" * (64 + i % 4096), tags: Array.new(8) { |j| "tag#{(i + j) % 512}" } }
    json = row.to_s
    pool[i % pool.size] = json if i % 50 == 0
    json.bytesize
  end
end

# Q9: YJIT on, one configuration. Silently falling back to the interpreter
# would measure a Ruby nobody runs.
abort "YJIT is not enabled (RUBYOPT=--yjit?)" unless ENV_FACTS[:yjit] == "true"

work = WORKLOAD == "rails" ? build_rails_work : build_synth_work

# --- run ---------------------------------------------------------------------

counters = Array.new(THREADS, 0)
rings    = Array.new(THREADS) { Array.new(RING, 0.0) }
stop     = false

work.call(0) # touch every code path once so boot cost is not sampled as churn

workers = Array.new(THREADS) do |t|
  Thread.new do
    n = 0
    until stop
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      work.call(t * 1_000_000 + n)
      rings[t][n % RING] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      n += 1
      counters[t] = n
    end
  end
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
File.open(OUT, "w") do |f|
  f.puts "t_s,rss_kb,reqs,gc_count,major_gc_count,heap_live_slots,malloc_increase_bytes"
  loop do
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    s = GC.stat
    f.puts [elapsed.round(1), rss_kb, counters.sum, s[:count].to_i,
            s[:major_gc_count].to_i, s[:heap_live_slots].to_i,
            s[:malloc_increase_bytes].to_i].join(",")
    f.flush
    break if elapsed >= DURATION
    sleep SAMPLE_INTERVAL
  end

  stop = true
  workers.each(&:join)

  # Safe to allocate freely now: sampling is over.
  seen = counters.each_with_index.flat_map { |n, t| rings[t].first([n, RING].min) }.sort
  p99  = seen.empty? ? 0.0 : seen[(seen.size * 0.99).floor] * 1000
  f.puts format("# label=%s workload=%s threads=%d p99_ms=%.3f total_reqs=%d %s",
                LABEL, WORKLOAD, THREADS, p99, counters.sum,
                ENV_FACTS.map { |k, v| "#{k}=#{v}" }.join(" "))
end

warn "#{LABEL}: #{counters.sum} reqs in #{DURATION}s -> #{OUT}"
