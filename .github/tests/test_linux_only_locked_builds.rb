#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"

ROOT = File.expand_path("../..", __dir__)

class LinuxOnlyLockedBuildsTest < Minitest::Test
  def test_build_linux_only_runs_exactly_the_five_locked_package_builds
    stdout, stderr, status = Open3.capture3(
      "make",
      "--no-print-directory",
      "-n",
      "-C",
      File.join(ROOT, "src"),
      "build-linux-only"
    )

    assert status.success?, "make dry-run failed: #{stderr}"
    assert_equal [
      "cargo build --locked --manifest-path ./qos_system/Cargo.toml",
      "cargo build --locked --manifest-path ./qos_aws/Cargo.toml",
      "cargo build --locked --manifest-path ./init/Cargo.toml",
      "cargo build --locked --manifest-path ./qos_enclave/Cargo.toml",
      "cargo build --locked --manifest-path ./qos_bridge/Cargo.toml"
    ], stdout.lines(chomp: true)
  end
end
