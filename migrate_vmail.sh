#!/bin/bash
# /www/vmail -> /data/vmail 迁移（数据 + 配置切换），失败自动回滚
SRC=/www/vmail
DST=/data/vmail
TS=$(date +%Y%m%d_%H%M%S)
BK=/root/backup/vmail-migration-$TS
log(){ echo "[$(date +%H:%M:%S)] $*"; }

log "=== [0] pre-checks ==="
[ -d "$SRC" ] || { echo "FATAL: $SRC missing"; exit 1; }
if [ -e "$DST" ]; then echo "FATAL: $DST already exists"; exit 1; fi
AVAIL=$(df -m --output=avail /data | tail -1); NEED=$(du -sm $SRC | cut -f1)
log "need ${NEED}M, avail ${AVAIL}M on /data"
[ "$AVAIL" -gt $((NEED*2)) ] || { echo "FATAL: not enough space"; exit 1; }

log "=== [1] backup configs -> $BK ==="
mkdir -p $BK
cp /etc/postfix/main.cf $BK/main.cf
cp -r /etc/dovecot $BK/dovecot
ls -la $BK | head -8

log "=== [2] pre-state ==="
du -sh $SRC
echo "files: $(find $SRC -type f | wc -l)"
echo "--- doveadm user nic@vche.net (old home) ---"
doveadm user nic@vche.net 2>&1 | head -6

log "=== [3] flush queue, then stop dovecot (postfix keeps accepting; LMTP defers) ==="
postqueue -f >/dev/null 2>&1
systemctl stop dovecot; sleep 1
echo "dovecot: $(systemctl is-active dovecot)"

log "=== [4] rsync $SRC/ -> $DST/ ==="
mkdir -p $DST; chown vmail:mail $DST; chmod 750 $DST
rsync -aHAX --numeric-ids $SRC/ $DST/
log "rsync exit: $?"

log "=== [5] verify copy ==="
du -sh $SRC $DST
echo "src files: $(find $SRC -type f | wc -l)  dst files: $(find $DST -type f | wc -l)"
if diff -rq $SRC $DST >/tmp/diffout 2>&1; then echo "RSYNC_IDENTICAL"; else echo "DIFFS (first 20):"; head -20 /tmp/diffout; fi
stat -c '%U:%G %a %n' $DST $DST/vche.net $DST/vche.net/nic

log "=== [6] switch configs to $DST ==="
postconf -e "virtual_mailbox_base = $DST"
sed -i "s#/www/vmail#$DST#g" /etc/dovecot/conf.d/auth-sql.conf.ext /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/dovecot-sql.conf.ext
echo "--- postfix ---"; postconf virtual_mailbox_base
echo "--- dovecot effective ---"; doveconf -n 2>/dev/null | grep -E "mail_path|CONCAT\('/data/vmail" | head -4

log "=== [7] postfix check + reload ==="
postfix check 2>&1 | grep -v smtpd_use_tls || true
postfix reload >/dev/null 2>&1 && echo "postfix reloaded"

log "=== [8] start dovecot ==="
systemctl start dovecot; sleep 2
if [ "$(systemctl is-active dovecot)" != "active" ]; then
  log "FATAL: dovecot failed to start -> rolling back configs"
  cp $BK/main.cf /etc/postfix/main.cf
  rm -rf /etc/dovecot; cp -r $BK/dovecot /etc/dovecot
  postfix reload >/dev/null 2>&1
  systemctl start dovecot
  exit 1
fi
echo "dovecot: $(systemctl is-active dovecot)"
echo "--- doveadm user nic@vche.net (NEW home) ---"
doveadm user nic@vche.net 2>&1 | head -8

log "=== [9] flush deferred queue ==="
postqueue -f >/dev/null 2>&1; sleep 3
mailq | tail -1

log "=== [10] live delivery test into NEW location ==="
B=$(ls $DST/vche.net/nic/new 2>/dev/null | wc -l)
BI=$(ls $DST/xn--hxy.xn--fiqs8s/xn--viq251j/new 2>/dev/null | wc -l)
printf "From: root@gc.vche.net\nTo: nic@vche.net\nSubject: vmail-migration local\n\nMigration check.\n" | sendmail -t
printf "From: root@gc.vche.net\nTo: 美丽@的.中国\nSubject: vmail-migration IDN\n\nIDN migration check.\n" | sendmail -t
sleep 3; postqueue -f >/dev/null 2>&1; sleep 3
A=$(ls $DST/vche.net/nic/new 2>/dev/null | wc -l)
AI=$(ls $DST/xn--hxy.xn--fiqs8s/xn--viq251j/new 2>/dev/null | wc -l)
log "nic@vche.net new/ delta: $((A-B)) ; 美丽@的.中国 new/ delta: $((AI-BI))"
echo "--- delivery trace ---"
grep "to=<nic@vche.net>" /var/log/postfix/postfix.log | tail -1
grep "to=<xn--viq251j@xn--hxy.xn--fiqs8s>" /var/log/postfix/postfix.log | tail -1

log "=== [11] old mail readable in NEW location ==="
doveadm mailbox status -u nic@vche.net all 2>&1 | head -3
echo "old dir still present (backup): $(du -sh $SRC | cut -f1)"
