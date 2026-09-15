require "digest"
require "json"

begin
  directory = ARGV.fetch(0)
  source = ENV.fetch("SOURCE_SHA")
  workflow = ENV.fetch("WORKFLOW_SHA")
  raise "invalid source" unless [source, workflow].all? { |s| s.match?(/\A[0-9a-f]{40}\z/) }
  files = %w[nitro.eif nitro.pcrs]
  files.each do |name|
    path = File.join(directory, name)
    raise "missing regular asset" unless File.file?(path) && !File.symlink?(path) && File.size(path) > 0
  end
  pcrs = File.binread(File.join(directory, "nitro.pcrs"))
  lines = pcrs.lines.map(&:strip)
  raise "invalid PCR set" unless lines.length == 3 &&
    lines.each_with_index.all? { |line, i| line.match?(/\A[0-9a-f]{96} PCR#{i}\z/) }
  %w[aws-x86_64.pcrs SHA256SUMS provenance.json].each do |name|
    path = File.join(directory, name)
    raise "occupied output" if File.exist?(path) || File.symlink?(path)
  end
  File.binwrite(File.join(directory, "aws-x86_64.pcrs"), pcrs)
  files << "aws-x86_64.pcrs"
  assets = files.to_h do |name|
    path = File.join(directory, name)
    [name, {"sha256" => Digest::SHA256.file(path).hexdigest, "size" => File.size(path)}]
  end
  File.write(File.join(directory, "SHA256SUMS"),
    assets.map { |name, meta| "#{meta.fetch("sha256")}  #{name}\n" }.join)
  File.write(File.join(directory, "provenance.json"), JSON.pretty_generate({
    "schema" => "0xkey.qos-pcr-candidate/v1", "source_commit" => source,
    "workflow_commit" => workflow, "assets" => assets,
    "limitations" => ["CI candidate only; no signature, registry publication or independent rebuild claimed"]
  }) + "\n")
rescue KeyError, IndexError, RuntimeError, SystemCallError => error
  warn "PCR bundle rejected: #{error.message}"
  exit 1
end
