#!/nix/store/lg40wk3i14yx460i4yk3yh1fpah4mmpb-system-path/bin/bash
set -ve
PID="$(pgrep -x dupefix)"

ps -o pid,ppid,etime,%cpu,%mem,state,command -p "$PID"

echo "Creating sample of thread activity over the last 5 seconds"

sample "$PID" 5