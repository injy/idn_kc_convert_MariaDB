#!/usr/bin/env bash
set -e
echo "=== 1. backup existing quota configs ==="
mkdir -p /root/backup/quota-$(date +%Y%m%d)
[ -f /etc/dovecot/90-quota.conf ] && cp -a /etc/dovecot/90-quota.conf /root/backup/quota-$(date +%Y%m%d)/90-quota.conf.orphan.$(date +%s)
[ -f /etc/dovecot/conf.d/90-quota.conf ] && cp -a /etc/dovecot/conf.d/90-quota.conf /root/backup/quota-$(date +%Y%m%d)/90-quota.conf.orig.$(date +%s)
[ -f /etc/dovecot/conf.d/90-quota.conf.old ] && cp -a /etc/dovecot/conf.d/90-quota.conf.old /root/backup/quota-$(date +%Y%m%d)/90-quota.conf.old.$(date +%s)
echo "backed up"

echo "=== 2. disable the orphan (not loaded anyway, just for clarity) ==="
[ -f /etc/dovecot/90-quota.conf ] && mv /etc/dovecot/90-quota.conf /etc/dovecot/90-quota.conf.orphan-$(date +%s) && echo "orphan moved"
echo "=== 3. remove the empty .old so it never confuses ==="
rm -f /etc/dovecot/conf.d/90-quota.conf.old

echo "=== 4. deploy new conf.d/90-quota.conf ==="
# (file pushed separately to /tmp/90-quota.conf)
cp /tmp/90-quota.conf /etc/dovecot/conf.d/90-quota.conf
chmod 644 /etc/dovecot/conf.d/90-quota.conf
echo "deployed"

echo "=== 5. dovecot config syntax check ==="
doveconf -n >/dev/null 2>&1 && echo "config OK" || { echo "CONFIG ERROR"; doveconf 2>&1 | head; }

echo "=== 6. confirm backend now loaded ==="
doveconf 2>/dev/null | grep -i "quota ="

echo "=== 7. reload dovecot (graceful) ==="
dovecot reload 2>&1 || systemctl reload dovecot 2>&1
sleep 2
echo "dovecot active: $(systemctl is-active dovecot)"
