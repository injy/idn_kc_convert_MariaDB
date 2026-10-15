-- IDN-hosted mailboxes (stored as ACE) plus their UTF-8 form,
-- used to pick a live end-to-end IDN delivery target.
SELECT username, domain, local_part, active,
       kc_to_utf8(domain) AS domain_utf8
FROM mailbox
WHERE domain LIKE 'xn--%'
ORDER BY username
LIMIT 25;
