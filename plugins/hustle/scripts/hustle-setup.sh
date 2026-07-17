#!/usr/bin/env bash
# Install the hustle loop into a project.
#
#   hustle-setup.sh [project-dir]     (default: current directory)
#
# Creates <project>/.hustle/ with the runtime scripts, a config file and
# (on Linux) the systemd user service. Idempotent: re-running refreshes the
# scripts but leaves an existing config untouched.
set -euo pipefail

PROJECT="$(cd "${1:-$PWD}" && pwd)"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HUSTLE_HOME="$PROJECT/.hustle"
SLUG="$(basename "$PROJECT" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')"
OS="$(uname -s)"

command -v python3 >/dev/null || { echo "error: python3 is required (macOS: xcode-select --install)"; exit 1; }
command -v claude  >/dev/null || { echo "error: claude CLI not found in PATH"; exit 1; }

mkdir -p "$HUSTLE_HOME/bin"
cp "$PLUGIN_DIR/scripts/hustle-scheduler.sh" "$PLUGIN_DIR/scripts/hustle-session.sh" \
   "$PLUGIN_DIR/scripts/hustle-monitor.py" "$HUSTLE_HOME/bin/"
chmod +x "$HUSTLE_HOME/bin/hustle-scheduler.sh" "$HUSTLE_HOME/bin/hustle-session.sh" "$HUSTLE_HOME/bin/hustle-monitor.py"

# Runtime state never belongs in the project's VCS.
echo "*" > "$HUSTLE_HOME/.gitignore"

if [ ! -f "$HUSTLE_HOME/config" ]; then
  cat > "$HUSTLE_HOME/config" <<EOF
# advance-goal loop configuration (sourced by bash, parsed by the monitor)
HUSTLE_PROJECT="$PROJECT"
HUSTLE_SLUG="$SLUG"
HUSTLE_MODEL="sonnet"
HUSTLE_EFFORT="high"
# The loop runs unattended: without this it cannot use tools headlessly.
# Understand what that means before flipping it — see the plugin README.
HUSTLE_SKIP_PERMISSIONS="true"
HUSTLE_PORT="8787"
HUSTLE_BIND="0.0.0.0"
EOF
  echo "wrote $HUSTLE_HOME/config"
else
  echo "kept existing $HUSTLE_HOME/config"
fi

if [ "$OS" != "Darwin" ]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/hustle-${SLUG}.service" <<EOF
[Unit]
Description=advance-goal run for ${SLUG}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$HUSTLE_HOME/bin/hustle-session.sh
TimeoutStartSec=7200
EOF
  systemctl --user daemon-reload
  echo "wrote systemd unit hustle-${SLUG}.service"
fi

# Smoke-test the scheduler round trip (arm in the future, read back, disarm).
if "$HUSTLE_HOME/bin/hustle-scheduler.sh" arm --in 3600 >/dev/null \
   && [ -n "$("$HUSTLE_HOME/bin/hustle-scheduler.sh" next)" ]; then
  "$HUSTLE_HOME/bin/hustle-scheduler.sh" disarm
  echo "scheduler smoke test: OK"
else
  "$HUSTLE_HOME/bin/hustle-scheduler.sh" disarm || true
  echo "scheduler smoke test: FAILED — check the output above" >&2
  exit 1
fi

cat <<EOF

hustle installed for: $PROJECT  (slug: $SLUG)

Next steps:
  1. Build your GOAL.md:            /grill-goal   (in a Claude Code session in this project)
  2. Kick off the chain:
EOF
if [ "$OS" = "Darwin" ]; then
  echo "       $HUSTLE_HOME/bin/hustle-session.sh &"
else
  cat <<EOF
       systemctl --user start hustle-${SLUG}.service
     (survive logout/reboot: loginctl enable-linger \$USER)
EOF
fi
cat <<EOF
  3. Watch:                          http://<this-host>:8787
  Kill switch:                       $HUSTLE_HOME/bin/hustle-scheduler.sh disarm
EOF
