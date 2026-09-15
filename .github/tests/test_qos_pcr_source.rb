require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"

class PcrSourceTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/qos-pcr-source.rb", __dir__)
  def test_only_clean_exact_source_on_main_dispatch_is_accepted
    Dir.mktmpdir do |dir|
      %w[source tooling].each do |name|
        path = "#{dir}/#{name}"
        FileUtils.mkdir_p(path)
        system("git", "-C", path, "init", "-q", exception: true)
        system("git", "-C", path, "-c", "user.name=test", "-c", "user.email=test@example.invalid",
               "commit", "--allow-empty", "-qm", "fixture", exception: true)
      end
      source = Open3.capture2("git", "-C", "#{dir}/source", "rev-parse", "HEAD").first.strip
      tooling = Open3.capture2("git", "-C", "#{dir}/tooling", "rev-parse", "HEAD").first.strip
      base = {"SOURCE_SHA" => source, "WORKFLOW_SHA" => tooling,
              "GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_REF" => "refs/heads/main"}
      [{}, {"SOURCE_SHA" => "f" * 40}, {"WORKFLOW_SHA" => "f" * 40},
       {"GITHUB_EVENT_NAME" => "pull_request"}, {"GITHUB_REF" => "refs/heads/feature"}].each do |change|
        _out, err, status = Open3.capture3(base.merge(change), "ruby", SCRIPT, dir)
        assert_equal change.empty?, status.success?, err
      end
      File.write("#{dir}/source/injected", "unreviewed")
      system("git", "-C", "#{dir}/source", "add", "injected", exception: true)
      _out, _err, status = Open3.capture3(base, "ruby", SCRIPT, dir)
      refute status.success?, "dirty source must be rejected"
    end
  end
end
