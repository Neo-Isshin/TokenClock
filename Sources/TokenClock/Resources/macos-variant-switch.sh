#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 7 ] || exit 2
task_home="$1"
task_source="$2"
task_target="$3"
task_source_pid="$4"
task_source_binary="$5"
task_autostart="$6"
task_stage="$7"
case "$task_source:$task_target" in glass:normal|normal:glass) ;; *) exit 2 ;; esac
case "$task_source_pid" in ''|*[!0-9]*) exit 2 ;; esac
task_binary="$task_home/.tokenclock/$task_target/TokenClock"
task_domain="gui/$(id -u)"
task_agents="$task_home/Library/LaunchAgents"
task_source_plist="$task_agents/com.tokenclock.app.$task_source.plist"
task_target_plist="$task_agents/com.tokenclock.app.$task_target.plist"
[ -x "$task_binary" ] && [ -s "$task_stage/target.plist" ] || exit 2

owned_plist() {
  [ -f "$1" ] &&
  [ "$(/usr/bin/plutil -extract Label raw -o - "$1" 2>/dev/null)" = "$2" ] &&
  [ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null)" = "$3" ]
}
task_source_owned=0
task_target_owned=0
if owned_plist "$task_source_plist" "com.tokenclock.app.$task_source" "$task_source_binary"; then
  cp "$task_source_plist" "$task_stage/source-backup.plist"
  task_source_owned=1
fi
if owned_plist "$task_target_plist" "com.tokenclock.app.$task_target" "$task_binary"; then
  cp "$task_target_plist" "$task_stage/target-backup.plist"
  task_target_owned=1
elif [ -e "$task_target_plist" ]; then
  /usr/bin/defaults write TokenClock TC_macVariantSwitchFailure -string "$task_target"
  exit 2
fi

rollback() {
  trap - ERR
  /bin/launchctl bootout "$task_domain/com.tokenclock.app.$task_target" 2>/dev/null || true
  if [ "$task_target_owned" = 1 ]; then
    cp "$task_stage/target-backup.plist" "$task_target_plist"
  elif [ "$task_autostart" = 1 ]; then
    rm -f "$task_target_plist"
  fi
  /usr/bin/defaults write TokenClock TC_preferredMacVariant -string "$task_source"
  /usr/bin/defaults write TokenClock TC_macVariantSwitchFailure -string "$task_target"
  task_restored=0
  if [ "$task_source_owned" = 1 ]; then
    cp "$task_stage/source-backup.plist" "$task_source_plist"
    if [ "$(/usr/bin/plutil -extract RunAtLoad raw -o - "$task_source_plist")" = true ]; then
      if /bin/launchctl bootstrap "$task_domain" "$task_source_plist" 2>/dev/null; then task_restored=1; fi
    fi
  fi
  if [ "$task_restored" = 0 ] && ! kill -0 "$task_source_pid" 2>/dev/null; then
    /usr/bin/nohup "$task_source_binary" >/dev/null 2>&1 &
  fi
}

# The parent quits cleanly, allowing scans and its API listener to shut down.
for ((task_attempt=0; task_attempt<40; task_attempt++)); do
  kill -0 "$task_source_pid" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$task_source_pid" 2>/dev/null; then
  /usr/bin/defaults write TokenClock TC_macVariantSwitchFailure -string "$task_target"
  exit 1
fi

trap rollback ERR
if [ "$task_source_owned" = 1 ]; then
  /bin/launchctl bootout "$task_domain/com.tokenclock.app.$task_source" 2>/dev/null || true
  /usr/bin/plutil -replace RunAtLoad -bool false "$task_source_plist"
fi
if [ "$task_target_owned" = 1 ]; then
  /bin/launchctl bootout "$task_domain/com.tokenclock.app.$task_target" 2>/dev/null || true
  /usr/bin/plutil -replace RunAtLoad -bool false "$task_target_plist"
fi
# Stop only another installed target edition, never a project/development binary.
while read -r task_pid task_command; do
  if [ "$task_command" = "$task_binary" ]; then
    kill -TERM "$task_pid" 2>/dev/null || true
    for ((task_attempt=0; task_attempt<40; task_attempt++)); do
      kill -0 "$task_pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$task_pid" 2>/dev/null; then false; fi
  fi
done < <(/bin/ps -U "$(id -u)" -o pid=,comm=)

if [ "$task_autostart" = 1 ]; then
  mkdir -p "$task_agents"
  cp "$task_stage/target.plist" "$task_target_plist"
  /bin/launchctl enable "$task_domain/com.tokenclock.app.$task_target"
  /bin/launchctl bootstrap "$task_domain" "$task_target_plist"
  sleep 2
  task_new_pid=$(/bin/launchctl print "$task_domain/com.tokenclock.app.$task_target" | /usr/bin/awk '/^[[:space:]]*pid =/ {print $3; exit}')
  [ -n "$task_new_pid" ]
  kill -0 "$task_new_pid"
else
  /usr/bin/nohup "$task_binary" >/dev/null 2>&1 &
  task_new_pid=$!
  sleep 2
  kill -0 "$task_new_pid"
fi
/usr/bin/defaults write TokenClock TC_preferredMacVariant -string "$task_target"
trap - ERR
