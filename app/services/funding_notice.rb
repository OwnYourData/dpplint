require "erb"
require "yaml"

# The funding notice of PACE-DPP, kept once in config/funding.yml.
#
# The footer of the start page renders it from there (#html). The README
# cannot read the configuration, so it holds a copy between two markers;
# `bin/rails funding:write` replaces that copy with what the configuration
# says, and test/services/funding_notice_test.rb fails while they differ.
module FundingNotice
  ROOT = File.expand_path("../..", __dir__)
  SOURCE = File.join(ROOT, "config", "funding.yml")
  README = File.join(ROOT, "README.md")
  BEGIN_MARK = "<!-- funding:begin -->"
  END_MARK = "<!-- funding:end -->"
  LINK = /\[([^\]]+)\]\(([^)\s]+)\)/

  module_function

  def settings
    YAML.safe_load_file(SOURCE)
  end

  # For the README: Markdown, with the full title of the project.
  def markdown
    s = settings
    format(s.fetch("text"), component: s.fetch("component"), title: " – #{s.fetch('title')}")
  end

  # For the footer: one line of HTML, without the title.
  def html
    s = settings
    text = format(s.fetch("text"), component: s.fetch("component"), title: "")
    String.new(ERB::Util.html_escape(text)).gsub(LINK) { %(<a href="#{Regexp.last_match(2)}">#{Regexp.last_match(1)}</a>) }
  end

  # The copy in the README, or nil without markers.
  def current(path = README)
    content = File.read(path, encoding: "UTF-8")
    start = content.index(BEGIN_MARK) or return nil
    stop = content.index(END_MARK, start) or return nil
    content[(start + BEGIN_MARK.length)...stop].strip
  end

  def write!(path = README)
    content = File.read(path, encoding: "UTF-8")
    region = /#{Regexp.escape(BEGIN_MARK)}.*?#{Regexp.escape(END_MARK)}/m
    raise "#{path}: no funding markers" unless content.match?(region)

    File.write(path, content.sub(region) { "#{BEGIN_MARK}\n#{markdown}\n#{END_MARK}" })
  end
end
