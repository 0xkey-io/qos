require "minitest/autorun"
require "tmpdir"
require "open3"
require "json"

class PcrBundleTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/qos-pcr-bundle.rb", __dir__)
  def test_bundle_rejects_invalid_inputs
    %w[valid missing malformed duplicate symlink source].each do |scenario|
      Dir.mktmpdir do |dir|
        File.binwrite("#{dir}/nitro.eif", "fixture-eif")
        pcrs = (0..2).map { |i| "#{"a" * 96} PCR#{i}" }.join("\n")
        pcrs = "not-pcrs" if scenario == "malformed"
        pcrs += "\n#{"b" * 96} PCR0" if scenario == "duplicate"
        File.write("#{dir}/nitro.pcrs", pcrs)
        File.unlink("#{dir}/nitro.eif") if %w[missing symlink].include?(scenario)
        File.symlink("nitro.pcrs", "#{dir}/nitro.eif") if scenario == "symlink"
        env = {"SOURCE_SHA" => scenario == "source" ? "main" : "a" * 40,
               "WORKFLOW_SHA" => "b" * 40}
        _out, err, status = Open3.capture3(env, "ruby", SCRIPT, dir)
        if scenario == "valid"
          assert status.success?, err
          assert_equal pcrs, File.read("#{dir}/aws-x86_64.pcrs")
          assert_equal "a" * 40, JSON.parse(File.read("#{dir}/provenance.json"))["source_commit"]
        else
          refute status.success?, scenario
          refute File.exist?("#{dir}/provenance.json")
        end
      end
    end
  end
end
