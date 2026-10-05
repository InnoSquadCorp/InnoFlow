#!/usr/bin/env ruby
# Exact date gate for a tagged candidate; an untagged development tree may remain Unreleased.
require 'date'
path, version = ARGV
abort '[release-date] Usage: check-release-date.rb CHANGELOG VERSION' unless path && version
headers = File.readlines(path, chomp: true).grep(/^## \[#{Regexp.escape(version)}\] - /)
unless headers.length == 1 && (match = headers.first.match(/\A## \[#{Regexp.escape(version)}\] - (\d{4}-\d{2}-\d{2})\z/))
  abort "[release-date] Tagged #{version} requires exactly one CHANGELOG heading with YYYY-MM-DD; Unreleased is not release evidence."
end
begin
  Date.iso8601(match[1])
rescue ArgumentError
  abort "[release-date] Invalid calendar date: #{match[1]}"
end
puts "[release-date] #{version}: #{match[1]}"
