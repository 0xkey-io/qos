# frozen_string_literal: true

require "open3"

def git(*args)
  out, _err, status = Open3.capture3("git", *args)
  raise "git source validation failed" unless status.success?
  out.strip
end

begin
  event = ENV.fetch("GITHUB_EVENT_NAME")
  ref = ENV.fetch("GITHUB_REF")
  tag = ""
  case event
  when "pull_request"
    raise "PR merge ref required" unless ref.match?(%r{\Arefs/pull/[1-9][0-9]*/merge\z})
    source = ENV.fetch("GITHUB_SHA")
    publish = false
  when "push", "workflow_dispatch"
    if event == "workflow_dispatch"
      raise "dispatch must run from main" unless ref == "refs/heads/main"
      tag = ENV.fetch("INPUT_TAG")
    else
      raise "tag push required" unless ref.start_with?("refs/tags/")
      tag = ref.delete_prefix("refs/tags/")
    end
    raise "stable release tag required" unless tag.match?(/\A0xkey-qos_client-v[0-9]+\.[0-9]+\.[0-9]+\z/)
    source = git("rev-parse", "--verify", "refs/tags/#{tag}^{commit}")
    raise "push source mismatch" if event == "push" && ENV.fetch("GITHUB_SHA") != source
    git("merge-base", "--is-ancestor", source, "refs/remotes/origin/main")
    publish = true
  else
    raise "unsupported event"
  end
  raise "invalid source SHA" unless source.match?(/\A[0-9a-f]{40}\z/)
  raise "checkout source mismatch" unless git("rev-parse", "HEAD") == source
  raise "dirty tracked source" unless git("status", "--porcelain", "--untracked-files=no").empty?
  tree = git("rev-parse", "HEAD^{tree}")
  if ENV.key?("EXPECTED_SOURCE_SHA")
    raise "prepared source mismatch" unless ENV.fetch("EXPECTED_SOURCE_SHA") == source
    raise "prepared tree mismatch" unless ENV.fetch("EXPECTED_SOURCE_TREE") == tree
  end
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
    output.puts "source_sha=#{source}", "source_tree=#{tree}", "release_tag=#{tag}", "publish=#{publish}"
  end
  puts "phase=source source_commit=#{source} source_tree=#{tree} outcome=success"
rescue KeyError, RuntimeError => error
  warn "phase=source outcome=failure reason=#{error.message}"
  exit 1
end
