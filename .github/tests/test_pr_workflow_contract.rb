#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
PRODUCT_JOBS = %w[test lint check-publishable-crates-standalone build-linux-only-crates].freeze
CHECKOUT_SHA = "11bd71901bbe5b1630ceea73d27597364c9af683"
RUST_SHA = "e97e2d8cc328f1b50210efc529dca0028893a2d9"
INSTALL_SHA = "50414676f9f5d50a65992c6dd2ed02641263226c"
DOCKER_SHA = "e43656e248c0bd0647d3f5c195d116aacf6fcaf4"

def pr_workflow
  document = YAML.safe_load(File.read(File.join(ROOT, ".github/workflows/pr.yml")), aliases: true)
  document["on"] = document.delete(true) if document.key?(true)
  document
end

class PrWorkflowContractTest < Minitest::Test
  def setup
    @pr = pr_workflow
    @jobs = @pr.fetch("jobs")
  end

  def test_trigger_permissions_runners_timeouts_and_action_pins
    assert_equal ["push", "pull_request"], @pr.fetch("on").keys
    assert_equal ["main"], @pr.dig("on", "push", "branches")
    assert_equal({ "contents" => "read" }, @pr.fetch("permissions"))
    assert_equal %w[source test lint check-publishable-crates-standalone build-linux-only-crates quality], @jobs.keys
    expected_timeouts = { "source" => 5, "test" => 45, "lint" => 30,
                          "check-publishable-crates-standalone" => 45,
                          "build-linux-only-crates" => 60, "quality" => 5 }
    @jobs.each do |name, job|
      assert_equal "ubuntu-24.04", job.fetch("runs-on"), name
      assert_equal expected_timeouts.fetch(name), job.fetch("timeout-minutes"), name
      refute job.key?("permissions"), name
      refute job.key?("environment"), name
      job.fetch("steps", []).select { |step| step["uses"] }.each do |step|
        assert_match(/@[0-9a-f]{40}\z/, step.fetch("uses"), step.fetch("uses"))
      end
    end
    uses = @jobs.values.flat_map { |job| job.fetch("steps", []).map { |step| step["uses"] }.compact }
    assert_includes uses, "actions/checkout@#{CHECKOUT_SHA}"
    assert_includes uses, "dtolnay/rust-toolchain@#{RUST_SHA}"
    assert_includes uses, "taiki-e/install-action@#{INSTALL_SHA}"
    assert_includes uses, "docker/setup-docker-action@#{DOCKER_SHA}"
  end

  def test_product_jobs_bind_exact_source_and_preserve_product_gates
    PRODUCT_JOBS.each do |name|
      job = @jobs.fetch(name)
      assert_equal "source", job.fetch("needs"), name
      checkout = job.fetch("steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
      assert_equal false, checkout.dig("with", "persist-credentials"), name
      assert_equal "${{ needs.source.outputs.source_sha }}", checkout.dig("with", "ref"), name
      runs = job.fetch("steps").map { |step| step["run"] }.compact.join("\n")
      assert_includes runs, ".github/scripts/verify-pr-source.sh", name
    end
    assert_includes runs_for("test"), "make -C src test"
    assert_includes runs_for("test"), "cargo test --locked -p integration --features legacy-protocol-compat --test protocol_legacy_decode"
    assert_includes runs_for("lint"), "make -C src lint"
    assert_includes runs_for("check-publishable-crates-standalone"), "cargo check --locked -p ${{ matrix.package }}"
    assert_includes runs_for("check-publishable-crates-standalone"), "cargo fetch --locked"
    assert_includes runs_for("check-publishable-crates-standalone"), '.github/scripts/check-no-dev-feature-powerset.sh "${{ matrix.package }}"'
    assert_includes runs_for("build-linux-only-crates"), 'make -j"$(nproc)" build-linux-only'
    assert_equal %w[qos_client qos_core qos_crypto qos_hex qos_net qos_p256 qos_nsm qos_test_primitives qos_json],
                 @jobs.dig("check-publishable-crates-standalone", "strategy", "matrix", "package")
  end

  def test_source_job_checks_out_event_sha_with_history_and_exports_verifier_outputs
    source = @jobs.fetch("source")
    checkout = source.fetch("steps").first
    assert_equal "${{ github.sha }}", checkout.dig("with", "ref")
    assert_equal 0, checkout.dig("with", "fetch-depth")
    assert_equal false, checkout.dig("with", "persist-credentials")
    assert_equal "${{ steps.verify.outputs.source_sha }}", source.dig("outputs", "source_sha")
    assert_equal "${{ steps.verify.outputs.source_tree }}", source.dig("outputs", "source_tree")
    verify = source.fetch("steps")[1]
    assert_includes verify.fetch("run"), ".github/scripts/pr-source-gate.sh"
    assert_includes verify.fetch("run"), 'mktemp "${RUNNER_TEMP}/pr-source-verification.XXXXXX"'
    assert_includes verify.fetch("run"), 'statuses=("${PIPESTATUS[@]}")'
    refute_includes verify.fetch("run"), "tee source-verification.log"
    refute_includes verify.to_s, "github.event.pull_request.title"
  end

  def test_exact_tools_and_local_gate_tests_are_enforced
    assert_equal "1.94.0", @pr.dig("env", "RUSTUP_TOOLCHAIN")
    %w[test lint check-publishable-crates-standalone].each do |name|
      rust = @jobs.fetch(name).fetch("steps").find { |step| step["uses"]&.start_with?("dtolnay/rust-toolchain@") }
      assert_equal "1.94.0", rust.dig("with", "toolchain"), name
      assert_includes runs_for(name), "rustc --version", name
      assert_includes runs_for(name), "cargo --version", name
    end
    assert_equal "clippy,rustfmt", @jobs.dig("lint", "steps").find { |s| s["uses"]&.start_with?("dtolnay/") }.dig("with", "components")
    install = @jobs.dig("check-publishable-crates-standalone", "steps").find { |s| s["uses"]&.start_with?("taiki-e/") }
    assert_equal "cargo-hack@0.6.45", install.dig("with", "tool")
    assert_includes runs_for("check-publishable-crates-standalone"), "cargo hack --version"
    test_runs = runs_for("test")
    %w[test_exact_source_fd_gate.sh test_pr_source_gate.sh test_verify_pr_source.sh test_workflow_boundaries.rb
       test_buildx_container_gate.sh test_no_dev_feature_powerset.sh test_linux_only_locked_builds.rb
       test_pr_workflow_contract.rb test_pr_quality_decision.rb].each do |test|
      assert_includes test_runs, test
    end
  end

  def test_quality_is_checkout_free_and_needs_every_gate
    quality = @jobs.fetch("quality")
    assert_equal "${{ always() }}", quality.fetch("if")
    assert_equal %w[source test lint check-publishable-crates-standalone build-linux-only-crates], quality.fetch("needs")
    refute quality.fetch("steps").any? { |step| step.key?("uses") }
    env = quality.fetch("env")
    assert_equal "${{ needs.source.outputs.source_sha }}", env.fetch("SOURCE_SHA")
    assert_equal "${{ needs.source.outputs.source_tree }}", env.fetch("SOURCE_TREE")
    assert_equal "${{ needs.build-linux-only-crates.result }}", env.fetch("RESULT_LINUX")
  end

  def test_docker_runtime_preserves_containerd_store_and_selects_exact_builder
    job = @jobs.fetch("build-linux-only-crates")
    setup = job.fetch("steps").find { |step| step["uses"]&.start_with?("docker/setup-docker-action@") }
    assert_equal "v28.0.4", setup.dig("with", "version")
    assert_equal "qos-validation", setup.dig("with", "context")
    assert_equal "", setup.dig("with", "github-token")
    assert_equal({ "features" => { "containerd-snapshotter" => true } }, YAML.safe_load(setup.dig("with", "daemon-config")))
    runs = runs_for("build-linux-only-crates")
    assert_includes runs, "docker version"
    assert_includes runs, "[[ \"$server_version\" == '28.0.4' ]]"
    assert_includes runs, "docker info"
    assert_includes runs, "[[ \"$driver_status\" == *'io.containerd.snapshotter.v1'* ]]"
    assert_includes runs, "docker buildx version"
    assert_includes runs, 'builder="qos-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"'
    assert_includes runs, 'node="$builder"'
    assert_includes runs, 'BUILDX_BUILDER="$builder"'
    assert_includes runs, 'docker buildx inspect "$builder" --bootstrap'
    assert_includes runs, '.github/scripts/verify-buildx-container.sh "$builder" "$node" qos-validation'
    assert_includes runs, 'docker buildx rm "$builder"'
    refute_includes runs, "label=com.docker.buildx.builder"
    cleanup = job.fetch("steps").find { |step| step["name"] == "Remove isolated builder" }
    assert_equal "${{ always() }}", cleanup.fetch("if")
    refute_includes cleanup.fetch("run"), "|| true"
    refute_match(/prune|tcp:\/\/|docker login|registry-mirror/i, runs)
  end

  def test_workflow_has_no_privileged_or_weakened_boundary
    text = File.read(File.join(ROOT, ".github/workflows/pr.yml"))
    refute_match(/ubicloud|\.github\/actions\/docker-setup|pull_request_target|continue-on-error|repository_owner/i, text)
    refute_match(/secrets\.|id-token|packages:|attestations:|docker login|\bpush\b.*(?:image|registry)|deploy|environment:/i, text)
  end

  private

  def runs_for(name)
    @jobs.fetch(name).fetch("steps").map { |step| step["run"] }.compact.join("\n")
  end
end
