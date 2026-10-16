# Revert the userdb quota concat to the panel's original form. The 2.4 quota
# backend (`quota maildir { }` in 90-quota.conf) already makes `doveadm quota
# get` show real usage. We intentionally do NOT enforce a per-user hard limit
# from userdb: the nested 2.4 field naming is fragile, and enabling it would
# reject mail for the one already-over-limit mailbox (et.et/et: 54.5MB vs 50MB).
import re
p = '/etc/dovecot/conf.d/auth-sql.conf.ext'
with open(p) as f:
    s = f.read()
s2 = re.sub(r"CONCAT\([^)]*storage=[^,]*,\s*quota\)\s+AS\s+\w+",
            "CONCAT('maildir:storage=', quota) AS quota_rule", s)
with open(p, 'w') as f:
    f.write(s2)
print('changed' if s2 != s else 'unchanged')
for l in s2.splitlines():
    if 'storage=' in l:
        print('QUERY:', l.strip())
