# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "open3"
require "time"

PLATFORMS = %w[linux-amd64 darwin-arm64].freeze
HELP = %w[--help provision-yubikey approve-manifest proxy-re-encrypt-share after-genesis].freeze
FIELDS = %w[platform filename checksum_filename source_commit source_tree size sha256 build_method runtime rustc deployment_target help_checks].freeze

def ensure_directory(path)
  raise "directory required" unless File.directory?(path) && !File.symlink?(path)
end

def ensure_file(path)
  raise "regular file required" unless File.file?(path) && !File.symlink?(path)
end

def facts(platform)
  platform == "linux-amd64" ? ["stagex-buildx", "ubuntu-24.04", ""] : ["native-cargo-smartcard", "macos-14", "11.0"]
end

begin
  sha = ENV.fetch("SOURCE_SHA")
  tree = ENV.fetch("SOURCE_TREE")
  raise "invalid source identity" unless [sha, tree].all? { |s| s.match?(/\A[0-9a-f]{40}\z/) }
  command, input, destination = ARGV
  case command
  when "record"
    platform = input
    raise "unsupported platform" unless PLATFORMS.include?(platform)
    ensure_directory(destination)
    name = "qos_client.#{platform}"
    binary = File.expand_path(File.join(destination, name))
    ensure_file(binary)
    raise "binary not executable" unless File.executable?(binary)
    description, status = Open3.capture2("file", "-b", binary)
    pattern = platform == "linux-amd64" ? /ELF 64-bit.*x86-64/ : /Mach-O 64-bit executable arm64/
    raise "binary architecture mismatch" unless status.success? && description.match?(pattern)
    HELP.each do |subcommand|
      args = subcommand == "--help" ? ["--help"] : [subcommand, "--help"]
      _out, _err, result = Open3.capture3(binary, *args)
      raise "required help check failed" unless result.success?
    end
    digest = Digest::SHA256.file(binary).hexdigest
    method, runtime, target = facts(platform)
    rustc = platform == "linux-amd64" ? "stagex-pinned" : ENV.fetch("RUSTC_VERSION")
    raise "unexpected Rust version" if platform == "darwin-arm64" && !rustc.start_with?("rustc 1.94.")
    metadata = { "platform" => platform, "filename" => name, "checksum_filename" => "#{name}.sha256",
                 "source_commit" => sha, "source_tree" => tree, "size" => File.size(binary), "sha256" => digest,
                 "build_method" => method, "runtime" => runtime, "rustc" => rustc,
                 "deployment_target" => target, "help_checks" => HELP }
    File.write(File.join(destination, "#{name}.sha256"), "#{digest}  #{name}\n", mode: "wx")
    File.write(File.join(destination, "metadata.json"), JSON.pretty_generate(metadata) + "\n", mode: "wx")
  when "assemble"
    ensure_directory(input)
    raise "unexpected artifact set" unless Dir.children(input).sort == PLATFORMS.map { |p| "qos_client-#{p}" }.sort
    raise "destination already exists" if File.exist?(destination) || File.symlink?(destination)
    tag = ENV.fetch("RELEASE_TAG")
    raise "invalid tag" unless tag.empty? || tag.match?(/\A0xkey-qos_client-v[0-9]+\.[0-9]+\.[0-9]+\z/)
    repository = ENV.fetch("GITHUB_REPOSITORY")
    run = ENV.fetch("GITHUB_RUN_ID")
    raise "invalid workflow identity" unless repository == "0xkey-io/qos" && run.match?(/\A[0-9]+\z/)
    platforms = {}
    PLATFORMS.each do |platform|
      path = File.join(input, "qos_client-#{platform}")
      ensure_directory(path)
      name = "qos_client.#{platform}"
      raise "unexpected contract files" unless Dir.children(path).sort == [name, "#{name}.sha256", "metadata.json"].sort
      Dir.children(path).each { |file| ensure_file(File.join(path, file)) }
      metadata = JSON.parse(File.read(File.join(path, "metadata.json")))
      raise "metadata schema mismatch" unless metadata.is_a?(Hash) && metadata.keys.sort == FIELDS.sort
      digest = Digest::SHA256.file(File.join(path, name)).hexdigest
      method, runtime, target = facts(platform)
      expected = { "platform" => platform, "filename" => name, "checksum_filename" => "#{name}.sha256",
                   "source_commit" => sha, "source_tree" => tree, "size" => File.size(File.join(path, name)),
                   "sha256" => digest, "build_method" => method, "runtime" => runtime,
                   "deployment_target" => target, "help_checks" => HELP }
      raise "metadata facts mismatch" unless expected.all? { |key, value| metadata[key] == value }
      rustc = metadata.fetch("rustc")
      valid_rust = platform == "linux-amd64" ? rustc == "stagex-pinned" : rustc.is_a?(String) && rustc.match?(/\Arustc 1\.94\.[0-9]+ [^\r\n]+\z/)
      raise "invalid toolchain" unless valid_rust
      raise "empty binary" unless metadata.fetch("size").positive?
      raise "checksum mismatch" unless File.read(File.join(path, "#{name}.sha256")) == "#{digest}  #{name}\n"
      platforms[platform] = metadata
    end
    manifest = { "schema" => "0xkey.qos-client-release/v1", "release_tag" => tag,
                 "repository" => repository, "source_commit" => sha, "source_tree" => tree,
                 "workflow_url" => "https://github.com/#{repository}/actions/runs/#{run}",
                 "generated_at" => Time.now.utc.iso8601, "platforms" => platforms }
    Dir.mkdir(destination)
    PLATFORMS.each do |platform|
      name = "qos_client.#{platform}"
      [name, "#{name}.sha256"].each { |file| FileUtils.copy_file(File.join(input, "qos_client-#{platform}", file), File.join(destination, file)) }
    end
    File.write(File.join(destination, "MANIFEST.json"), JSON.pretty_generate(manifest) + "\n", mode: "wx")
  else
    raise "unsupported command"
  end
  puts "phase=artifacts source_commit=#{sha} source_tree=#{tree} outcome=success"
rescue KeyError, RuntimeError, SystemCallError, JSON::ParserError => error
  warn "phase=artifacts outcome=failure reason=#{error.message}"
  exit 1
end
