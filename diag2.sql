SELECT "=== alias_domain: stored vs converted ===" AS s;
SELECT
  alias_domain AS stored,
  kc_to_ascii(alias_domain) AS a,
  kc_to_utf8(alias_domain) AS u,
  target_domain,
  (alias_domain LIKE '@%') AS is_at_prefix
FROM alias_domain ORDER BY alias_domain LIMIT 30;

SELECT "=== alias.address failing rows ===" AS s;
SELECT
  address,
  kc_to_ascii(address) AS a,
  (address LIKE '@%') AS is_catchall,
  goto
FROM alias
WHERE kc_to_ascii(address) <> address
ORDER BY address LIMIT 20;

SELECT "=== alias: how many are @-catchall vs other ===" AS s;
SELECT
  SUM(address LIKE '@%') AS catchall_count,
  SUM(address NOT LIKE '@%') AS specific_count,
  COUNT(*) AS total
FROM alias;

SELECT "=== alias_domain: are stored values pure-ascii/punycode/utf8? ===" AS s;
SELECT
  SUM(alias_domain REGEXP '^[ -~]+$') AS ascii_or_punycode,
  SUM(alias_domain REGEXP '[^\x00-\x7F]') AS contains_nonascii
FROM alias_domain;
