#!/bin/zsh
# Runs the crash-safe shield scenarios against the real window server. Each one covers this
# Mac's screens for a few seconds and then releases on its own (test-mode autorelease, hard
# deadlines). Nothing is installed or registered. Usage: run-scenarios.sh BIN_DIR OUT_DIR
set -u
BIN=$1; OUT=$2; mkdir -p "$OUT"
K="$BIN/ShieldKeeper"; A="$BIN/FakeSender"; T="$BIN/CoverageTrace"
cleanup() { pkill -9 -f "^$K" 2>/dev/null; pkill -9 -f "^$A" 2>/dev/null; rm -f "$OUT/marker"; }
trap cleanup EXIT INT TERM
wait_gone() { for i in {1..200}; do kill -0 $1 2>/dev/null || return 0; sleep 0.05; done; }
pid_of() { pgrep -f "^$1" | head -1; }
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

# B1: app crashes (kill -9) while covering; the keeper keeps covering, then test-releases.
"$T" --out "$OUT/trace-B1.json" --seconds 12 > /dev/null & TR=$!
sleep 0.5
"$A" --log "$OUT/app-B1.log" --deadline 14 --session iPhone --keeper "$K" --keeper-log "$OUT/keeper-B1.log" \
     --keeper-args "--test-mode --test-autorelease 7 --no-lock --deadline 14" & APP=$!
sleep 3; echo "$(ms) kill -9 app" >> "$OUT/script-B1.log"; kill -9 $APP
wait $TR; cleanup; sleep 1

# B2: normal Quit while covering; the keeper stays (held), no lock, then test-releases and exits.
"$T" --out "$OUT/trace-B2.json" --seconds 10 > /dev/null & TR=$!
sleep 0.5
"$A" --log "$OUT/app-B2.log" --deadline 12 --session iPhone --clean-quit-after 3 --keeper "$K" --keeper-log "$OUT/keeper-B2.log" \
     --keeper-args "--test-mode --test-autorelease 6 --no-lock --deadline 12" &
wait $TR; cleanup; sleep 1

# B3: the keeper is killed; the app's own covers stay until its normal Quit.
"$T" --out "$OUT/trace-B3.json" --seconds 8 > /dev/null & TR=$!
sleep 0.5
"$A" --log "$OUT/app-B3.log" --deadline 10 --session iPhone --clean-quit-after 5 --keeper "$K" --keeper-log "$OUT/keeper-B3.log" \
     --keeper-args "--test-mode --no-lock --deadline 10" &
sleep 2.5; KP=$(pid_of "$K"); echo "$(ms) kill -9 keeper $KP" >> "$OUT/script-B3.log"; kill -9 $KP
wait $TR; cleanup; sleep 1

# A1: no keeper; the app is killed and relaunched at once (what launchd KeepAlive would do,
# minus launchd's own delay); the relaunch covers from the marker.
"$T" --out "$OUT/trace-A1.json" --seconds 8 > /dev/null & TR=$!
sleep 0.5
"$A" --log "$OUT/app-A1.log" --deadline 10 --session iPhone --marker "$OUT/marker" & APP=$!
sleep 2.5; echo "$(ms) kill -9 app" >> "$OUT/script-A1.log"; kill -9 $APP; wait_gone $APP
echo "$(ms) relaunch" >> "$OUT/script-A1.log"
"$A" --log "$OUT/app-A1.log" --deadline 10 --session relaunch --marker "$OUT/marker" --clean-quit-after 3 &
wait $TR; cleanup; sleep 1

# B4: double failure: the keeper's main thread hangs and the app is killed. The watchdog
# locks (logged only here) and exits; from then on only the lock would protect the Mac.
"$T" --out "$OUT/trace-B4.json" --seconds 9 > /dev/null & TR=$!
sleep 0.5
"$A" --log "$OUT/app-B4.log" --deadline 11 --session iPhone --hang-keeper-after 2 --keeper "$K" --keeper-log "$OUT/keeper-B4.log" \
     --keeper-args "--test-mode --no-lock --deadline 11" & APP=$!
sleep 2.5; echo "$(ms) kill -9 app" >> "$OUT/script-B4.log"; kill -9 $APP
wait $TR; cleanup
echo done
