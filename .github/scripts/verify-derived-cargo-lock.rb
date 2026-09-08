#!/usr/bin/env ruby
# frozen_string_literal: true

def fail_closed(message)
  warn "verify-derived-cargo-lock: #{message}"
  exit 1
end

def packages(path)
  fail_closed("lock file is missing: #{path}") unless File.file?(path)
  parsed = []
  current = nil

  File.foreach(path, chomp: true) do |line|
    if line == "[[package]]"
      parsed << finish_package(current, path) if current
      current = {}
      next
    end
    next unless current

    match = line.match(/\A(name|version|source|checksum) = "([^"]*)"\z/)
    next unless match
    fail_closed("duplicate #{match[1]} in #{path}") if current.key?(match[1])

    current[match[1]] = match[2]
  end
  parsed << finish_package(current, path) if current
  fail_closed("lock file has no packages: #{path}") if parsed.empty?
  parsed
end

def finish_package(package, path)
  fail_closed("package missing name in #{path}") if package["name"].to_s.empty?
  fail_closed("package missing version in #{path}") if package["version"].to_s.empty?
  [package["name"], package["version"], package["source"], package["checksum"]]
end

original_path, derived_path = ARGV
fail_closed("usage: verify-derived-cargo-lock.rb ORIGINAL DERIVED") unless original_path && derived_path && ARGV.length == 2

available = Hash.new(0)
packages(original_path).each { |package| available[package] += 1 }
derived = packages(derived_path)
derived.each do |package|
  unless available.fetch(package, 0).positive?
    fail_closed("derived lock introduced package outside original lock: #{package.inspect}")
  end
  available[package] -= 1
end

puts "derived_lock_packages=#{derived.length}"
