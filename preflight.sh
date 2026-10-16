#!/bin/bash
# 需要环境变量 MAIL_DB_PASSWORD（邮局 MySQL 密码），如：export MAIL_DB_PASSWORD=...
# 迁移前预检：遗留引用、DB 中的路径、sieve、lmtp 监听
echo "=== /www/vmail top level (前50行) ==="
ls -la /www/vmail/ | head -50
echo; echo "=== sqlite/db files in vmail ==="
ls -la /www/vmail/*.db 2>&1
echo; echo "=== who references dovecot-sql.conf.ext ==="
grep -rn "dovecot-sql" /etc/dovecot/ 2>/dev/null
echo; echo "=== dovecot.conf includes ==="
grep -n "!include" /etc/dovecot/dovecot.conf
echo; echo "=== mailbox.maildir column sample (是否含绝对路径) ==="
mysql -u mailserver -p"$MAIL_DB_PASSWORD" mailserver -N -e "SELECT username, maildir FROM mailbox LIMIT 5;" 2>/dev/null
echo; echo "=== catch-all rows stored form ==="
mysql -u mailserver -p"$MAIL_DB_PASSWORD" mailserver -N -e "SELECT address FROM alias WHERE address LIKE '@%';" 2>/dev/null
echo; echo "=== sieve dirs? ==="
find /www/vmail -maxdepth 3 -name sieve -type d 2>/dev/null | head -5
echo; echo "=== lmtp listener ==="
grep -n -B2 -A6 "service lmtp" /etc/dovecot/conf.d/10-master.conf
echo; echo "=== panel plugin vmail refs ==="
grep -rln "vmail" /www/server/panel/plugin/mailserver 2>/dev/null | head -10
