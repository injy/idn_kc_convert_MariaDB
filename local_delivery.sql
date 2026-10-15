-- Pick mailboxes at domains that have NO catch-all (@domain) row,
-- so they must be delivered LOCALLY (LMTP) rather than forwarded.
SELECT m.username AS ace_username,
       kc_to_utf8(m.username) AS utf8_username,
       (SELECT COUNT(*) FROM alias a
          WHERE a.active=1
            AND (kc_to_ascii(a.address) = CONCAT('@', kc_to_ascii(m.domain))
                 OR a.address = CONCAT('@', m.domain))) AS catchall_rows
FROM mailbox m
WHERE m.active=1
  AND m.username IN ('nic@diy.gd', 'xn--viq251j@xn--hxy.xn--fiqs8s', 'xn--mxa@xn--mxa.cc')
ORDER BY m.username;
