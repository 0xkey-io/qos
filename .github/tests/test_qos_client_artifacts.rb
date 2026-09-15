# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "digest"

class QosClientArtifactsTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/qos-client-artifacts.rb", __dir__)
  def setup
    @dir = Dir.mktmpdir("qos-artifacts-")
    @env = { "SOURCE_SHA" => "a" * 40, "SOURCE_TREE" => "b" * 40,
             "RELEASE_TAG" => "0xkey-qos_client-v0.2.0", "GITHUB_REPOSITORY" => "0xkey-io/qos",
             "GITHUB_RUN_ID" => "123" }
    %w[linux-amd64 darwin-arm64].each do |platform|
      path = File.join(@dir, "artifacts", "qos_client-#{platform}")
      FileUtils.mkdir_p(path)
      name = "qos_client.#{platform}"
      File.write(File.join(path, name), platform)
      sha = Digest::SHA256.hexdigest(platform)
      File.write(File.join(path, "#{name}.sha256"), "#{sha}  #{name}\n")
      metadata = { "platform" => platform, "filename" => name, "checksum_filename" => "#{name}.sha256",
                   "source_commit" => @env["SOURCE_SHA"], "source_tree" => @env["SOURCE_TREE"],
                   "size" => platform.bytesize, "sha256" => sha,
                   "build_method" => platform == "linux-amd64" ? "stagex-buildx" : "native-cargo-smartcard",
                   "runtime" => platform == "linux-amd64" ? "ubuntu-24.04" : "macos-14",
                   "rustc" => platform == "linux-amd64" ? "stagex-pinned" : "rustc 1.94.0 (fixture)",
                   "deployment_target" => platform == "linux-amd64" ? "" : "11.0",
                   "help_checks" => ["--help", "provision-yubikey", "approve-manifest", "proxy-re-encrypt-share", "after-genesis"] }
      File.write(File.join(path, "metadata.json"), JSON.generate(metadata))
    end
  end
  def teardown
    FileUtils.remove_entry(@dir)
  end
  def run_bundle(success: true)
    out, err, result = Open3.capture3(@env, "ruby", SCRIPT, "assemble", "artifacts", "release", chdir: @dir)
    assert_equal success, result.success?, "#{out}\n#{err}"
    assert_includes err, "phase=artifacts outcome=failure" unless success
  end
  def linux(name)
    File.join(@dir, "artifacts/qos_client-linux-amd64", name)
  end
  def test_valid_bundle
    run_bundle
    assert_equal 5, Dir.children(File.join(@dir, "release")).length
    manifest = JSON.parse(File.read(File.join(@dir, "release/MANIFEST.json")))
    assert_equal "0xkey.qos-client-release/v1", manifest.fetch("schema")
    assert_equal %w[linux-amd64 darwin-arm64], manifest.fetch("platforms").keys
  end
  def test_metadata_mutations
    original = File.read(linux("metadata.json"))
    { "source_commit" => "c" * 40, "size" => 99, "sha256" => "0" * 64,
      "extra" => true, "help_checks" => [], "runtime" => "other", "build_method" => "other" }.each do |key, value|
      data = JSON.parse(original).merge(key => value)
      File.write(linux("metadata.json"), JSON.generate(data))
      run_bundle(success: false)
    end
  end
  def test_checksum_without_filename
    File.write(linux("qos_client.linux-amd64.sha256"), "0" * 64)
    run_bundle(success: false)
  end
  def test_extra_file
    File.write(linux("extra"), "bad")
    run_bundle(success: false)
  end
  def test_missing_platform
    FileUtils.remove_entry(File.join(@dir, "artifacts/qos_client-darwin-arm64"))
    run_bundle(success: false)
  end
  def test_symlink
    File.rename(linux("qos_client.linux-amd64"), File.join(@dir, "outside"))
    File.symlink(File.join(@dir, "outside"), linux("qos_client.linux-amd64"))
    run_bundle(success: false)
  end
  def test_existing_destination
    Dir.mkdir(File.join(@dir, "release"))
    run_bundle(success: false)
  end
end
