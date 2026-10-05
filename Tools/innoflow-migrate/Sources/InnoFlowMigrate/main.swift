import Foundation
import MigrationCore

struct CommandFailure: Error, CustomStringConvertible {
  let description: String
}

@main
struct MigrateCommand {
  static func main() {
    do { try run() } catch {
      report("innoflow-migrate: \(error)")
      exit(2)
    }
  }

  private static func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments == ["--help"] {
      print("""
      Usage: innoflow-migrate [--write | --check] FILE.swift ...
      Default: unified diff on stdout; edit/blocker report on stderr. No writes.
      --write: apply a blocker-free batch, retaining FILE.swift.innoflow-migrate.bak.
      --check: exit 1 when edits are pending; exit 2 for blockers/errors.
      Explicit file paths only. No recursion, symlinks, or async/range/lifetime guessing.
      """)
      return
    }
    let writes = arguments.contains("--write")
    let checks = arguments.contains("--check")
    guard !(writes && checks) else { throw CommandFailure(description: "Choose either --write or --check.") }
    guard !arguments.contains(where: { $0.hasPrefix("--") && $0 != "--write" && $0 != "--check" }) else {
      throw CommandFailure(description: "Unknown option. Use --help.")
    }
    let paths = arguments.filter { !$0.hasPrefix("--") }
    guard !paths.isEmpty else { throw CommandFailure(description: "Provide at least one Swift source file.") }
    var plans: [(path: String, original: String, result: MigrationResult)] = []
    var seen = Set<String>()
    for path in paths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension == "swift" else {
        throw CommandFailure(description: "Expected a regular, nonsymlink .swift file: \(path)")
      }
      guard seen.insert(url.resolvingSymlinksInPath().path).inserted else {
        throw CommandFailure(description: "Duplicate input file: \(path)")
      }
      let source = try String(contentsOf: url, encoding: .utf8)
      plans.append((url.path, source, InnoFlowMigration.migrate(source)))
    }
    for plan in plans {
      for change in plan.result.changes { report("\(plan.path): edit: \(change)") }
      for blocker in plan.result.blockers { report("\(plan.path): blocker: \(blocker)") }
      if plan.result.isChanged { print(diff(path: plan.path, old: plan.original, new: plan.result.source), terminator: "") }
    }
    guard !plans.contains(where: { !$0.result.blockers.isEmpty }) else {
      throw CommandFailure(description: "Manual decisions are required; no input files were written.")
    }
    let changed = plans.filter { $0.result.isChanged }
    if writes {
      // Preflight every backup before creating any; retain originals if a write fails.
      for plan in changed {
        guard !FileManager.default.fileExists(atPath: backupPath(plan.path)) else {
          throw CommandFailure(description: "Backup already exists: \(backupPath(plan.path)); preserve or move it before retrying.")
        }
        guard try String(contentsOfFile: plan.path, encoding: .utf8) == plan.original else {
          throw CommandFailure(description: "Input changed during planning: \(plan.path); nothing was written.")
        }
      }
      for plan in changed { try FileManager.default.copyItem(atPath: plan.path, toPath: backupPath(plan.path)) }
      for plan in changed {
        try plan.result.source.write(toFile: plan.path, atomically: true, encoding: .utf8)
        report("Updated \(plan.path); original retained at \(backupPath(plan.path))")
      }
    }
    report("Reviewed \(plans.count) file(s): \(changed.count) changed, 0 blockers\(writes ? ", applied" : ", dry-run")")
    if checks && !changed.isEmpty { exit(1) }
  }

  private static func backupPath(_ path: String) -> String { path + ".innoflow-migrate.bak" }

  private static func report(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  /// Whole-file unified hunks remain patch-compatible, even without a final newline.
  private static func diff(path: String, old: String, new: String) -> String {
    func lines(_ source: String) -> [String] {
      guard !source.isEmpty else { return [] }
      var result = source.components(separatedBy: "\n")
      if source.hasSuffix("\n") { result.removeLast() }
      return result
    }
    let before = lines(old), after = lines(new)
    var result = "--- \(path)\n+++ \(path)\n@@ -\(before.isEmpty ? 0 : 1),\(before.count) +\(after.isEmpty ? 0 : 1),\(after.count) @@\n"
    result += before.map { "-\($0)\n" }.joined()
    if !old.isEmpty && !old.hasSuffix("\n") { result += "\\ No newline at end of file\n" }
    result += after.map { "+\($0)\n" }.joined()
    if !new.isEmpty && !new.hasSuffix("\n") { result += "\\ No newline at end of file\n" }
    return result
  }
}
