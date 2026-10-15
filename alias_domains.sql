SELECT alias_domain, target_domain, kc_to_ascii(alias_domain) AS ace,
       (SELECT COUNT(*) FROM domain d WHERE kc_to_ascii(d.domain)=kc_to_ascii(t.alias_domain)) AS also_in_domain_tbl
FROM alias_domain t
ORDER BY alias_domain;
