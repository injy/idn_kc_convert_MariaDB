SELECT "=== punycode mailbox rows: UDF behaviour ===" AS s;
SELECT
  username AS stored,
  kc_to_ascii(username) AS a,
  kc_to_utf8(username) AS u,
  kc_to_ascii(kc_to_utf8(username)) AS rt,
  (kc_to_ascii(username) = username) AS a_eq_stored,
  (kc_to_ascii(kc_to_utf8(username)) = username) AS rt_eq_stored
FROM mailbox WHERE username LIKE '%xn--%' LIMIT 20;

SELECT "=== punycode domain rows ===" AS s;
SELECT
  domain AS stored,
  kc_to_ascii(domain) AS a,
  kc_to_utf8(domain) AS u,
  kc_to_ascii(kc_to_utf8(domain)) AS rt,
  (kc_to_ascii(domain) = domain) AS a_eq,
  (kc_to_ascii(kc_to_utf8(domain)) = domain) AS rt_eq
FROM domain WHERE domain LIKE '%xn--%' LIMIT 20;
