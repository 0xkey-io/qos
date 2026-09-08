#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("../..", __dir__)

def workflow(name)
  document = YAML.safe_load(File.read(File.join(ROOT, ".github/workflows", name)), aliases: true)
  # Psych follows YAML 1.1 and decodes the GitHub Actions key `on` as true.
  document["on"] = document.delete(true) if document.key?(true)
  document
end

def checkout_steps(document)
  document.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
    .select { |step| step["uses"]&.start_with?("actions/checkout@") }
end

class WorkflowBoundariesTest < Minitest::Test
  def test_upstream_publication_jobs_are_not_reachable_on_fork
    stagex = workflow("stagex.yml")
    assert_equal "github.repository_owner == 'tkhq'", stagex.dig("jobs", "build", "if")
    assert_equal "github.repository_owner == 'tkhq' && always()", stagex.dig("jobs", "build-artifacts", "if")
    assert_equal "github.repository_owner == 'tkhq' && github.event_name == 'pull_request'", stagex.dig("jobs", "qemu-e2e", "if")
    assert_equal "github.repository_owner == 'tkhq'", workflow("signed-echo-image.yml").dig("jobs", "publish", "if")
    assert_equal "github.repository_owner == 'tkhq'", workflow("stagex-release.yml").dig("jobs", "build", "if")
  end

  def test_ordinary_pr_workflow_is_read_only_and_checkouts_drop_credentials
    pr = workflow("pr.yml")
    assert_equal({ "contents" => "read" }, pr.fetch("permissions"))
    refute_empty checkout_steps(pr)
    checkout_steps(pr).each do |step|
      assert_equal false, step.fetch("with").fetch("persist-credentials")
    end
  end

  def test_exact_source_gate_is_manual_read_only_and_has_no_deployment_boundary
    gate = workflow("exact-source-fd-validation.yml")
    assert_equal ["workflow_dispatch"], gate.fetch("on").keys
    assert_equal({ "contents" => "read" }, gate.fetch("permissions"))
    assert_equal ["fd-gate"], gate.fetch("jobs").keys

    job = gate.dig("jobs", "fd-gate")
    assert_equal "ubuntu-24.04", job.fetch("runs-on")
    assert_equal 30, job.fetch("timeout-minutes")
    refute job.key?("environment")
    refute job.key?("permissions")
    refute job.key?("secrets")

    scalars = gate.to_s.downcase
    %w[aws oidc ghcr ecr docker login push publish deploy environment].each do |term|
      refute_includes scalars, term
    end
  end

  def test_exact_source_gate_uses_fixed_action_pins_and_separate_controller_checkout
    gate = workflow("exact-source-fd-validation.yml")
    steps = gate.dig("jobs", "fd-gate", "steps")
    action_steps = steps.select { |step| step.key?("uses") }
    action_steps.each do |step|
      assert_match(/@[0-9a-f]{40}\z/, step.fetch("uses"))
    end

    controller, validate, source = steps.first(3)
    assert_equal "controller", controller.dig("with", "path")
    assert_equal false, controller.dig("with", "persist-credentials")
    assert_includes validate.fetch("run"), "controller/.github/scripts/exact-source-fd-gate.sh"
    assert_equal "source", source.dig("with", "path")
    assert_equal false, source.dig("with", "persist-credentials")
    assert_equal "${{ env.SOURCE_SHA }}", source.dig("with", "ref")
  end
end
