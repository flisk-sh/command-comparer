#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the data in _data/ (tools.yml, tabs.yml, compare/<tab>.yml).
#
#   ruby scripts/check-data.rb                 structure: every tab has a cell per task and tool,
#                                              every cell has an https source, no TODO left
#   ruby scripts/check-data.rb --tab ID        only that tab (repeat the flag for more)
#   ruby scripts/check-data.rb --todo-ok       allow `TODO` placeholders (work in progress)
#   ruby scripts/check-data.rb --flisk         also run each Flisk command's subcommand and
#                                              flags against the installed `flisk --help`
#   ruby scripts/check-data.rb --links         also fetch every source URL and expect a 2xx
#
# Exit code 1 when anything fails.

require "yaml"
require "uri"
require "net/http"
require "open3"

DATA_DIR = ENV["DATA_DIR"] || File.expand_path("../_data", __dir__)
STATUSES = %w[match partial none na].freeze
NOTE_MAX = 110
BLURB_MAX = 100

check_flisk = ARGV.include?("--flisk")
check_links = ARGV.include?("--links")
todo_ok = ARGV.include?("--todo-ok")
only = ARGV.each_with_index.select { |a, _| a == "--tab" }.map { |_, i| ARGV[i + 1] }.compact

errors = []
warnings = []

tools = YAML.safe_load(File.read(File.join(DATA_DIR, "tools.yml")))
tabs = YAML.safe_load(File.read(File.join(DATA_DIR, "tabs.yml")))
meta = YAML.safe_load(File.read(File.join(DATA_DIR, "meta.yml")))

tools.each do |id, t|
  %w[name tagline site docs].each do |k|
    errors << "tool #{id}: missing #{k}" if t[k].to_s.strip.empty?
  end
end

tab_ids = tabs.map { |t| t["id"] }
errors << "duplicate tab ids" unless tab_ids.uniq.size == tab_ids.size
unknown_only = only - tab_ids
errors << "--tab: unknown tab #{unknown_only.join(', ')}" unless unknown_only.empty?
selected = only.empty? ? tabs : tabs.select { |t| only.include?(t["id"]) }

def commands_of(cell)
  Array(cell["cmd"]).map(&:to_s)
end

todo_count = 0
cell_count = 0
task_count = 0
data_by_tab = {}

selected.each do |tab|
  tid = tab["id"]
  %w[id name title blurb tools].each do |k|
    errors << "tab #{tid}: missing #{k}" if tab[k].nil? || tab[k].to_s.strip.empty?
  end
  warnings << "tab #{tid}: blurb is #{tab['blurb'].to_s.size} chars, keep it under #{BLURB_MAX}" if tab["blurb"].to_s.size > BLURB_MAX

  tab_tools = tab["tools"] || []
  errors << "tab #{tid}: Flisk must be the first tool" unless tab_tools.first == "flisk"
  errors << "tab #{tid}: duplicate tools" unless tab_tools.uniq.size == tab_tools.size
  (tab_tools - tools.keys).each { |t| errors << "tab #{tid}: tool #{t} is not in tools.yml" }

  path = File.join(DATA_DIR, "compare", "#{tid}.yml")
  unless File.exist?(path)
    errors << "tab #{tid}: missing #{path}"
    next
  end
  data = YAML.safe_load(File.read(path))
  data_by_tab[tid] = data
  tasks = data["tasks"] || []
  errors << "tab #{tid}: no tasks" if tasks.empty?
  ids = tasks.map { |t| t["id"] }
  errors << "tab #{tid}: duplicate task ids" unless ids.uniq.size == ids.size

  tasks.each do |task|
    task_count += 1
    where_task = "#{tid} / #{task['id']}"
    errors << "#{where_task}: missing task title" if task["task"].to_s.strip.empty?
    cells = task["cells"] || {}

    extra = cells.keys - tab_tools
    errors << "#{where_task}: cells for tools not in this tab: #{extra.join(', ')}" unless extra.empty?

    tab_tools.each do |tool|
      cell_count += 1
      cell = cells[tool]
      where = "#{where_task} / #{tool}"

      if cell.nil?
        errors << "#{where}: missing cell (use status: none for no equivalent)"
        next
      end
      if cell == "TODO"
        todo_count += 1
        errors << "#{where}: still TODO" unless todo_ok
        next
      end
      unless cell.is_a?(Hash)
        errors << "#{where}: cell must be a mapping"
        next
      end

      status = cell["status"] || "match"
      errors << "#{where}: bad status #{status.inspect}" unless STATUSES.include?(status)

      begin
        uri = URI.parse(cell["source"].to_s)
        errors << "#{where}: source must be an https URL" unless uri.is_a?(URI::HTTPS) && uri.host
      rescue URI::InvalidURIError
        errors << "#{where}: source is not a valid URL"
      end

      cmds = commands_of(cell)
      if %w[match partial].include?(status)
        errors << "#{where}: status #{status} needs a cmd" if cmds.empty?
      elsif !cmds.empty?
        errors << "#{where}: status #{status} must not have a cmd"
      end
      errors << "#{where}: cmd entries must be non-empty, trimmed strings" if cmds.any? { |c| c.strip.empty? || c != c.strip }
      errors << "#{where}: status partial needs a note saying why" if status == "partial" && cell["note"].to_s.strip.empty?
      warnings << "#{where}: note is #{cell['note'].to_s.size} chars, keep it under #{NOTE_MAX}" if cell["note"].to_s.size > NOTE_MAX
    end
  end
end

# --- Flisk commands against the installed CLI ---------------------------------
if check_flisk
  def run_flisk(*args)
    out, status = Open3.capture2e("flisk", *args)
    [out.force_encoding(Encoding::UTF_8).scrub, status]
  rescue Errno::ENOENT
    [nil, nil]
  end

  version_out, = run_flisk("--version")
  if version_out.nil?
    errors << "--flisk: the flisk CLI is not on PATH"
  else
    installed = version_out.strip.split("\n").last.to_s.strip
    expected = meta.dig("checked", "flisk").to_s
    warnings << "installed flisk is #{installed}, data was checked against #{expected}" unless installed == expected

    top, = run_flisk("--help")
    nested = { "config" => true, "agent" => true }
    help_cache = {}
    seen = {}

    data_by_tab.each do |tid, data|
      data["tasks"].each do |task|
        cell = task["cells"]["flisk"]
        next unless cell.is_a?(Hash)

        commands_of(cell).each do |cmd|
          next if seen[cmd]

          seen[cmd] = true
          where = "#{tid} / #{task['id']} / flisk: `#{cmd}`"
          tokens = cmd.split
          first = tokens.shift
          # skills are installed with npx, not flisk; only flisk commands are checked here
          next if first == "npx"

          unless first == "flisk"
            errors << "#{where}: must start with flisk"
            next
          end

          sub = tokens.first
          if sub.nil? || sub.start_with?("-")
            errors << "#{where}: needs a subcommand"
            next
          end
          # A command or one of its aliases (such as `init` for `project`) prints its own
          # "Usage: flisk project|init ..." line. An unknown word prints the root help instead.
          sub_help, = help_cache[[sub, "--help"]] ||= run_flisk(sub, "--help")
          unless sub_help.lines.first(3).any? { |l| l =~ /Usage: flisk (?:[\w-]+\|)*#{Regexp.escape(sub)}(?:\|[\w-]+)*\b/ } ||
                 top =~ /^\s+(?:[\w-]+,\s*)*#{Regexp.escape(sub)}(?:,\s*[\w-]+)*\s{2,}/
            errors << "#{where}: `flisk #{sub}` is not a flisk command"
            next
          end

          help_args = [sub, "--help"]
          help_args = [sub, "help", tokens[1]] if nested[sub] && tokens[1] && !tokens[1].start_with?("-")
          help, = help_cache[help_args] ||= run_flisk(*help_args)

          if help.include?("could not run")
            warnings << "#{where}: help is not available here (#{help.strip.lines.first.strip}); flags not checked"
            next
          end

          tokens.select { |t| t.start_with?("-") }.each do |flag|
            errors << "#{where}: flag #{flag} not in `flisk #{help_args.join(' ')}`" unless help.include?(flag)
          end
        end
      end
    end
  end
end

# --- Source URLs ---------------------------------------------------------------
if check_links
  urls = []
  tools.each_value { |t| urls << t["site"] << t["docs"] }
  data_by_tab.each_value do |data|
    data["tasks"].each do |task|
      task["cells"].each_value { |c| urls << c["source"] if c.is_a?(Hash) }
    end
  end

  def fetch_status(url, limit = 5)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 25
    req = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "command-comparer-link-check")
    res = http.request(req)
    if res.is_a?(Net::HTTPRedirection) && limit.positive?
      return fetch_status(URI.join(url, res["location"]).to_s, limit - 1)
    end

    res.code.to_i
  end

  urls.compact.map { |u| u.split("#").first }.uniq.each do |base|
    code = nil
    3.times do
      begin
        code = fetch_status(base)
      rescue StandardError => e
        code = e.class.name
      end
      break if code.is_a?(Integer) && code < 400

      sleep 2
    end
    if code.is_a?(Integer) && code < 400
      puts "ok   #{code} #{base}"
    else
      errors << "link: #{base} returned #{code}"
    end
  end
end

warnings.each { |w| warn "warning: #{w}" }

if errors.empty?
  msg = "OK: #{selected.size} tabs, #{task_count} tasks, #{cell_count} cells"
  msg += todo_ok ? " (#{todo_count} still TODO)." : ", every cell has a source."
  puts msg
else
  warn "#{errors.size} problem(s):"
  errors.first(60).each { |e| warn "  - #{e}" }
  warn "  ... and #{errors.size - 60} more" if errors.size > 60
  exit 1
end
