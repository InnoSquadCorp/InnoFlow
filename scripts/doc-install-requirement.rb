# frozen_string_literal: true

require "json"

# Reads the InnoFlow requirement of a documented installation manifest from
# `swift package dump-package` JSON. The JSON also holds the requirement's
# upper bound and the tools version, so finding the release target anywhere
# in it proves nothing; only the requirement's lower bound does.
module DocInstallRequirement
  URL = "https://github.com/InnoSquadCorp/InnoFlow.git"

  module_function

  # The source-control dependencies of a parsed manifest that point at URL.
  def innoflow_dependencies(package)
    package.fetch("dependencies").flat_map { |dependency| Array(dependency["sourceControl"]) }.select do |source|
      remotes = Array(source.dig("location", "remote")).map { |remote| remote.is_a?(Hash) ? remote["urlString"] : remote }
      remotes == [URL]
    end
  end

  # nil when the manifest requires InnoFlow `from: release_target`, otherwise
  # a description of what it requires instead.
  def version_drift(package, release_target)
    dependencies = innoflow_dependencies(package)
    return "#{dependencies.length} dependencies on #{URL} instead of one" unless dependencies.length == 1

    requirement = dependencies.first["requirement"]
    ranges = requirement.is_a?(Hash) ? requirement["range"] : nil
    lower_bound = ranges.first["lowerBound"] if ranges.is_a?(Array) && ranges.length == 1 && ranges.first.is_a?(Hash)
    return nil if lower_bound == release_target

    "requirement #{JSON.generate(requirement)} does not start at #{release_target}"
  end
end
