/*
 * kc_idn - MariaDB / MySQL UDF
 * ----------------------------
 * Two functions for internationalised (IDN) mail addresses:
 *
 *   kc_to_ascii(input)  - convert an email address or a bare domain to its
 *                         ASCII (punycode / ACE) form, converting BOTH the
 *                         local part and the domain.
 *   kc_to_utf8(input)   - the reverse: ACE / punycode back to UTF-8.
 *
 *   mysql> SELECT kc_to_ascii('中文@中文.中国');
 *   +---------------------------------------+
 *   | xn--fiq228c@xn--fiq228c.xn--fiqs8s     |
 *   +---------------------------------------+
 *
 *   mysql> SELECT kc_to_utf8('xn--fiq228c@xn--fiq228c.xn--fiqs8s');
 *   +---------------------------------------+
 *   | 中文@中文.中国                          |
 *   +---------------------------------------+
 *
 * Purpose: let Postfix / Dovecot do native `mysql:` table lookups for IDN
 * mail addresses without a resident PHP daemon, e.g.
 *   WHERE username = kc_to_ascii('%u')        -- on the way IN (lookup)
 *   WHERE username = kc_to_utf8(username)     -- on the way OUT (display)
 *
 * This is a faithful C port of the PHP function idn_kc_convert($input, $is_utf)
 * (the production postfix helper).  Semantics replicated exactly for BOTH
 * directions:
 *
 *   1. trim            - PHP trim() default charlist " \t\n\r\0\x0B"
 *   2. empty input     -> returns the string 'no_input'
 *   3. more than one '@' in the input -> returns 'too_many_at_2+'
 *   4. input longer than 200 bytes    -> returns 'input_too_long'
 *      (the three sentinel strings simply never match a mailbox row, i.e.
 *       the lookup fails - exactly what the PHP original does)
 *   5. sanitiser       - strips the dangerous-character class of the PHP
 *                         original (see kc_is_dangerous() below), then
 *                         collapses runs of '.' into a single '.' (two
 *                         preg_replace passes, in that order)
 *   6. split on the FIRST '@' -> local part + domain; a leading '@' means
 *      "domain only"; a trailing '@' with empty domain returns just the
 *      (converted) local part
 *   7. per-side conversion:
 *        kc_to_ascii -> idn_to_ascii(..., UTS46) on each side
 *        kc_to_utf8  -> idn_to_utf8 (..., UTS46) on each side
 *   8. if the domain is empty -> return the local part; if the per-side
 *      conversion fails -> PHP returns false, which becomes '' in string
 *      context
 *
 * INTENTIONAL DEVIATION FROM THE PHP ORIGINAL (one line, see README):
 * the PHP version runs
 *     mb_detect_encoding($s, ['UTF-8','GBK','ASCII'], true)
 *     + mb_convert_encoding(...)
 * to guess the input encoding.  That guess is removed here: Postfix and
 * Dovecot always hand over UTF-8 (SMTPUTF8) or ASCII, never GBK, and the
 * guess demonstrably corrupts 4-byte UTF-8 (e.g. emoji) and mangles GBK
 * bytes that collide with valid UTF-8.  The input is therefore assumed to
 * be UTF-8, which is what the mail path guarantees.
 *
 * Build (see Makefile):
 *   make standalone   -> kc_idn_test  (libidn2 only, for A/B testing)
 *   make udf          -> kc_idn.so    (needs libmariadb-dev)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <idn2.h>

#define KC_MAX_OUT 2048

/* ------------------------------------------------------------------ */
/* PHP-compatible primitives                                          */
/* ------------------------------------------------------------------ */

/* PHP trim() default charlist is " \t\n\r\0\x0B".  A NUL byte cannot occur
 * inside a C string, so it is omitted here. */
static int kc_is_trim(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v';
}

/* Character class of the PHP sanitiser
 *     preg_replace('/[<>"\';=&|\\?`{}()\[\]%*\/\s]/', '', $s)
 * Every member is ASCII and the pattern is compiled WITHOUT the /u
 * modifier, i.e. it operates byte-wise - so a byte scan is exactly
 * equivalent and can never split a multibyte UTF-8 sequence.
 * \s = [ \t\n\r\f\v]. */
static int kc_is_dangerous(unsigned char c)
{
    if (c >= 0x80)
        return 0;
    switch (c) {
    case ' ': case '\t': case '\n': case '\r': case '\f': case '\v':
        return 1;
    default:
        break;
    }
    return strchr("<>\"';=&|\\?`{}()[]%*/", (char)c) != NULL;
}

/* Two passes, in the same order as the two preg_replace() calls of the PHP
 * original: strip dangerous characters FIRST, then collapse dot runs.
 * (A single pass is NOT equivalent: 'a.<.>b' must become 'a.b', because
 * the character removal happens before the dot collapsing.) */
static void kc_sanitise(const char *in, char *out, size_t outlen)
{
    size_t j = 0;

    /* pass 1: drop dangerous characters */
    for (size_t i = 0; in[i] && j + 1 < outlen; i++) {
        unsigned char c = (unsigned char)in[i];
        if (!kc_is_dangerous(c))
            out[j++] = (char)c;
    }
    out[j] = '\0';

    /* pass 2: collapse runs of '.' into a single '.' */
    size_t w = 0;
    int prev_dot = 0;
    for (size_t r = 0; out[r] && w + 1 < outlen; r++) {
        if (out[r] == '.') {
            if (prev_dot)
                continue;
            prev_dot = 1;
        } else {
            prev_dot = 0;
        }
        out[w++] = out[r];
    }
    out[w] = '\0';
}

/* Strict UTF-8 validation.  PHP's idn_to_ascii() / idn_to_utf8() (ICU) rejects
 * invalid UTF-8 outright (returns false -> ''), while libidn2's decoder is
 * lenient and would silently skip bad bytes and "decode" the rest - e.g.
 * the GBK bytes (d6 d0 b9 fa) would become U+0409 and produce a bogus ACE
 * label.  Validating first keeps the UDF byte-identical to the PHP reference
 * for every input, valid or not. */
static int kc_valid_utf8(const char *s)
{
    static const unsigned int minv[4] = {0, 0x80, 0x800, 0x10000};
    const unsigned char *p = (const unsigned char *)s;

    while (*p) {
        unsigned char c = *p;
        size_t need;
        unsigned int cp;

        if (c < 0x80) { p++; continue; }
        else if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1Fu; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0Fu; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07u; }
        else return 0;                       /* stray continuation / 0xF8+ */

        p++;
        for (size_t k = 0; k < need; k++) {
            if ((*p & 0xC0) != 0x80)
                return 0;                    /* missing continuation byte */
            cp = (cp << 6) | (*p & 0x3Fu);
            p++;
        }
        if (cp < minv[need])           return 0;   /* overlong encoding  */
        if (cp >= 0xD800 && cp <= 0xDFFF) return 0; /* UTF-16 surrogate  */
        if (cp > 0x10FFFF)             return 0;   /* out of range       */
    }
    return 1;
}

/* Convert one side (local part or domain) to ACE (kc_to_ascii direction).
 * Mirrors idn_to_ascii($s, INTL_IDNA_VARIANT_UTS46): on success the ACE
 * string, on failure PHP returns false which becomes '' in string context -
 * so an empty string is written on failure.
 *
 * IDN2_TRANSITIONAL is required to match PHP/ICU UTS46 transitional
 * processing (e.g. 'faß.de' -> 'fass.de', not 'xn--fa-hia.de'). */
static void kc_puny_side(const char *s, char *out, size_t outlen)
{
    out[0] = '\0';
    if (!s || !*s)
        return;

    /* ICU fails on invalid UTF-8; libidn2 would not.  Match ICU. */
    if (!kc_valid_utf8(s))
        return;

    char *ace = NULL;
    int rc = idn2_to_ascii_8z(s, &ace, IDN2_TRANSITIONAL);
    if (rc == IDN2_OK && ace) {
        snprintf(out, outlen, "%s", ace);
        free(ace);
        return;
    }
    free(ace);
    /* PHP: idn_to_ascii() returned false -> '' in string concatenation */
}

/* Convert one side (local part or domain) from ACE back to UTF-8
 * (kc_to_utf8 direction).  Mirrors idn_to_utf8($s, INTL_IDNA_VARIANT_UTS46):
 * on success the Unicode string, on failure '' (false in string context).
 *
 * Why the toASCII -> toUnicode two-step: libidn2's idn2_to_unicode_8z8z only
 * DECODES ACE labels and leaves non-ACE input untouched (so 'faß.de' would
 * stay 'faß.de' and 'K.de' would stay 'K.de'), whereas ICU's idn_to_utf8
 * applies the full UTS46 mapping to EVERY label.  Running idn2_to_ascii_8z
 * first applies that mapping (ß->ss, Ⅰ->i, upper->lower), and the following
 * toUnicode then decodes any ACE - reproducing idn_to_utf8 exactly for both
 * ACE and non-ACE input, while keeping kc_to_utf8(kc_to_ascii(x)) == x.
 * The same TRANSITIONAL flag is used on both steps to stay consistent with
 * the encode direction. */
static void kc_utf8_side(const char *s, char *out, size_t outlen)
{
    out[0] = '\0';
    if (!s || !*s)
        return;

    /* ICU fails on invalid UTF-8; libidn2 would not.  Match ICU. */
    if (!kc_valid_utf8(s))
        return;

    char *ace = NULL;
    int rc = idn2_to_ascii_8z(s, &ace, IDN2_TRANSITIONAL);
    if (rc != IDN2_OK || !ace) {
        free(ace);
        return;                         /* conversion failure -> '' */
    }
    char *uni = NULL;
    rc = idn2_to_unicode_8z8z(ace, &uni, IDN2_TRANSITIONAL);
    free(ace);
    if (rc == IDN2_OK && uni) {
        snprintf(out, outlen, "%s", uni);
        free(uni);
        return;
    }
    free(uni);
    /* PHP: idn_to_utf8() returned false -> '' in string context */
}

/* ------------------------------------------------------------------ */
/* Shared preprocessing pipeline (identical for both directions)      */
/* ------------------------------------------------------------------ */

/* Steps 1-5 (trim -> empty -> too many @ -> too long -> sanitiser).
 *   returns 0 and leaves the sanitised, not-yet-@-split string in *tmp
 *   returns 1 and writes a sentinel string into sentinel_out (caller
 *               emits it verbatim)
 * tmp must be >= KC_MAX_OUT bytes; sentinel_out must be >= 32 bytes. */
static int kc_prepare(const char *in, char *tmp, size_t tmplen,
                      char *sentinel_out, size_t sentinel_len)
{
    if (!in)
        in = "";

    /* 1. trim (PHP default charlist) */
    while (kc_is_trim(*in))
        in++;
    size_t len = strlen(in);
    while (len > 0 && kc_is_trim(in[len - 1]))
        len--;

    /* 2. empty input */
    if (len == 0) {
        snprintf(sentinel_out, sentinel_len, "no_input");
        return 1;
    }

    if (tmplen < len + 1) {
        snprintf(sentinel_out, sentinel_len, "input_too_long");
        return 1;
    }
    memcpy(tmp, in, len);
    tmp[len] = '\0';

    /* 3. more than one '@' (checked on the trimmed, unsanitised string,
     *    exactly like substr_count() in the PHP original) */
    size_t ats = 0;
    for (const char *p = tmp; *p; p++)
        if (*p == '@')
            ats++;
    if (ats > 1) {
        snprintf(sentinel_out, sentinel_len, "too_many_at_2+");
        return 1;
    }

    /* 4. byte length limit (PHP strlen() counts bytes) */
    if (strlen(tmp) > 200) {
        snprintf(sentinel_out, sentinel_len, "input_too_long");
        return 1;
    }

    /* 5. sanitiser, in place (output never grows) */
    kc_sanitise(tmp, tmp, len + 1);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Core conversions                                                   */
/* ------------------------------------------------------------------ */

/* kc_to_ascii: UTF-8 / IDN -> punycode (ASCII).  (Core; the public UDF
 * entry point of the same name lives in the UDF branch below.) */
static int kc_ascii_core(const char *in, char *out, size_t outlen)
{
    out[0] = '\0';
    if (!in || outlen < 8)
        return -1;

    char tmp[KC_MAX_OUT];
    char sentinel[32];
    if (kc_prepare(in, tmp, sizeof(tmp), sentinel, sizeof(sentinel)) == 1) {
        snprintf(out, outlen, "%s", sentinel);
        return 0;
    }

    /* 6. split at the first '@' (strpos) */
    char *at = strchr(tmp, '@');
    char user_enc[KC_MAX_OUT];
    char domain_enc[KC_MAX_OUT];
    const char *domain_raw;
    int at_gt0 = 0;                    /* strpos() returned > 0 */
    int leading_at = (tmp[0] == '@') ? 1 : 0;   /* keep a leading '@' */

    user_enc[0] = '\0';
    domain_enc[0] = '\0';

    if (at && at != tmp) {
        /* user@domain : convert the local part BEFORE the empty-domain
         * check, like the PHP original */
        at_gt0 = 1;
        *at = '\0';
        kc_puny_side(tmp, user_enc, sizeof(user_enc));
        domain_raw = at + 1;
    } else if (at) {
        /* leading '@' : domain only, local part stays empty */
        domain_raw = at + 1;
    } else {
        /* bare domain */
        domain_raw = tmp;
    }

    /* 7/8. empty domain -> return the (already converted) local part */
    if (*domain_raw == '\0') {
        snprintf(out, outlen, "%s", user_enc);
        return 0;
    }

    kc_puny_side(domain_raw, domain_enc, sizeof(domain_enc));

    /* reassemble.  PHP: $at ? ($user ? $user.'@'.$domain : '@'.$domain)
     *                         : $domain   -- note strpos()===0 is falsy */
    if (at_gt0) {
        if (user_enc[0] != '\0')
            snprintf(out, outlen, "%s@%s", user_enc, domain_enc);
        else
            snprintf(out, outlen, "@%s", domain_enc);
    } else {
        snprintf(out, outlen, "%s%s", leading_at ? "@" : "", domain_enc);
    }
    return 0;
}

/* kc_to_utf8: punycode (ASCII / ACE) -> UTF-8 / IDN.  Same pipeline, the
 * per-side conversion is kc_utf8_side() instead of kc_puny_side().
 * (Core; the public UDF entry point of the same name lives in the UDF
 * branch below.) */
static int kc_utf8_core(const char *in, char *out, size_t outlen)
{
    out[0] = '\0';
    if (!in || outlen < 8)
        return -1;

    char tmp[KC_MAX_OUT];
    char sentinel[32];
    if (kc_prepare(in, tmp, sizeof(tmp), sentinel, sizeof(sentinel)) == 1) {
        snprintf(out, outlen, "%s", sentinel);
        return 0;
    }

    char *at = strchr(tmp, '@');
    char user_dec[KC_MAX_OUT];
    char domain_dec[KC_MAX_OUT];
    const char *domain_raw;
    int at_gt0 = 0;
    int leading_at = (tmp[0] == '@') ? 1 : 0;   /* keep a leading '@' */

    user_dec[0] = '\0';
    domain_dec[0] = '\0';

    if (at && at != tmp) {
        at_gt0 = 1;
        *at = '\0';
        kc_utf8_side(tmp, user_dec, sizeof(user_dec));
        domain_raw = at + 1;
    } else if (at) {
        domain_raw = at + 1;
    } else {
        domain_raw = tmp;
    }

    if (*domain_raw == '\0') {
        snprintf(out, outlen, "%s", user_dec);
        return 0;
    }

    kc_utf8_side(domain_raw, domain_dec, sizeof(domain_dec));

    if (at_gt0) {
        if (user_dec[0] != '\0')
            snprintf(out, outlen, "%s@%s", user_dec, domain_dec);
        else
            snprintf(out, outlen, "@%s", domain_dec);
    } else {
        snprintf(out, outlen, "%s%s", leading_at ? "@" : "", domain_dec);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Standalone test mode: not linked against MariaDB headers.          */
/*   gcc -DSTANDALONE_TEST kc_idn.c -lidn2 -o kc_idn_test             */
/*                                                                     */
/*   kc_idn_test [--utf8] <address-or-domain>     (default: --ascii)  */
/*   kc_idn_test [--utf8] --hex <hexlified-input>                       */
/*                                                                     */
/* The --hex mode lets the test harness pass arbitrary bytes (e.g.      */
/* invalid UTF-8 / GBK) without depending on shell argv transparency.   */
/* ------------------------------------------------------------------ */
#ifdef STANDALONE_TEST

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int hex_decode(const char *hex, char *out, size_t outlen)
{
    size_t n = strlen(hex);
    if (n % 2 != 0 || n / 2 + 1 > outlen)
        return -1;
    for (size_t i = 0; i < n; i += 2) {
        int hi = hexval(hex[i]);
        int lo = hexval(hex[i + 1]);
        if (hi < 0 || lo < 0)
            return -1;
        out[i / 2] = (char)((hi << 4) | lo);
    }
    out[n / 2] = '\0';
    return 0;
}

int main(int argc, char **argv)
{
    int mode = 0;                       /* 0 = ascii, 1 = utf8 */
    char inbuf[KC_MAX_OUT];
    const char *input = NULL;
    int i = 1;

    while (i < argc) {
        if (strcmp(argv[i], "--utf8") == 0) {
            mode = 1;
            i++;
        } else if (strcmp(argv[i], "--hex") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "missing hex argument\n");
                return 2;
            }
            if (hex_decode(argv[i + 1], inbuf, sizeof(inbuf)) != 0) {
                fprintf(stderr, "invalid hex input\n");
                return 2;
            }
            input = inbuf;
            i += 2;
        } else {
            break;
        }
    }
    if (input == NULL && i < argc)
        input = argv[i];

    if (input == NULL) {
        fprintf(stderr,
                "usage: %s [--utf8] <address-or-domain>\n"
                "       %s [--utf8] --hex <hexlified-input>\n",
                argv[0], argv[0]);
        return 2;
    }

    char out[KC_MAX_OUT];
    int rc = (mode == 1) ? kc_utf8_core(input, out, sizeof(out))
                         : kc_ascii_core(input, out, sizeof(out));
    if (rc != 0) {
        fprintf(stderr, "convert failed\n");
        return 1;
    }
    printf("%s\n", out);
    return 0;
}

/* ------------------------------------------------------------------ */
/* MariaDB / MySQL UDF interface. Compiled only when building the .so */
/* (libmariadb-dev must be installed).                                */
/* ------------------------------------------------------------------ */
#else
#include <mysql.h>

/* ---- kc_to_ascii ---- */
my_bool kc_to_ascii_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        strncpy(message, "kc_to_ascii() requires exactly 1 argument",
                MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->max_length = KC_MAX_OUT;
    initid->ptr = (char *)malloc(KC_MAX_OUT);
    if (!initid->ptr) {
        strncpy(message, "kc_to_ascii: out of memory", MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }
    return 0;
}

char *kc_to_ascii(UDF_INIT *initid, UDF_ARGS *args,
                  char *result __attribute__((unused)),
                  unsigned long *length, char *is_null, char *error)
{
    (void)result;
    (void)error;
    if (args->args[0] == NULL) {
        *is_null = 1;
        return NULL;
    }
    /* MariaDB passes string UDF args as length-prefixed, NOT NUL-terminated.
     * Copy into a properly terminated local buffer before any strlen/strchr
     * work, otherwise we scan past the argument into adjacent memory. */
    char inbuf[KC_MAX_OUT];
    size_t inlen = args->lengths[0];
    if (inlen >= KC_MAX_OUT)
        inlen = KC_MAX_OUT - 1;
    memcpy(inbuf, args->args[0], inlen);
    inbuf[inlen] = '\0';

    char *out = initid->ptr;
    if (kc_ascii_core(inbuf, out, KC_MAX_OUT) != 0) {
        *is_null = 1;
        return NULL;
    }
    *length = (unsigned long)strlen(out);
    return out;
}

void kc_to_ascii_deinit(UDF_INIT *initid)
{
    if (initid->ptr)
        free(initid->ptr);
}

/* ---- kc_to_utf8 ---- */
my_bool kc_to_utf8_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        strncpy(message, "kc_to_utf8() requires exactly 1 argument",
                MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->max_length = KC_MAX_OUT;
    initid->ptr = (char *)malloc(KC_MAX_OUT);
    if (!initid->ptr) {
        strncpy(message, "kc_to_utf8: out of memory", MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }
    return 0;
}

char *kc_to_utf8(UDF_INIT *initid, UDF_ARGS *args,
                 char *result __attribute__((unused)),
                 unsigned long *length, char *is_null, char *error)
{
    (void)result;
    (void)error;
    if (args->args[0] == NULL) {
        *is_null = 1;
        return NULL;
    }
    /* MariaDB passes string UDF args as length-prefixed, NOT NUL-terminated.
     * Copy into a properly terminated local buffer before any strlen/strchr
     * work, otherwise we scan past the argument into adjacent memory. */
    char inbuf[KC_MAX_OUT];
    size_t inlen = args->lengths[0];
    if (inlen >= KC_MAX_OUT)
        inlen = KC_MAX_OUT - 1;
    memcpy(inbuf, args->args[0], inlen);
    inbuf[inlen] = '\0';

    char *out = initid->ptr;
    if (kc_utf8_core(inbuf, out, KC_MAX_OUT) != 0) {
        *is_null = 1;
        return NULL;
    }
    *length = (unsigned long)strlen(out);
    return out;
}

void kc_to_utf8_deinit(UDF_INIT *initid)
{
    if (initid->ptr)
        free(initid->ptr);
}
#endif
