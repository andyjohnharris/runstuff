// RunStuff's bundled runstuff-tty-helper
//
// posix_spawn cannot give a child a controlling terminal: acquiring one needs
// ioctl(slave, TIOCSCTTY) run in the child after SETSID and before exec, and
// posix_spawn has no hook there and macOS has no POSIX_SPAWN_SETCTTY. The
// phase 0 spike proved a raw spawned program gets no ctty (open("/dev/tty")
// fails); shells only worked because they acquire it themselves on startup.
//
// So the supervisor posix_spawns this helper instead of the command. By then
// POSIX_SPAWN_SETSID has made the helper a session leader and the file actions
// have put the PTY slave on fds 0/1/2. The helper acquires the slave as its
// controlling terminal and execs the real command in place. exec preserves the
// pid, so the pid posix_spawn returned is still the final process and nothing
// in the reap or signal paths changes.
//
// argv[1] is the resolved absolute path of the real command; argv[2..] its
// arguments. The command path is pre-resolved by the supervisor, so execv (no
// PATH search) is correct here.

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fputs("runstuff-tty-helper: no command given\n", stderr);
        return 125;
    }

    // Already a session leader with no controlling terminal (SETSID). Acquire
    // the slave, now on fd 0, as the controlling terminal.
    if (ioctl(0, TIOCSCTTY, 0) == -1) {
        fprintf(stderr, "runstuff-tty-helper: TIOCSCTTY: %s\n", strerror(errno));
        return 125;
    }

    execv(argv[1], &argv[1]);

    int err = errno;
    fprintf(stderr, "runstuff: %s: %s\n", argv[1], strerror(err));
    return (err == EACCES || err == EPERM || err == ENOEXEC) ? 126 : 127;
}
