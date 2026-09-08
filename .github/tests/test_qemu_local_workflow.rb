#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
WORKFLOW = File.join(ROOT, ".github/workflows/exact-source-qemu-validation.yml")

class QemuLocalWorkflowTest < Minitest::Test
  def setup
    @document = YAML.safe_load(File.read(WORKFLOW), aliases: true)
    @document["on"] = @document.delete(true) if @document.key?(true)
    @job = @document.fetch("jobs").fetch("qemu-gate")
    @steps = @job.fetch("steps")
  end

  def test_gate_is_manual_read_only_and_single_job
    assert_equal ["workflow_dispatch"], @document.fetch("on").keys
    source_input = @document.dig("on", "workflow_dispatch", "inputs", "source_sha")
    assert_equal true, source_input.fetch("required")
    assert_equal "string", source_input.fetch("type")
    assert_equal({ "contents" => "read" }, @document.fetch("permissions"))
    assert_equal ["qemu-gate"], @document.fetch("jobs").keys
    assert_equal "ubuntu-24.04", @job.fetch("runs-on")
    assert_equal 90, @job.fetch("timeout-minutes")
    refute @job.key?("permissions")
    refute @job.key?("environment")
    refute @job.key?("secrets")
  end

  def test_controller_and_source_are_distinct_exact_checkouts
    checkouts = @steps.select { |step| step["uses"]&.start_with?("actions/checkout@") }
    assert_equal 2, checkouts.length
    checkouts.each do |step|
      assert_match(/@[0-9a-f]{40}\z/, step.fetch("uses"))
      assert_equal false, step.dig("with", "persist-credentials")
    end
    assert_equal "controller", checkouts[0].dig("with", "path")
    assert_equal "${{ github.sha }}", checkouts[0].dig("with", "ref")
    assert_equal "source", checkouts[1].dig("with", "path")
    assert_equal "${{ env.SOURCE_SHA }}", checkouts[1].dig("with", "ref")
    assert_operator @steps.index { |step| step["name"] == "Reject malformed source SHA" }, :<,
                    @steps.index(checkouts[1])
  end

  def test_actions_are_pinned_and_docker_is_isolated
    @steps.select { |step| step["uses"] }.each do |step|
      assert_match(/@[0-9a-f]{40}\z/, step.fetch("uses"), step.fetch("uses"))
    end
    setup = @steps.find { |step| step["uses"]&.start_with?("docker/setup-docker-action@") }
    assert_equal "v28.0.4", setup.dig("with", "version")
    assert_equal "qos-validation", setup.dig("with", "context")
    assert_equal "", setup.dig("with", "github-token")
    assert_equal({ "features" => { "containerd-snapshotter" => true } },
                 YAML.safe_load(setup.dig("with", "daemon-config")))
    runs = @steps.map { |step| step["run"] }.compact.join("\n")
    assert_includes runs, ".github/scripts/verify-buildx-container.sh"
    assert_includes runs, 'builder="qos-qemu-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"'
  end

  def test_gate_uses_local_images_exact_tests_and_always_cleanup
    runs = @steps.map { |step| step["run"] }.compact.join("\n")
    %w[preflight build-load run-tests verify-final cleanup].each do |command|
      assert_match(/qemu-local-gate\.sh"? #{command}/, runs)
    end
    test_step = @steps.find { |step| step["name"] == "Run exact two-test QEMU gate" }
    expected_images = {
      "QOS_TEST_QEMU_ENCLAVE_IMAGE" => "qos-local/qos_enclave_egress:latest",
      "QOS_TEST_QEMU_HOST_IMAGE" => "qos-local/qos_host_qemu:latest",
      "QOS_TEST_QEMU_BRIDGE_IMAGE" => "qos-local/qos_bridge_qemu:latest",
      "QOS_TEST_QEMU_CLIENT_IMAGE" => "qos-local/qos_client:latest",
      "QOS_TEST_QEMU_PIVOT_IMAGE" => "qos-local/signed_echo:latest"
    }
    assert_equal expected_images, test_step.fetch("env")
    cleanup = @steps.find { |step| step["name"] == "Clean run-owned resources" }
    builder = @steps.find { |step| step["name"] == "Remove isolated builder" }
    assert_equal "${{ always() }}", cleanup.fetch("if")
    assert_equal "${{ always() }}", builder.fetch("if")
  end

  def test_workflow_has_no_publication_or_privilege_boundary
    workflow_text = File.read(WORKFLOW)
    helper_text = File.read(File.join(ROOT, ".github/scripts/qemu-local-gate.sh"))
    refute_match(/pull_request_target|workflow_call|continue-on-error|repository_owner|secrets\.|secrets:|packages:|id-token|attestations:|docker login|\bpush\b.*(?:image|registry)|publish|release|deploy|environment:|uses:\s*\.\/\.github\/workflows\/qemu-e2e\.yml/i, workflow_text)
    refute_match(/ghcr\.io|\.dkr\.ecr\.|aws-actions|kubectl|stagex\.yml|\.github\/actions\/docker-setup/i, workflow_text)
    refute_match(/docker login|\bpush\b.*(?:image|registry)|ghcr\.io|\.dkr\.ecr\.|aws-actions|kubectl|secrets\./i, helper_text)
  end
end
