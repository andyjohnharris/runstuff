import Foundation
import RunStuffCore

/// A tool or configuration a fixture needs. Unmet preconditions make the
/// scenario report SKIPPED with the reason, never FAIL.
enum Precondition {
  case met
  case unmet(String)

  static func nvm(home: String) -> Precondition {
    let nvmScript = "\(home)/.nvm/nvm.sh"
    guard FileManager.default.fileExists(atPath: nvmScript) else {
      return .unmet("\(nvmScript) not found")
    }
    let versions = "\(home)/.nvm/versions/node"
    let installed = (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []
    guard installed.contains(where: { $0.hasPrefix("v24") }) else {
      return .unmet("no node v24 under \(versions); found \(installed.sorted())")
    }
    return .met
  }

  /// True when, from a scrubbed login shell in `projectDir`, `node`
  /// resolves through mise (shim or install).
  static func mise(harness: Harness, projectDir: String) -> Precondition {
    let probe = harness.runOutsidePTY(
      [harness.shell, "-l", "-c", "cd '\(projectDir)' && command -v node && node -v"],
      cwd: projectDir)
    let lines = probe.stdout.split(separator: "\n").map(String.init)
    guard probe.code == 0, let resolved = lines.first else {
      return .unmet(
        "scrubbed `\(harness.shell) -l -c 'command -v node'` failed (exit \(probe.code))")
    }
    guard resolved.contains("/mise/") else {
      return .unmet("node on the login PATH is \(resolved), not a mise shim or install")
    }
    guard lines.count > 1, lines[1].hasPrefix("v24") else {
      return .unmet(
        "mise resolved node \(lines.dropFirst().first ?? "?") for this project, wanted v24")
    }
    return .met
  }
}
