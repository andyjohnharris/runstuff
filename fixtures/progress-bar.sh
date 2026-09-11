#!/bin/sh
# Redraws a progress bar with \r and reports the terminal size before and
# after SIGWINCH. After the resize it prints a line exactly as wide as the
# tty reports through TIOCGWINSZ (`stty size`), plus what `tput cols` says:
# ncurses prefers a COLUMNS environment variable over the ioctl, so the two
# can disagree when the job environment sets COLUMNS.
# Phase 0 asserts: \r redraws captured; new size reported; line wraps at it.
# Phase 1 asserts: redraw renders correctly in SwiftTerm.
repeat() {
  ch=$1
  n=$2
  out=""
  while [ "$n" -gt 0 ]; do
    out="${out}${ch}"
    n=$((n - 1))
  done
  printf '%s' "$out"
}

on_winch() {
  echo
  echo "WINCH"
  echo "SIZE $(stty size)"
  cols=$(stty size | cut -d' ' -f2)
  repeat '#' "$cols"
  echo
  echo "TPUT_COLS=$(tput cols)"
  echo "WIDTH-DONE"
}
trap on_winch WINCH

echo "SIZE $(stty size)"
step=0
while [ "$step" -le 40 ]; do
  pct=$((step * 100 / 40))
  filled=$((step / 2))
  printf '\r[%s%s] %3d%%' "$(repeat '#' "$filled")" "$(repeat ' ' $((20 - filled)))" "$pct"
  step=$((step + 1))
  sleep 0.1
done
echo
echo "BAR-DONE"
