SELECT "=== mailbox roundtrip (username) ===" AS s;
SELECT COUNT(*) AS total,
  SUM(kc_to_ascii(username) <> username) AS ascii_not_idempotent,
  SUM(kc_to_ascii(kc_to_utf8(username)) <> username) AS rt_fail
  FROM mailbox;
SELECT "=== domain roundtrip ===" AS s;
SELECT COUNT(*) AS total,
  SUM(kc_to_ascii(domain) <> domain) AS ascii_not_idempotent,
  SUM(kc_to_ascii(kc_to_utf8(domain)) <> domain) AS rt_fail
  FROM domain;
SELECT "=== alias roundtrip (address/goto) ===" AS s;
SELECT COUNT(*) AS total,
  SUM(kc_to_ascii(address) <> address) AS addr_ascii_fail,
  SUM(kc_to_ascii(kc_to_utf8(address)) <> address) AS addr_rt_fail,
  SUM(kc_to_ascii(goto) <> goto) AS goto_ascii_fail,
  SUM(kc_to_ascii(kc_to_utf8(goto)) <> goto) AS goto_rt_fail
  FROM alias;
SELECT "=== alias_domain roundtrip ===" AS s;
SELECT COUNT(*) AS total,
  SUM(kc_to_ascii(alias_domain) <> alias_domain) AS ad_ascii_fail,
  SUM(kc_to_ascii(kc_to_utf8(alias_domain)) <> alias_domain) AS ad_rt_fail,
  SUM(kc_to_ascii(target_domain) <> target_domain) AS td_ascii_fail,
  SUM(kc_to_ascii(kc_to_utf8(target_domain)) <> target_domain) AS td_rt_fail
  FROM alias_domain;
