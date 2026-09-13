# frozen_string_literal: true
# Turn results/*.csv into REPORT.md + rss.svg. stdlib only.
#   ruby bench/report.rb results/

DIR    = ARGV[0] || "results"
ORDER  = %w[glibc-default glibc-arena2 glibc-trim jemalloc tcmalloc mimalloc mimalloc-v2 snmalloc]
# Validated categorical order (light surface #fcfcfb): all six checks pass,
# worst adjacent CVD dE 9.1. Three slots sit under 3:1 contrast, which the
# right-edge direct labels and the README table are the required relief for.
# Assigned in fixed order -- never recoloured when a line is added or dropped.
COLORS = %w[#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300 #4a3aa7 #e34948]
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e8e8e4"

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
W, H, PADL, PADR, PADT, PADB = 940, 460, 64, 168, 40, 56
runs.group_by(&:workload).each do |workload, wruns|
  picks = wruns.group_by(&:label).map { |label, rs| [label, rs.sort_by(&:rss_median)[rs.size / 2]] }
              .sort_by { |label, _| ORDER.index(label) || 99 }

  max_t = picks.map { |_, r| r.duration }.max
  vals  = picks.flat_map { |_, r| r.rows.map { |x| x[:rss] } }
  # Not zero-based: the whole question is a 5% gap, and a 0-211MB axis flattens
  # every line into one band at the top. Nothing is clipped -- the domain covers
  # every plotted point -- and the axis says so in words.
  lo, hi = vals.min, vals.max
  pad = (hi - lo) * 0.08
  lo -= pad; hi += pad
  sx = ->(t) { PADL + (t / max_t) * (W - PADL - PADR) }
  sy = ->(v) { H - PADB - ((v - lo) / (hi - lo)) * (H - PADT - PADB) }

  svg = +%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{W} #{H}" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="12">)
  svg << %(<rect width="#{W}" height="#{H}" fill="#{SURFACE}"/>)
  svg << %(<text x="#{PADL}" y="22" fill="#{INK}" font-size="13" font-weight="600">Resident set size over #{max_t.round}s — #{workload}</text>)

  # The window the table scores on, so the chart and the numbers agree visibly.
  wx = sx[max_t - [300.0, max_t * 0.4].min]
  svg << %(<rect x="#{wx.round(1)}" y="#{PADT}" width="#{(sx[max_t] - wx).round(1)}" height="#{H - PADT - PADB}" fill="#000" opacity="0.035"/>)
  svg << %(<text x="#{((wx + sx[max_t]) / 2).round}" y="#{PADT - 8}" text-anchor="middle" fill="#{MUTED}" font-size="10">scoring window</text>)

  5.times do |i|
    v = lo + (hi - lo) * i / 4.0
    y = sy[v].round(1)
    svg << %(<line x1="#{PADL}" y1="#{y}" x2="#{W - PADR}" y2="#{y}" stroke="#{GRID}"/>)
    svg << %(<text x="#{PADL - 8}" y="#{y + 4}" text-anchor="end" fill="#{MUTED}" font-size="11">#{(v / 1024).round} MB</text>)
  end
  svg << %(<text x="#{PADL}" y="#{H - 30}" fill="#{MUTED}" font-size="11">0s</text>)
  svg << %(<text x="#{W - PADR}" y="#{H - 30}" text-anchor="end" fill="#{MUTED}" font-size="11">#{max_t.round}s</text>)
  svg << %(<text x="#{PADL}" y="#{H - 12}" fill="#{MUTED}" font-size="10">y axis does not start at zero</text>)

  picks.each_with_index do |(label, r), i|
    c = COLORS[ORDER.index(label) || i]
    pts = r.rows.map { |x| "#{sx[x[:t]].round(1)},#{sy[x[:rss]].round(1)}" }.join(" ")
    svg << %(<polyline fill="none" stroke="#{c}" stroke-width="2" stroke-linejoin="round" points="#{pts}"/>)
    ly = PADT + 8 + i * 30
    # Colour rides the swatch, not the text: the label stays legible for the
    # slots that sit under 3:1 on this surface.
    svg << %(<line x1="#{W - PADR + 10}" y1="#{ly - 4}" x2="#{W - PADR + 28}" y2="#{ly - 4}" stroke="#{c}" stroke-width="3" stroke-linecap="round"/>)
    svg << %(<text x="#{W - PADR + 34}" y="#{ly}" fill="#{INK}" font-size="11">#{label}</text>)
    svg << %(<text x="#{W - PADR + 34}" y="#{ly + 12}" fill="#{MUTED}" font-size="10">#{(r.rss_median / 1024.0).round(1)} MB</text>)
  end
  svg << "</svg>"
  File.write(File.join(DIR, "rss-#{workload}.svg"), svg)
end

puts File.read(File.join(DIR, "REPORT.md"))
