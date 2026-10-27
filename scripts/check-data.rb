#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks _data/commands.yml.
#
#   ruby scripts/check-data.rb            structure: every task has a cell per tool,
#                                         every cell has an https source
#   ruby scripts/check-data.rb --flisk    also run each Flisk command's subcommand and
#                                         flags against the installed `flisk --help`
#   ruby scripts/check-data.rb --links    also fetch every source URL and expect a 2xx
#
# Exit code 1 when anything fails.

require "yaml"
require "uri"
require "net/http"
require "open3"

DATA = ENV["COMMANDS_YML"] || File.expand_path("../_data/commands.yml", __dir__)
STATUSES = %w[match partial none na].freeze

check_flisk = ARGV.include?("--flisk")
check_links = ARGV.include?("--links")

data = YAML.safe_load(File.read(DATA))
errors = []
warnings = []

tools = data.fetch("tools")
tool_ids = tools.map { |t| t.fetch("id") }
category_ids = data.fetch("categories").map { |c| c.fetch("id") }

errors << "Flisk must be the first tool (found #{tool_ids.first.inspect})" unless tool_ids.first == "flisk"
errors << "duplicate tool ids" unless tool_ids.uniq.size == tool_ids.size

tools.each do |t|
  %w[id name tagline site docs what scope why].each do |k|
    errors << "tool #{t['id']}: missing #{k}" if t[k].to_s.strip.empty?
  end
end

task_ids = data.fetch("tasks").map { |t| t["id"] }
errors << "duplicate task ids" unless task_ids.uniq.size == task_ids.size

def commands_of(cell)
  Array(cell["cmd"]).map(&:to_s)
end

data.fetch("tasks").each do |task|
  id = task["id"]
  errors << "task #{id}: unknown category #{task['category'].inspect}" unless category_ids.include?(task["category"])
  errors << "task #{id}: missing task title" if task["task"].to_s.strip.empty?
  cells = task["cells"] || {}

  extra = cells.keys - tool_ids
  errors << "task #{id}: unknown tools #{extra.join(', ')}" unless extra.empty?

  tool_ids.each do |tid|
    cell = cells[tid]
    where = "task #{id} / #{tid}"
    if cell.nil?
      errors << "#{where}: missing cell (use status: none for no equivalent)"
      next
    end

    status = cell["status"] || "match"
    errors << "#{where}: bad status #{status.inspect}" unless STATUSES.include?(status)

    source = cell["source"].to_s
    begin
      uri = URI.parse(source)
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

    errors << "#{where}: status #{status} needs a note" if %w[none na partial].include?(status) && cell["note"].to_s.strip.empty?
    errors << "#{where}: cmd entries must be non-empty strings" if cmds.any? { |c| c.strip.empty? }
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
    expected = data.dig("checked", "flisk").to_s
    warnings << "installed flisk is #{installed}, data was checked against #{expected}" unless installed == expected

    top, = run_flisk("--help")
    nested = { "config" => true, "agent" => true }
    help_cache = {}

    data.fetch("tasks").each do |task|
      commands_of(task["cells"]["flisk"]).each do |cmd|
        where = "task #{task['id']} / flisk: `#{cmd}`"
        tokens = cmd.split
        unless tokens.shift == "flisk"
          errors << "#{where}: must start with flisk"
          next
        end

        sub = tokens.first
        if sub.nil? || sub.start_with?("-")
          errors << "#{where}: needs a subcommand"
          next
        end
        unless top =~ /^\s+(?:[\w-]+,\s*)*#{Regexp.escape(sub)}(?:,\s*[\w-]+)*\s{2,}/
          errors << "#{where}: `flisk #{sub}` is not in `flisk --help`"
          next
        end

        help_args = [sub, "--help"]
        if nested[sub] && tokens[1] && !tokens[1].start_with?("-")
          help_args = [sub, "help", tokens[1]]
        end
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

# --- Source URLs ---------------------------------------------------------------
if check_links
  urls = []
  tools.each { |t| urls << t["site"] << t["docs"] }
  data["tasks"].each { |task| task["cells"].each_value { |c| urls << c["source"] } }

  def fetch_status(url, limit = 5)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 25
    req = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "command-comparer-link-check")
    res = http.request(req)
    if res.is_a?(Net::HTTPRedirection) && limit.positive?
      target = URI.join(url, res["location"]).to_s
      return fetch_status(target, limit - 1)
    end
    res.code.to_i
  end

  urls.compact.uniq.each do |url|
    base = url.split("#").first
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
      puts "ok   #{code} #{url}"
    else
      errors << "link: #{url} returned #{code}"
    end
  end
end

warnings.each { |w| warn "warning: #{w}" }

if errors.empty?
  cells = data["tasks"].size * tool_ids.size
  puts "OK: #{data['tasks'].size} tasks, #{tool_ids.size} tools, #{cells} cells, every cell has a source."
else
  warn "#{errors.size} problem(s):"
  errors.each { |e| warn "  - #{e}" }
  exit 1
end
