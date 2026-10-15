-- Full-table sweep after the leading-'@' UDF fix.
-- Everything is stored as ACE, so kc_to_ascii() must be a no-op on it,
-- and it must be idempotent. Any row failing these is corrupted.

SELECT "mailbox: kc_to_ascii must be a no-op" AS what,
       COUNT(*) AS failures
FROM mailbox
WHERE kc_to_ascii(username) <> username
   OR kc_to_ascii(local_part) <> local_part
   OR kc_to_ascii(domain) <> domain;

SELECT "mailbox: idempotent" AS what, COUNT(*) AS failures
FROM mailbox
WHERE kc_to_ascii(kc_to_ascii(username)) <> kc_to_ascii(username);

SELECT "domain: kc_to_ascii must be a no-op" AS what, COUNT(*) AS failures
FROM domain
WHERE kc_to_ascii(domain) <> domain;

SELECT "alias: kc_to_ascii must be a no-op" AS what, COUNT(*) AS failures
FROM alias
WHERE kc_to_ascii(address) <> address;

SELECT "alias: catch-all rows keep their leading @" AS what,
       SUM(address LIKE '@%' AND kc_to_ascii(address) NOT LIKE '@%') AS failures,
       COUNT(*) AS catchall_rows
FROM alias
WHERE address LIKE '@%';

SELECT "alias_domain: ACE of UTF-8 == stored target" AS what,
       COUNT(*) AS failures
FROM alias_domain
WHERE kc_to_ascii(alias_domain) <> kc_to_ascii(target_domain);

SELECT "round-trip kc_to_ascii then kc_to_utf8 (IDN rows only)" AS what,
       COUNT(*) AS failures
FROM domain
WHERE domain LIKE 'xn--%'
  AND kc_to_ascii(domain) <> domain;

-- sanity: total row counts inspected
SELECT "mailbox rows" AS what, COUNT(*) AS n FROM mailbox
UNION ALL SELECT "domain rows", COUNT(*) FROM domain
UNION ALL SELECT "alias rows", COUNT(*) FROM alias
UNION ALL SELECT "alias_domain rows", COUNT(*) FROM alias_domain;
