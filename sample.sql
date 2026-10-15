SELECT "=== mailbox sample ===" AS s;
SELECT username, local_part, domain, active FROM mailbox LIMIT 12;
SELECT "=== how many are pure-ASCII vs contain non-ascii ===" AS s;
SELECT
  SUM(username REGEXP '[[:nonascii:]]') AS nonascii_user,
  SUM(username LIKE 'xn--%' OR username LIKE '%@xn--%') AS has_punycode,
  SUM(username REGEXP '^[[:ascii:]]+$') AS pure_ascii
  FROM mailbox;
SELECT "=== domain sample ===" AS s;
SELECT domain FROM domain LIMIT 12;
SELECT "=== alias sample ===" AS s;
SELECT address, goto FROM alias LIMIT 12;
SELECT "=== alias_domain sample ===" AS s;
SELECT alias_domain, target_domain FROM alias_domain LIMIT 12;
