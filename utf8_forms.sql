SELECT username AS ace_username, kc_to_utf8(username) AS utf8_username
FROM mailbox
WHERE username IN ('xn--zfr188b@xn--fiqs8s.xn--nqv7f',
                   'xn--mxa@xn--mxa.cc',
                   'xn--9p9h@xn--r28h.uz',
                   'xn--bya@xn--bya.cc');
