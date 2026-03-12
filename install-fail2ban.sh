#!/bin/sh
set -u

log() {
  echo "[INFO] $*"
}

ok() {
  echo "[SUCCESS] $*"
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

run() {
  "$@" || fail "Command failed: $*"
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    fail "Please run this script as root"
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  else
    fail "Unsupported system: no apt-get / dnf / yum found"
  fi
  log "Package manager: $PM"
}

install_fail2ban() {
  log "Installing fail2ban..."

  if [ "$PM" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update; then
      echo
      echo "[HINT] apt-get update failed."
      echo "[HINT] Common reasons:"
      echo "  - expired/invalid APT repository"
      echo "  - old backports source such as buster-backports"
      echo "  - duplicated or broken source entries"
      echo
      echo "[HINT] Check these files:"
      echo "  - /etc/apt/sources.list"
      echo "  - /etc/apt/sources.list.d/*.list"
      echo
      fail "Cannot continue until apt sources are fixed"
    fi

    run apt-get install -y fail2ban
  elif [ "$PM" = "dnf" ]; then
    dnf install -y epel-release >/dev/null 2>&1 || true
    run dnf install -y fail2ban fail2ban-firewalld
  elif [ "$PM" = "yum" ]; then
    yum install -y epel-release >/dev/null 2>&1 || true
    run yum install -y fail2ban
  fi

  command -v fail2ban-client >/dev/null 2>&1 || fail "fail2ban-client not found after installation"
  ok "fail2ban installed"
}

find_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  elif [ -x /usr/sbin/sshd ]; then
    SSHD_BIN="/usr/sbin/sshd"
  elif [ -x /sbin/sshd ]; then
    SSHD_BIN="/sbin/sshd"
  else
    fail "sshd binary not found"
  fi
  log "sshd binary: $SSHD_BIN"
}

write_sshd_hardening() {
  log "Writing SSH hardening config..."
  mkdir -p /etc/ssh/sshd_config.d

  cat >/etc/ssh/sshd_config.d/99-openclaw-min-hardening.conf <<'EOF'
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 10:30:60
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

  "$SSHD_BIN" -t || fail "sshd config test failed"

  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    run systemctl reload ssh
  elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    run systemctl reload sshd
  else
    log "SSH service unit not found, skipping reload"
  fi

  ok "SSH hardening config applied"
}

write_fail2ban_jail() {
  log "Writing fail2ban SSH jail..."
  mkdir -p /etc/fail2ban/jail.d

  cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime = 315360000
EOF

  ok "fail2ban jail config written"
}

enable_fail2ban() {
  log "Enabling fail2ban..."
  run systemctl enable --now fail2ban
  sleep 2
  systemctl is-active fail2ban >/dev/null 2>&1 || fail "fail2ban service is not active"
  ok "fail2ban service is active"
}

verify() {
  log "Verifying final status..."

  systemctl is-active fail2ban >/dev/null 2>&1 || fail "fail2ban is not running"
  fail2ban-client status sshd >/dev/null 2>&1 || fail "sshd jail is not available"

  EFFECTIVE_BANTIME="$(fail2ban-client get sshd bantime 2>/dev/null || true)"

  echo
  echo "===== Verification ====="
  echo "sshd binary: $SSHD_BIN"
  echo
  echo "--- sshd effective ---"
  "$SSHD_BIN" -T | egrep 'permitrootlogin|passwordauthentication|maxauthtries|maxstartups|logingracetime|pubkeyauthentication' || true
  echo
  echo "--- fail2ban jail file ---"
  cat /etc/fail2ban/jail.d/sshd.local
  echo
  echo "--- fail2ban status ---"
  fail2ban-client status sshd || true
  echo
  echo "--- effective bantime ---"
  echo "$EFFECTIVE_BANTIME"
  echo "========================"
  echo

  [ "$EFFECTIVE_BANTIME" = "315360000" ] || fail "Unexpected bantime: $EFFECTIVE_BANTIME"

  ok "fail2ban installed and configured successfully"
  ok "Rule: 10 minutes / 5 failures / 10-year ban"
}

main() {
  need_root
  detect_pm
  install_fail2ban
  find_sshd
  write_sshd_hardening
  write_fail2ban_jail
  enable_fail2ban
  verify
}

main "$@"
