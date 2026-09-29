#!/usr/bin/env ruby
# frozen_string_literal: true

module ReleaseRuntimeCatalog
  RUNTIME_PLATFORMS = {
    "ios" => "iOS",
    "tvos" => "tvOS",
    "watchos" => "watchOS",
    "visionos" => "xrOS",
  }.freeze

  DEVICE_TYPES = {
    "ios" => %w[com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro],
    "tvos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K],
    "watchos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10-46mm],
    "visionos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro],
  }.freeze

  def self.runtime_info(check)
    match = /\Aruntime-(ios|tvos|watchos|visionos)-\d+\.\d+\z/.match(check.fetch("id"))
    return nil unless match

    platform = match[1]
    version = check.fetch("environment").fetch("os")
    runtime = "com.apple.CoreSimulator.SimRuntime.#{RUNTIME_PLATFORMS.fetch(platform)}-#{version.tr('.', '-')}"
    [runtime, DEVICE_TYPES.fetch(platform), check.fetch("environment").fetch("platform")]
  end
end
