#!/usr/bin/env bash
# Install the advance-goal loop into a project.
#
#   ag-setup.sh [project-dir]     (default: current directory)
#
# Creates <project>/.advance-goal/ with the runtime scripts, a config file and
# (on Linux) the systemd user service. Idempotent: re-running refreshes the
# scripts but leaves an existing config untouched.
set -euo pipefail

PROJECT="$(cd "${1:-$PWD}" && pwd)"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AG_HOME="$PROJECT/.advance-goal"
SLUG="$(basename "$PROJECT" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')"
OS="$(uname -s)"

command -v python3 >/dev/null || { echo "error: python3 is required (macOS: xcode-select --install)"; exit 1; }
command -v claude  >/dev/null || { echo "error: claude CLI not found in PATH"; exit 1; }

mkdir -p "$AG_HOME/bin"
cp "$PLUGIN_DIR/scripts/ag-scheduler.sh" "$PLUGIN_DIR/scripts/ag-session.sh" \
   "$PLUGIN_DIR/scripts/ag-monitor.py" "$AG_HOME/bin/"
chmod +x "$AG_HOME/bin/ag-scheduler.sh" "$AG_HOME/bin/ag-session.sh" "$AG_HOME/bin/ag-monitor.py"

# Runtime state never belongs in the project's VCS.
echo "*" > "$AG_HOME/.gitignore"

if [ ! -f "$AG_HOME/config" ]; then
  cat > "$AG_HOME/config" <<EOF
# advance-goal loop configuration (sourced by bash, parsed by the monitor)
AG_PROJECT="$PROJECT"
AG_SLUG="$SLUG"
AG_MODEL="sonnet"
AG_EFFORT="high"
# The loop runs unattended: without this it cannot use tools headlessly.
# Understand what that means before flipping it — see the plugin README.
AG_SKIP_PERMISSIONS="true"
AG_PORT="8787"
AG_BIND="0.0.0.0"
EOF
  echo "wrote $AG_HOME/config"
else
  echo "kept existing $AG_HOME/config"
fi

if [ "$OS" != "Darwin" ]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/ag-${SLUG}.service" <<EOF
[Unit]
Description=advance-goal run for ${SLUG}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$AG_HOME/bin/ag-session.sh
TimeoutStartSec=7200
EOF
  systemctl --user daemon-reload
  echo "wrote systemd unit ag-${SLUG}.service"
fi

# Smoke-test the scheduler round trip (arm in the future, read back, disarm).
if "$AG_HOME/bin/ag-scheduler.sh" arm --in 3600 >/dev/null \
   && [ -n "$("$AG_HOME/bin/ag-scheduler.sh" next)" ]; then
  "$AG_HOME/bin/ag-scheduler.sh" disarm
  echo "scheduler smoke test: OK"
else
  "$AG_HOME/bin/ag-scheduler.sh" disarm || true
  echo "scheduler smoke test: FAILED — check the output above" >&2
  exit 1
fi

cat <<EOF

advance-goal installed for: $PROJECT  (slug: $SLUG)

Next steps:
  1. Build your GOAL.md:            /grill-goal   (in a Claude Code session in this project)
  2. Kick off the chain:
EOF
if [ "$OS" = "Darwin" ]; then
  echo "       $AG_HOME/bin/ag-session.sh &"
else
  cat <<EOF
       systemctl --user start ag-${SLUG}.service
     (survive logout/reboot: loginctl enable-linger \$USER)
EOF
fi
cat <<EOF
  3. Watch:                          http://<this-host>:8787
  Kill switch:                       $AG_HOME/bin/ag-scheduler.sh disarm
EOF
