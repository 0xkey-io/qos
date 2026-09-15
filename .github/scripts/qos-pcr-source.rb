require "open3"

begin
  root = ARGV.fetch(0)
  raise "main dispatch required" unless ENV.fetch("GITHUB_EVENT_NAME") == "workflow_dispatch" &&
    ENV.fetch("GITHUB_REF") == "refs/heads/main"
  {"source" => "SOURCE_SHA", "tooling" => "WORKFLOW_SHA"}.each do |name, variable|
    expected = ENV.fetch(variable)
    raise "invalid commit" unless expected.match?(/\A[0-9a-f]{40}\z/)
    path = File.join(root, name)
    raise "symlink checkout" if File.symlink?(path)
    actual, _error, status = Open3.capture3("git", "-C", path, "rev-parse", "HEAD")
    raise "checkout mismatch" unless status.success? && actual.strip == expected
    dirty, _error, status = Open3.capture3(
      "git", "-C", path, "status", "--porcelain", "--untracked-files=no"
    )
    raise "dirty tracked checkout" unless status.success? && dirty.empty?
  end
  puts "PCR source gate passed"
rescue KeyError, IndexError, RuntimeError, SystemCallError => error
  warn "PCR source rejected: #{error.message}"
  exit 1
end
