#!/bin/sh
set -eu

echo "[1/6] Detecting package manager..."
if command -v apt-get >/dev/null 2>&1; then
PM="apt"
elif command -v dnf >/dev/null 2>&1; then
PM="dnf"
elif command -v yum >/dev/null 2>&1; then
PM="yum"
else
echo "Unsupported system: no apt/dnf/yum found"
exit 1
fi

echo "[2/6] Installing fail2ban..."
if [ "$PM" = "apt" ]; then
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y fail2ban
elif [ "$PM" = "dnf" ]; then
dnf install -y epel-release || true
dnf install -y fail2ban fail2ban-firewalld
elif [ "$PM" = "yum" ]; then
yum install -y epel-release || true
yum install -y fail2ban
fi

echo "[3/6] Writing SSH hardening config..."
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-openclaw-min-hardening.conf <<'EOF'
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 10:30:60
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

if command -v sshd >/dev/null 2>&1; then
SSHD_BIN="$(command -v sshd)"
elif [ -x /usr/sbin/sshd ]; then
SSHD_BIN="/usr/sbin/sshd"
else
echo "sshd not found"
exit 1
fi

"$SSHD_BIN" -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "[4/6] Writing fail2ban jail..."
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

echo "[5/6] Enabling fail2ban..."
systemctl enable --now fail2ban
sleep 2

echo "[6/6] Verifying..."
echo "=== sshd effective ==="
"$SSHD_BIN" -T | egrep 'permitrootlogin|passwordauthentication|maxauthtries|maxstartups|logingracetime|pubkeyauthentication' || true
echo
echo "=== fail2ban jail ==="
cat /etc/fail2ban/jail.d/sshd.local
echo
echo "=== fail2ban status ==="
fail2ban-client status sshd || fail2ban-client status
echo
echo "=== effective bantime ==="
fail2ban-client get sshd bantime || true

echo
echo "Done."
