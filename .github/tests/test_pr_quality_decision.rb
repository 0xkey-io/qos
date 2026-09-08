#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
JOBS = %w[source test lint matrix linux].freeze
SHA = "0123456789abcdef0123456789abcdef01234567"
TREE = "89abcdef0123456789abcdef0123456789abcdef"

def quality_script
  document = YAML.safe_load(File.read(File.join(ROOT, ".github/workflows/pr.yml")), aliases: true)
  document["on"] = document.delete(true) if document.key?(true)
  step = document.dig("jobs", "quality", "steps").find { |item| item["name"] == "Enforce aggregate quality" }
  step.fetch("run")
end

def run_quality(results: {}, sha: SHA, tree: TREE)
  Tempfile.create("quality-summary") do |summary|
    env = {
      "GITHUB_EVENT_NAME" => "pull_request",
      "GITHUB_REF" => "refs/pull/73/merge",
      "SOURCE_SHA" => sha,
      "SOURCE_TREE" => tree,
      "GITHUB_STEP_SUMMARY" => summary.path
    }
    JOBS.each { |job| env["RESULT_#{job.upcase}"] = results.fetch(job, "success") }
    stdout, stderr, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", quality_script)
    summary.rewind
    [stdout, stderr, status, summary.read]
  end
end

class PrQualityDecisionTest < Minitest::Test
  def test_all_success_results_and_valid_source_succeed
    stdout, stderr, status, summary = run_quality
    assert status.success?, stderr
    assert_includes stdout, "source_sha=#{SHA}"
    JOBS.each { |job| assert_includes summary, "#{job}=success" }
  end

  def test_every_non_success_or_missing_result_fails
    %w[failure cancelled skipped missing unknown].each do |outcome|
      JOBS.each do |job|
        value = outcome == "missing" ? "" : outcome
        _stdout, _stderr, status, summary = run_quality(results: { job => value })
        refute status.success?, "#{job}=#{outcome} unexpectedly succeeded"
        assert_includes summary, "#{job}=#{value}"
      end
    end
  end

  def test_invalid_source_identity_fails
    refute run_quality(sha: "main")[2].success?
    refute run_quality(tree: "ABCDEF")[2].success?
  end

  def test_summary_write_failure_is_fatal
    Dir.mktmpdir("quality-summary-dir") do |summary_dir|
      env = {
        "GITHUB_EVENT_NAME" => "pull_request",
        "GITHUB_REF" => "refs/pull/73/merge",
        "SOURCE_SHA" => SHA,
        "SOURCE_TREE" => TREE,
        "GITHUB_STEP_SUMMARY" => summary_dir
      }
      JOBS.each { |job| env["RESULT_#{job.upcase}"] = "success" }
      _stdout, _stderr, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", quality_script)
      refute status.success?
    end
  end
end
