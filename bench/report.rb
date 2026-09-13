# frozen_string_literal: true
# Turn results/*.csv into REPORT.md + rss.svg. stdlib only.
#   ruby bench/report.rb results/

DIR    = ARGV[0] || "results"
ORDER  = %w[glibc-default glibc-arena2 jemalloc tcmalloc mimalloc]
COLORS = { "glibc-default" => "#888888", "glibc-arena2" => "#3b7dd8",
           "jemalloc" => "#1f9d55", "tcmalloc" => "#d97706", "mimalloc" => "#c2410c" }

Run = Struct.new(:workload, :label, :round, :rows, :p99_ms, :duration, :facts, keyword_init: true) do
  # Drop boot/warmup, then score on a trailing window -- RSS right after boot
  # says nothing about fragmentation.
  def warmup = [120.0, duration * 0.2].min
  def window = [300.0, duration * 0.4].min
  def scored = rows.select { |r| r[:t] >= duration - window }
  def rss_median = median(scored.map { |r| r[:rss] })
  def rss_peak = rows.map { |r| r[:rss] }.max
  def reqs_per_s
    a = rows.find { |r| r[:t] >= warmup } || rows.first
    b = rows.last
    dt = b[:t] - a[:t]
    dt <= 0 ? 0.0 : (b[:reqs] - a[:reqs]) / dt
  end
  def gc_count = rows.last[:gc]
  def major_gc = rows.last[:major_gc]
  def median(a) = a.empty? ? 0 : a.sort[a.size / 2]
end

runs = Dir[File.join(DIR, "*.csv")].map do |path|
  lines = File.readlines(path, chomp: true)
  meta  = lines.find { |l| l.start_with?("#") } || ""
  rows  = lines.drop(1).reject { |l| l.empty? || l.start_with?("#") }.map do |l|
    t, rss, reqs, gc, major, live, mi = l.split(",")
    { t: t.to_f, rss: rss.to_i, reqs: reqs.to_i, gc: gc.to_i,
      major_gc: major.to_i, live: live.to_i, malloc_increase: mi.to_i }
  end
  next if rows.empty?
  workload, label, round = File.basename(path, ".csv").match(/\A(\w+)-(.+)-r(\d+)\z/)&.captures
  Run.new(workload: workload, label: label, round: round.to_i, rows: rows,
          p99_ms: meta[/p99_ms=([\d.]+)/, 1].to_f, duration: rows.last[:t],
          facts: meta.scan(/(arch|nproc|glibc|thp|ruby|yjit)=(\S+)/).to_h)
end.compact

abort "no CSVs in #{DIR}" if runs.empty?

def med(a) = a.sort[a.size / 2]

out = []
runs.group_by(&:workload).each do |workload, wruns|
  by_label = wruns.group_by(&:label)
  base = by_label["glibc-default"]&.then { |rs| med(rs.map(&:rss_median)) }

  out << "## workload: #{workload}"
  out << ""
  out << "rounds: #{by_label.values.map(&:size).max} · duration: #{wruns.first.duration.round}s · " \
         "RSS = median over final window, after warmup"
  out << ""
  out << "| allocator | RSS median | vs glibc | RSS peak | req/s | p99 ms | GC | major GC |"
  out << "|---|--:|--:|--:|--:|--:|--:|--:|"
  (ORDER & by_label.keys).each do |label|
    rs = by_label[label]
    rss = med(rs.map(&:rss_median))
    rel = base && base > 0 ? format("%+.1f%%", (rss - base) * 100.0 / base) : "-"
    out << format("| %s | %.1f MB | %s | %.1f MB | %.1f | %.2f | %d | %d |",
                  label, rss / 1024.0, rel, med(rs.map(&:rss_peak)) / 1024.0,
                  med(rs.map(&:reqs_per_s)), med(rs.map(&:p99_ms)),
                  med(rs.map(&:gc_count)), med(rs.map(&:major_gc)))
  end
  out << ""
  out << "GC columns are the tell: an allocator that wins on RSS while running more"
  out << "major GCs did not save memory, it spent CPU."
  out << ""
end

f = runs.first.facts || {}
header = "# Ruby allocator benchmark\n\n" \
         "`#{f["arch"]}` · #{f["nproc"]} cores · glibc #{f["glibc"]} · THP `#{f["thp"]}` · " \
         "ruby #{f["ruby"]} · YJIT #{f["yjit"]}\n\n"
File.write(File.join(DIR, "REPORT.md"), header + out.join("\n") + "\n")

# --- RSS over time, median round per allocator --------------------------------
W, H, PAD = 900, 420, 56
runs.group_by(&:workload).each do |workload, wruns|
  picks = wruns.group_by(&:label).map do |label, rs|
    [label, rs.sort_by(&:rss_median)[rs.size / 2]]
  end.sort_by { |label, _| ORDER.index(label) || 99 }

  max_t = picks.map { |_, r| r.duration }.max
  max_y = picks.flat_map { |_, r| r.rows.map { |x| x[:rss] } }.max * 1.08
  sx = ->(t) { PAD + (t / max_t) * (W - PAD - 150) }
  sy = ->(v) { H - PAD - (v / max_y) * (H - 2 * PAD) }

  svg = +%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{W} #{H}" font-family="ui-monospace,monospace" font-size="11">)
  svg << %(<rect width="#{W}" height="#{H}" fill="#fff"/>)
  4.downto(0) do |i|
    v = max_y * i / 4
    svg << %(<line x1="#{PAD}" y1="#{sy[v].round(1)}" x2="#{W - 150}" y2="#{sy[v].round(1)}" stroke="#e5e5e5"/>)
    svg << %(<text x="#{PAD - 6}" y="#{sy[v].round(1) + 4}" text-anchor="end" fill="#666">#{(v / 1024).round} MB</text>)
  end
  svg << %(<text x="#{PAD}" y="#{H - 16}" fill="#666">0s</text>)
  svg << %(<text x="#{W - 150}" y="#{H - 16}" text-anchor="end" fill="#666">#{max_t.round}s</text>)

  picks.each_with_index do |(label, r), i|
    pts = r.rows.map { |x| "#{sx[x[:t]].round(1)},#{sy[x[:rss]].round(1)}" }.join(" ")
    c = COLORS[label] || "#333"
    svg << %(<polyline fill="none" stroke="#{c}" stroke-width="1.6" points="#{pts}"/>)
    svg << %(<text x="#{W - 138}" y="#{PAD + i * 18}" fill="#{c}">#{label}</text>)
  end
  svg << "</svg>"
  File.write(File.join(DIR, "rss-#{workload}.svg"), svg)
end

puts File.read(File.join(DIR, "REPORT.md"))
