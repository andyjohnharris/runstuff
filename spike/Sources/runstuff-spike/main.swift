import Darwin
import Foundation
import RunStuffCore

// runstuff-spike: phase 0 harness.
//
//   runstuff-spike fixtures/<name>.sh        run one fixture's scenario and assert
//   runstuff-spike --all [fixturesDir]        run every scenario
//   runstuff-spike --manual fixtures/<name>.sh   act as a terminal for the fixture
//   options: --shell login|interactive|direct (manual mode), --verbose

typealias Scenario = @Sendable (Harness) async -> ScenarioReport

struct ScenarioEntry {
  let fixture: String
  let deadline: Duration
  let run: Scenario
}

let scenarios: [ScenarioEntry] = [
  ScenarioEntry(fixture: "exit-clean.sh", deadline: .seconds(60), run: exitCleanScenario),
  ScenarioEntry(fixture: "exit-fail.sh", deadline: .seconds(60), run: exitFailScenario),
  ScenarioEntry(
    fixture: "writes-then-exits.sh", deadline: .seconds(60), run: writesThenExitsScenario),
  ScenarioEntry(fixture: "not-found.sh", deadline: .seconds(60), run: notFoundScenario),
  ScenarioEntry(fixture: "ctty-probe.sh", deadline: .seconds(60), run: cttyProbeScenario),
  ScenarioEntry(fixture: "ctrl-c.sh", deadline: .seconds(30), run: ctrlCScenario),
  ScenarioEntry(fixture: "crash-delayed.sh", deadline: .seconds(60), run: crashDelayedScenario),
  ScenarioEntry(fixture: "prompt-wait.sh", deadline: .seconds(30), run: promptWaitScenario),
  ScenarioEntry(fixture: "progress-bar.sh", deadline: .seconds(60), run: progressBarScenario),
  ScenarioEntry(fixture: "winch-fg", deadline: .seconds(60), run: resizeJobControlScenario),
  ScenarioEntry(fixture: "eof-isolation", deadline: .seconds(30), run: eofIsolationScenario),
  ScenarioEntry(fixture: "colours.sh", deadline: .seconds(30), run: coloursScenario),
  ScenarioEntry(fixture: "spawns-children.sh", deadline: .seconds(60), run: spawnsChildrenScenario),
  ScenarioEntry(fixture: "job-control.sh", deadline: .seconds(90), run: jobControlScenario),
  ScenarioEntry(fixture: "ignores-sigterm.sh", deadline: .seconds(60), run: ignoresSigtermScenario),
  ScenarioEntry(fixture: "binds-port.sh", deadline: .seconds(60), run: bindsPortScenario),
  ScenarioEntry(fixture: "crash-loop.sh", deadline: .seconds(120), run: crashLoopScenario),
  ScenarioEntry(fixture: "reap-stress", deadline: .seconds(120), run: reapStressScenario),
  ScenarioEntry(fixture: "firehose.sh", deadline: .seconds(240), run: firehoseScenario),
  ScenarioEntry(fixture: "nvm-project", deadline: .seconds(120), run: nvmProjectScenario),
  ScenarioEntry(fixture: "mise-project", deadline: .seconds(120), run: miseProjectScenario),
]

func usage() -> Never {
  print(
    """
    usage: runstuff-spike [--verbose] fixtures/<name>.sh
           runstuff-spike [--verbose] --all [fixturesDir]
           runstuff-spike [--shell login|interactive|direct] --manual fixtures/<name>.sh
    """)
  exit(2)
}

func absolute(_ path: String) -> String {
  if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
    .standardizedFileURL.path
}

var args = Array(CommandLine.arguments.dropFirst())
var verbose = false
var all = false
var manual = false
var manualMode = ShellMode.login
var target: String?

while !args.isEmpty {
  let arg = args.removeFirst()
  switch arg {
  case "--verbose": verbose = true
  case "--all": all = true
  case "--manual": manual = true
  case "--shell":
    guard !args.isEmpty else { usage() }
    switch args.removeFirst() {
    case "login": manualMode = .login
    case "interactive": manualMode = .interactiveLogin
    case "direct": manualMode = .direct
    default: usage()
    }
  case "-h", "--help": usage()
  default:
    if arg.hasPrefix("-") { usage() }
    target = arg
  }
}

let fixturesDirectory: String
if all {
  fixturesDirectory = absolute(target ?? "fixtures")
} else if let target {
  let path = absolute(target)
  if FileManager.default.fileExists(atPath: path) {
    // A file path like fixtures/foo.sh: the fixtures dir is its parent.
    fixturesDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
  } else {
    // A bare scenario name like winch-fg or reap-stress: default to
    // ./fixtures rather than deriving a directory from the name.
    fixturesDirectory = absolute("fixtures")
  }
} else {
  usage()
}
let repoRoot = URL(fileURLWithPath: fixturesDirectory).deletingLastPathComponent().path
guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
  fatalError("could not locate runstuff-spike executable directory")
}
let ttyHelperPath = executableDirectory.appendingPathComponent("runstuff-tty-helper").path
guard FileManager.default.isExecutableFile(atPath: ttyHelperPath) else {
  fatalError("required tty helper is missing or not executable: \(ttyHelperPath)")
}

let spoolDirectory: String = {
  let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
  let dir = "\(base)/runstuff-spike-\(getpid())"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir
}()

let harness = Harness(
  fixturesDirectory: fixturesDirectory,
  repoRoot: repoRoot,
  shell: SpawnEnvironment.loginShell(),
  spoolDirectory: spoolDirectory,
  ttyHelperPath: ttyHelperPath,
  verbose: verbose)

// Our own SIGPIPE would otherwise kill the harness when a job closes early.
signal(SIGPIPE, SIG_IGN)

// A supervisor manages many jobs, each holding a master fd and a spool fd.
// Raise the fd limit off the 256 default so concurrent churn does not hit
// EMFILE and fail openpty.
var fdLimit = rlimit()
if getrlimit(RLIMIT_NOFILE, &fdLimit) == 0 {
  fdLimit.rlim_cur = min(fdLimit.rlim_max, 8192)
  setrlimit(RLIMIT_NOFILE, &fdLimit)
}

let exitCode: Int32 = await {
  if manual {
    guard let target else { usage() }
    let name = URL(fileURLWithPath: target).lastPathComponent
    return await ManualRunner.run(harness, fixture: name, mode: manualMode)
  }
  print("shell: \(harness.shell); fixtures: \(harness.fixturesDirectory)")
  var selected = scenarios
  if !all, let target {
    let name = URL(fileURLWithPath: target).lastPathComponent
    selected = scenarios.filter { $0.fixture == name }
    if selected.isEmpty {
      print("no scenario for \(name); known: \(scenarios.map(\.fixture).joined(separator: ", "))")
      return 2
    }
  }
  var reports: [ScenarioReport] = []
  for entry in selected {
    let report = await withDeadline(entry.fixture, entry.deadline) { await entry.run(harness) }
    Reporter.print(report)
    reports.append(report)
  }
  await LiveJobs.shared.killAll()
  return Reporter.summary(reports)
}()

try? FileManager.default.removeItem(atPath: spoolDirectory)
exit(exitCode)
