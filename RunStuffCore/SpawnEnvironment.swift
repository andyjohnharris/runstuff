import Darwin

/// Builds the environment RunStuff spawns a job with. Plan §1: launchd env →
/// shell startup files → RunStuff defaults → per-job overrides. The shell
/// layer happens inside the child; this type produces the base and the
/// defaults.
public enum SpawnEnvironment {
  /// A scrubbed base that looks like what launchd hands a GUI app: the
  /// system `PATH` and the identity variables, nothing from the calling
  /// process's shell. Fixtures spawn from this so a version manager on the
  /// caller's `PATH` cannot make a shell-mode test pass vacuously.
  public static func launchdLikeBase() -> [String: String] {
    var env: [String: String] = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
    ]
    for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"] {
      if let value = getenv(key) {
        env[key] = String(cString: value)
      }
    }
    if env["SHELL"] == nil { env["SHELL"] = "/bin/zsh" }
    if env["HOME"] == nil, let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
      env["HOME"] = String(cString: dir)
    }
    return env
  }

  /// RunStuff's own defaults for a job.
  ///
  /// Deliberately does NOT set `COLUMNS`/`LINES`. The `TIOCSWINSZ` ioctl is
  /// the single source of terminal size and stays correct across resizes;
  /// an env var is a stale snapshot that ncurses treats as an override
  /// (unless the program calls `use_env(FALSE)`). Setting them would add a
  /// wrong answer that beats the right one after the first resize. Shell
  /// modes additionally `unset COLUMNS LINES` so a value exported from the
  /// user's rc files cannot leak in from an unrelated window.
  public static func jobDefaults(jobID: String, windowSize: WindowSize) -> [String: String] {
    [
      "TERM": "xterm-256color",
      "RUNSTUFF_JOB": jobID,
    ]
  }

  /// Later layers override earlier ones.
  public static func layered(_ layers: [String: String]...) -> [String: String] {
    var result: [String: String] = [:]
    for layer in layers {
      for (key, value) in layer { result[key] = value }
    }
    return result
  }

  /// The caller's login shell, for shell modes.
  public static func loginShell() -> String {
    if let value = getenv("SHELL") { return String(cString: value) }
    return "/bin/zsh"
  }

  /// Resolves a bare command name against a `PATH` string the way `execvp`
  /// would. Returns nil when nothing executable is found. Names containing
  /// a slash are returned unchanged.
  public static func resolveExecutable(_ name: String, path: String) -> String? {
    if name.contains("/") { return name }
    for dir in path.split(separator: ":") where !dir.isEmpty {
      let candidate = "\(dir)/\(name)"
      if access(candidate, X_OK) == 0 {
        var st = stat()
        if stat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
          return candidate
        }
      }
    }
    return nil
  }
}
