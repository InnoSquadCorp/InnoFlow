#!/usr/bin/env ruby
# Diagnostic-only. Never produces a release receipt or changes the pinned policy.
require_relative 'hosted-release-preflight'
require 'optparse'
options = {}
OptionParser.new do |parser|
  parser.on('--check-id ID') { |v| options[:id] = v }
  parser.on('--output PATH') { |v| options[:output] = v }
  parser.on('--smoke') { options[:smoke] = true }
end.parse!
begin
  root = File.expand_path('..', __dir__)
  runner = HostedReleasePreflight.new(root)
  runner.hosted_environment!
  raise 'Unexpected arguments' unless ARGV.empty?
  allowed = %w[runtime-ios-18.5 runtime-tvos-18.5 runtime-watchos-11.5 runtime-visionos-2.5]
  id = options.fetch(:id)
  raise 'Probe requires an exact reviewed legacy runtime' unless allowed.include?(id)
  output = runner.outside!(options.fetch(:output))
  raise 'Unexpected selected Xcode' unless ENV['DEVELOPER_DIR'] == '/Applications/Xcode_26.6.app/Contents/Developer'
  policy = JSON.parse(File.read(File.join(root, 'docs/contracts/release-evidence-policy.json')))
  check = policy.fetch('checks').find { |entry| entry.fetch('id') == id }
  raise 'Pinned runtime missing' unless check
  FileUtils.mkdir_p(output)
  source = runner.capture!('git', 'rev-parse', 'HEAD').strip
  xcode = runner.capture!('xcodebuild', '-version')
  swift = runner.capture!('xcrun', 'swift', '--version')
  raise 'Xcode 26.6 required' unless xcode.lines.first.to_s.strip == 'Xcode 26.6'
  raise 'Swift 6.3 required' unless swift.match?(/\bversion 6\.3(?:\.|\b)/)
  File.write(File.join(output, 'environment.json'), JSON.pretty_generate({
    'purpose' => 'diagnostic-only; not release evidence', 'sha' => source,
    'check' => id, 'xcode' => xcode, 'swift' => swift,
    'runner' => ENV.to_h.slice('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'RUNNER_OS', 'RUNNER_ARCH', 'ImageOS', 'ImageVersion')
  }) + "\n")
  runner.with_provisioning_diagnostics(id, output) { runner.provision_runtime!(check) }
  File.write(File.join(output, 'runtimes.json'), runner.capture!('xcrun', 'simctl', 'list', 'runtimes', '-j'))
  if options[:smoke]
    runtime, device_types, = ReleaseRuntimeCatalog.runtime_info(check)
    device = runner.capture!('xcrun', 'simctl', 'create', 'InnoFlow diagnostic probe', device_types.first, runtime).strip
    raise 'Invalid simulator identifier' unless device.match?(/\A[0-9A-Fa-f-]{36}\z/)
    begin
      runner.run!(File.join(root, 'scripts/run-focused-platform-runtime-tests.sh'),
        '--destination', "id=#{device}", '--derived-data', File.join(output, 'DerivedData'),
        '--result-bundle', File.join(output, 'smoke.xcresult'))
    ensure
      runner.run!('xcrun', 'simctl', 'delete', device)
    end
  end
  File.write(File.join(output, 'probe-success.json'), JSON.generate({ 'sha' => source, 'check' => id, 'smoke' => !!options[:smoke] }) + "\n")
rescue StandardError => error
  abort "[runtime-provisioning-probe] #{error.class}: #{error.message}"
end
