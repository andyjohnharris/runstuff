// Raw-binary coverage that the PTY is a controlling terminal: with the
// default termios ISIG setting, writing 0x03 to the master must terminate this
// process with SIGINT. A shell wrapper could acquire the ctty itself and hide
// a broken spawn path, so this fixture deliberately contains no shell.

#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("READY");
    for (;;) pause();
}
