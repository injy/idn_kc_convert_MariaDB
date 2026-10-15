-- How many alias_domain rows are "identity" (the domain maps to its own ACE form)?
SELECT COUNT(*) AS total_rows,
       SUM(kc_to_ascii(target_domain) = kc_to_ascii(alias_domain)) AS identity_rows,
       SUM(kc_to_ascii(target_domain) <> kc_to_ascii(alias_domain)) AS genuine_alias_rows
FROM alias_domain;

-- Any genuinely-different alias domains we must still honour?
SELECT alias_domain, target_domain,
       kc_to_ascii(alias_domain) AS ace_alias,
       kc_to_ascii(target_domain) AS ace_target
FROM alias_domain
WHERE kc_to_ascii(target_domain) <> kc_to_ascii(alias_domain);
