import RunStuffCore

/// Which delivery phase owns an assertion. Plan §7.
enum Phase: Int, Sendable, Comparable {
  case p0 = 0
  case p1 = 1
  case p2 = 2

  static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
  var label: String { "phase \(rawValue)" }
}

enum Outcome: Sendable {
  case pass(String?)
  case fail(String)
  /// Owned by a later phase; reported so the inventory stays visible.
  case deferred
  /// A precondition the machine does not meet, or a check blocked by an
  /// earlier failed check.
  case skipped(String)
}

struct AssertionResult: Sendable {
  let name: String
  let phase: Phase
  let planRef: String?
  let outcome: Outcome
}

struct ScenarioReport: Sendable {
  let name: String
  var results: [AssertionResult] = []
  var notes: [String] = []
  var hung = false

  var failures: Int {
    results.filter {
      if case .fail = $0.outcome { return true }
      return false
    }.count
  }
}

/// Accumulates one scenario's assertions. Lives inside a single task.
final class Check {
  private(set) var report: ScenarioReport

  init(_ name: String) {
    report = ScenarioReport(name: name)
  }

  func p0(_ name: String, _ ok: Bool, detail: String = "") {
    report.results.append(
      AssertionResult(
        name: name, phase: .p0, planRef: nil,
        outcome: ok ? .pass(detail.isEmpty ? nil : detail) : .fail(detail)))
  }

  func p1(_ name: String, _ ok: Bool, detail: String = "", ref: String) {
    report.results.append(
      AssertionResult(
        name: name, phase: .p1, planRef: ref,
        outcome: ok ? .pass(detail.isEmpty ? nil : detail) : .fail(detail)))
  }

  func p2(_ name: String, _ ok: Bool, detail: String = "", ref: String) {
    report.results.append(
      AssertionResult(
        name: name, phase: .p2, planRef: ref,
        outcome: ok ? .pass(detail.isEmpty ? nil : detail) : .fail(detail)))
  }

  func deferred(_ name: String, phase: Phase, ref: String) {
    report.results.append(
      AssertionResult(name: name, phase: phase, planRef: ref, outcome: .deferred))
  }

  func skipped(_ name: String, phase: Phase = .p0, reason: String) {
    report.results.append(
      AssertionResult(name: name, phase: phase, planRef: nil, outcome: .skipped(reason)))
  }

  func note(_ text: String) {
    report.notes.append(text)
  }

  func hung() {
    report.hung = true
  }
}

/// Plain-text reporter.
enum Reporter {
  static func print(_ report: ScenarioReport) {
    Swift.print("== \(report.name)")
    for result in report.results {
      switch result.outcome {
      case .pass(let detail):
        Swift.print("  PASS     \(result.name)\(detail.map { " — \($0)" } ?? "")")
      case .fail(let detail):
        Swift.print("  FAIL     \(result.name) — \(detail)")
      case .deferred:
        Swift.print("  SKIPPED  [\(result.phase.label), \(result.planRef ?? "")] \(result.name)")
      case .skipped(let reason):
        Swift.print("  SKIPPED  \(result.name) — \(reason)")
      }
    }
    for note in report.notes {
      Swift.print("  NOTE     \(note)")
    }
    if report.hung {
      Swift.print("  FAIL     scenario timed out; job killed")
    }
  }

  /// Prints totals and the deferred inventory. Returns the process exit code.
  static func summary(_ reports: [ScenarioReport]) -> Int32 {
    var pass = 0
    var fail = 0
    var deferred: [(Phase, String, String)] = []
    var preconditionSkips = 0
    for report in reports {
      if report.hung { fail += 1 }
      for result in report.results {
        switch result.outcome {
        case .pass: pass += 1
        case .fail: fail += 1
        case .deferred:
          deferred.append((result.phase, report.name, "\(result.name) (\(result.planRef ?? ""))"))
        case .skipped: preconditionSkips += 1
        }
      }
    }
    Swift.print("")
    Swift.print(
      "== summary: \(reports.count) scenarios — \(pass) PASS, \(fail) FAIL, \(deferred.count) deferred, \(preconditionSkips) skipped"
    )
    if !deferred.isEmpty {
      Swift.print("== deferred inventory (owed by later phases)")
      for phase in [Phase.p1, .p2] {
        let items = deferred.filter { $0.0 == phase }
        if items.isEmpty { continue }
        Swift.print("  \(phase.label):")
        for item in items {
          Swift.print("    \(item.1): \(item.2)")
        }
      }
    }
    return fail == 0 ? 0 : 1
  }
}

func formatSeconds(_ duration: Duration) -> String {
  let s = duration.seconds
  if s < 1 { return "\(Int(s * 1000)) ms" }
  return String(format2(s)) + " s"
}

private func format2(_ value: Double) -> String {
  let rounded = (value * 100).rounded() / 100
  let whole = Int(rounded)
  let frac = Int(((rounded - Double(whole)) * 100).rounded())
  return "\(whole).\(frac < 10 ? "0" : "")\(frac)"
}

func formatBytes(_ count: UInt64) -> String {
  var digits = Array(String(count))
  var out: [Character] = []
  var i = 0
  while let ch = digits.popLast() {
    if i > 0 && i % 3 == 0 { out.append(",") }
    out.append(ch)
    i += 1
  }
  return String(out.reversed())
}
