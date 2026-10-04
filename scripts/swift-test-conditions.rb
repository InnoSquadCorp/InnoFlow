# frozen_string_literal: true

require "json"
require "open3"

# Use the same reviewed selector for the policy, focused runner and receipts.
module SwiftTestConditions
  module_function

  def resolve(operation, inventory: nil, compiler_output: nil, runtime_identity: nil, summary: nil, tests: nil)
    output, error, status = Open3.capture3(
      "python3", File.join(__dir__, "swift_test_conditions.py"),
      stdin_data: JSON.generate({"operation" => operation, "inventory" => inventory,
                                "compilerOutput" => compiler_output, "runtimeIdentity" => runtime_identity,
                                "summary" => summary, "tests" => tests})
    )
    raise ArgumentError, error.strip unless status.success?
    JSON.parse(output)
  end
end
