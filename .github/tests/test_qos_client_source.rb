# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"

class QosClientSourceTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/qos-client-source.rb", __dir__)
  TAG = "0xkey-qos_client-v0.2.0"

  def setup
    @dir = Dir.mktmpdir("qos-client-source-")
    git("init", "-b", "main")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    git("commit", "--allow-empty", "-m", "base")
    @sha = git("rev-parse", "HEAD").strip
    git("update-ref", "refs/remotes/origin/main", @sha)
    git("tag", TAG)
    @env = { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF" => "refs/tags/#{TAG}",
             "GITHUB_SHA" => @sha, "INPUT_TAG" => "", "GITHUB_OUTPUT" => File.join(@dir, "output") }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", *args, chdir: @dir)
    raise err unless status.success?
    out
  end

  def check(overrides = {}, success: true)
    out, err, status = Open3.capture3(@env.merge(overrides), "ruby", SCRIPT, chdir: @dir)
    assert_equal success, status.success?, "#{out}\n#{err}"
    unless success
      assert_includes err, "phase=source outcome=failure"
      return
    end
    File.read(@env.fetch("GITHUB_OUTPUT"))
  end

  def test_tag_push
    result = check
    assert_includes result, "source_sha=#{@sha}\n"
    assert_includes result, "source_tree=#{git('rev-parse', 'HEAD^{tree}').strip}\n"
    assert_includes result, "publish=true\n"
  end

  def test_pr_uses_merge_commit_without_main_ancestry_requirement
    git("commit", "--allow-empty", "-m", "candidate")
    sha = git("rev-parse", "HEAD").strip
    result = check({ "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF" => "refs/pull/42/merge", "GITHUB_SHA" => sha })
    assert_includes result, "publish=false\n"
    assert_includes result, "release_tag=\n"
  end

  def test_dispatch_from_main
    check({ "GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_REF" => "refs/heads/main", "INPUT_TAG" => TAG })
  end

  def test_dispatch_from_other_branch_is_rejected
    check({ "GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_REF" => "refs/heads/candidate", "INPUT_TAG" => TAG }, success: false)
  end

  def test_bad_tags_are_rejected
    ["v0.2.0", "#{TAG}-rc.1", "#{TAG}\n", "--help", "0xkey-qos_client-v0x2x0"].each do |tag|
      check({ "GITHUB_REF" => "refs/tags/#{tag}" }, success: false)
    end
  end

  def test_missing_tag_is_rejected
    check({ "GITHUB_REF" => "refs/tags/0xkey-qos_client-v9.9.9" }, success: false)
  end

  def test_non_main_release_is_rejected
    git("commit", "--allow-empty", "-m", "unreviewed")
    git("tag", "-f", TAG)
    check({ "GITHUB_SHA" => git("rev-parse", "HEAD").strip }, success: false)
  end

  def test_wrong_checkout_is_rejected
    check({ "GITHUB_SHA" => "a" * 40 }, success: false)
  end

  def test_prepared_identity_mismatch_is_rejected
    check({ "EXPECTED_SOURCE_SHA" => @sha, "EXPECTED_SOURCE_TREE" => "c" * 40 }, success: false)
    check({ "EXPECTED_SOURCE_SHA" => "c" * 40, "EXPECTED_SOURCE_TREE" => git("rev-parse", "HEAD^{tree}").strip }, success: false)
  end

  def test_unknown_event_is_rejected
    check({ "GITHUB_EVENT_NAME" => "pull_request_target" }, success: false)
  end

  def test_pr_head_ref_is_rejected
    check({ "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF" => "refs/pull/42/head" }, success: false)
  end

  def test_dirty_tracked_file_is_rejected
    File.write(File.join(@dir, "tracked"), "original")
    git("add", "tracked")
    git("commit", "-m", "tracked")
    sha = git("rev-parse", "HEAD").strip
    File.write(File.join(@dir, "tracked"), "changed")
    check({ "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF" => "refs/pull/42/merge", "GITHUB_SHA" => sha }, success: false)
  end
end
