#!/usr/bin/env bash
# Host watchdog for the iPhone Duo UI-test step: tells a stalled app from a stalled CI host.
#   host-watchdog.sh DIR UDID TEST_LOG
# Every 10 s it appends the time, the load, vm_stat, the swap and the busiest processes to
# DIR/host.log. When TEST_LOG (xcodebuild's output) has not grown for 60 s it also samples,
# into DIR/samples/, the app and the UI test runner installed on the simulator UDID and that
# simulator's testmanagerd (which serves the accessibility snapshots), at most once every 120 s.
# A sample with the app's main thread busy or blocked answers "the app stalled"; an idle app
# with a busy host (host.log) answers "the host stalled". Runs until it is killed.
set -u
dir=${1:?usage: host-watchdog.sh DIR UDID TEST_LOG}
udid=${2:?usage: host-watchdog.sh DIR UDID TEST_LOG}
testlog=${3:?usage: host-watchdog.sh DIR UDID TEST_LOG}
mkdir -p "$dir/samples"
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
last_size=-1
last_change=$(date +%s)
last_sample=0
while :; do
  now=$(date +%s)
  {
    echo "=== $(stamp)"
    sysctl -n vm.loadavg
    sysctl -n vm.swapusage
    vm_stat
    top -l 1 -n 12 -o cpu -stats pid,command,cpu,mem,state | tail -n 18
  } >> "$dir/host.log" 2>&1
  size=$(stat -f %z "$testlog" 2>/dev/null || echo 0)
  if [ "$size" != "$last_size" ]; then
    last_size=$size
    last_change=$now
  elif [ $((now - last_change)) -ge 60 ] && [ $((now - last_sample)) -ge 120 ]; then
    last_sample=$now
    echo "=== $(stamp) the test log has not grown for $((now - last_change)) s: sampling" >> "$dir/host.log"
    pids=$(pgrep -f "CoreSimulator/Devices/$udid/data/Containers/Bundle/Application" || true)
    pids="$pids $(pgrep -f "Devices/$udid/.*testmanagerd" || true)"
    for pid in $pids; do
      name=$(ps -p "$pid" -o comm= 2>/dev/null | xargs -I{} basename {} || true)
      sample "$pid" 5 -mayDie -file "$dir/samples/$(date -u +%H%M%S)-$pid-${name:-unknown}.txt" >/dev/null 2>&1 &
    done
  fi
  sleep 10
done
