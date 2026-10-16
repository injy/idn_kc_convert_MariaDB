#!/bin/bash
# 需要环境变量 MAIL_DB_PASSWORD（邮局 MySQL 密码），如：export MAIL_DB_PASSWORD=...
# 迁移前盘点：/data 数据盘、/www/vmail 数据量、所有引用点、nic@vche.net 状态
echo "=== [1] date/host ==="; date; hostname
echo; echo "=== [2] disk space ==="; df -h /data /www / 2>&1
echo; echo "=== [3] is /data a separate mount? ==="; mount | grep -E 'on /data |on /www ' ; echo "--- lsblk ---"; lsblk 2>/dev/null | head -20
echo; echo "=== [4] /data tree ==="; ls -la /data/ 2>&1; echo "--- /data/vmail ---"; ls -la /data/vmail/ 2>&1 | head -15
echo; echo "=== [5] /www/vmail stats ==="; du -sh /www/vmail 2>/dev/null; echo "domain dirs: $(ls /www/vmail 2>/dev/null | wc -l)"
echo; echo "=== [6] ownership samples ==="; stat -c '%U:%G %a %n' /www/vmail 2>&1; stat -c '%U:%G %a %n' /www/vmail/diy.gd /www/vmail/diy.gd/nic 2>&1
echo; echo "=== [7] postfix vmail refs ==="; grep -n "vmail" /etc/postfix/main.cf 2>/dev/null
echo; echo "=== [8] dovecot ==="; dovecot --version 2>&1; ls /etc/dovecot/ 2>&1
echo; echo "=== [9] dovecot vmail refs ==="; grep -rn "vmail" /etc/dovecot/ 2>/dev/null | head -30
echo; echo "=== [10] mailbox table schema ==="; mysql -u mailserver -p"$MAIL_DB_PASSWORD" mailserver -e "SHOW CREATE TABLE mailbox\G" 2>/dev/null
echo; echo "=== [11] nic@vche.net: mailbox row + alias row ==="; mysql -u mailserver -p"$MAIL_DB_PASSWORD" mailserver -e "SELECT username, domain, active FROM mailbox WHERE kc_to_ascii(domain)='vche.net' AND kc_to_ascii(local_part)='nic'; SELECT address, active FROM alias WHERE address='nic@vche.net';" 2>/dev/null
echo; echo "=== [12] doveadm user nic@vche.net (current home) ==="; doveadm user nic@vche.net 2>&1 | head -12
echo; echo "=== [13] services ==="; systemctl is-active postfix dovecot 2>&1
echo; echo "=== [14] all /www/vmail refs outside the data dir ==="; grep -rln "/www/vmail" /etc /root /www/server /usr/local 2>/dev/null | grep -v "^/www/vmail" | head -20
echo; echo "=== [15] cron refs ==="; grep -rln "/www/vmail" /var/spool/cron 2>/dev/null | head -5
