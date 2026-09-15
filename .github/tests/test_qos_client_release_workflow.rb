# frozen_string_literal: true
require "minitest/autorun"
require "yaml"

class QosClientReleaseWorkflowTest < Minitest::Test
  def setup
    @workflow = YAML.safe_load(File.read(File.expand_path("../workflows/0xkey-qos-client-release.yml", __dir__)))
  end
  def test_events_and_permissions
    events = @workflow["on"] || @workflow[true]
    assert_equal %w[pull_request push workflow_dispatch], events.keys.sort
    assert_equal({ "contents" => "read" }, @workflow["permissions"])
    @workflow.fetch("jobs").each do |name, job|
      if name == "publish"
        assert_equal({ "contents" => "write", "attestations" => "write", "id-token" => "write" }, job["permissions"])
        assert_includes job.fetch("if"), "needs.prepare.outputs.publish == 'true'"
      else
        refute job.key?("permissions")
      end
      job.fetch("steps").each do |step|
        next unless step.key?("uses")
        assert_match(/@[0-9a-f]{40}\z/, step["uses"]) unless step["uses"].start_with?("./")
        assert_equal false, step.dig("with", "persist-credentials") if step["uses"].start_with?("actions/checkout@")
      end
    end
  end
  def test_builds_and_publication
    jobs = @workflow.fetch("jobs")
    assert_equal "ubuntu-24.04", jobs.dig("linux", "runs-on")
    assert_equal "macos-14", jobs.dig("darwin", "runs-on")
    assert_includes jobs["linux"].to_s, "make out/qos_client/index.json"
    assert_includes jobs["darwin"].to_s, "cargo build --release --locked --features smartcard"
    %w[linux darwin verify publish].each do |name|
      assert_includes jobs[name].to_s, "EXPECTED_SOURCE_SHA"
      assert_includes jobs[name].to_s, "EXPECTED_SOURCE_TREE"
      assert_includes jobs[name].to_s, "qos-client-source.rb"
    end
    refute_includes jobs["publish"].to_s, "--clobber"
    assert_includes jobs["publish"].to_s, "--verify-tag"
    assert_includes jobs["publish"].to_s, "qos-client-artifacts.rb assemble"
  end
end
