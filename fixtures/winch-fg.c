// Deterministic coverage for resize under job control (finding #4): the
// kernel sends SIGWINCH to the tty's foreground process group, which job
// control can move away from the job leader. This program is spawned as the
// job leader (session leader, controlling terminal on fd 0). It forks a child,
// puts the child in its own process group, and makes that group the tty's
// foreground group with tcsetpgrp. So tcgetpgrp(master) is the child's group,
// not the leader's, and a correct resize() must target the child.
//
// Compiled by the harness with /usr/bin/cc (base-system, no dependency).

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t got_winch = 0;
static void on_winch(int sig) { (void)sig; got_winch = 1; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    // Does this raw (non-shell) spawned program have a controlling terminal?
    int tty = open("/dev/tty", O_RDWR);
    printf("LEADER-CTTY %s\n", tty >= 0 ? "yes" : "no");
    if (tty >= 0) close(tty);
    printf("LEADER-FG0 %d\n", (int)tcgetpgrp(0));

    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }

    if (child == 0) {
        setpgid(0, 0); // own process group
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_winch;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGWINCH, &sa, NULL);
        printf("CHILD-PGID %d\n", (int)getpgrp());
        printf("READY\n");
        for (int i = 0; i < 300; i++) {
            if (got_winch) {
                got_winch = 0;
                struct winsize ws;
                if (ioctl(0, TIOCGWINSZ, &ws) == 0)
                    printf("SIZE %d %d\n", (int)ws.ws_row, (int)ws.ws_col);
            }
            usleep(100000);
        }
        printf("CHILD-DONE\n");
        _exit(0);
    }

    setpgid(child, child);   // put the child in its own group
    tcsetpgrp(0, child);     // and foreground it on the controlling terminal
    printf("LEADER-PGID %d FG %d\n", (int)getpgrp(), (int)tcgetpgrp(0));
    int status;
    waitpid(child, &status, 0);
    printf("LEADER-DONE\n");
    return 0;
}
