# idn_kc_convert_MariaDB

把邮箱地址或域名在 **UTF-8（IDN）** 与 **punycode（ASCII/ACE）** 之间互转的
**MariaDB / MySQL 自定义函数（UDF）**，与常见的 PHP `idn_kc_convert()` 语义
**逐字节一致**。

提供两个函数：

- `kc_to_ascii(input)` —— UTF-8/IDN → punycode（入信查表时用）
- `kc_to_utf8(input)` —— punycode → UTF-8/IDN（出库展示/回信时用）

它解决的是一个具体问题：邮局要支持 `中文@中文.中国` 这类 **IDN 邮箱**（本地名和域名都非 ASCII），
而 Postfix / Dovecot 的原生 `mysql:` 查表不会做 punycode 转换。传统做法是常驻一个 PHP
守护进程（socketmap）在 SQL 前转换地址——那是个单点。本 UDF 把转换下沉进数据库：

```sql
WHERE username = kc_to_ascii('%u')      -- 入信：中文@中文.中国 -> xn--...@xn--...
```

Postfix、Dovecot 即可用原生 `mysql:` 表，**彻底去掉常驻进程**。反方向用 `kc_to_utf8`
把库里存的 punycode 用户名还原成可读的 UTF-8（例如后台/"已收邮件"列表展示、回信路由）。

```sql
mysql> SELECT kc_to_ascii('中文@中文.中国');
+---------------------------------------+
| xn--fiq228c@xn--fiq228c.xn--fiqs8s     |
+---------------------------------------+

mysql> SELECT kc_to_utf8('xn--fiq228c@xn--fiq228c.xn--fiqs8s');
+---------------------------------------+
| 中文@中文.中国                          |
+---------------------------------------+

mysql> SELECT kc_to_utf8(kc_to_ascii('中文@中文.中国')) AS roundtrip;
+---------------------------------------+
| 中文@中文.中国                          |
+---------------------------------------+
```

## 构建

依赖：`libidn2`（必需）；编译 `.so` 另需 `libmariadb-dev`（Debian/Ubuntu：
`apt install libmariadb-dev`）。

```bash
make standalone    # 编译测试二进制 kc_idn_test（只需 libidn2，不动数据库）
make udf           # 编译 kc_idn.so（需 libmariadb-dev）
```

## 安装

```bash
cp kc_idn.so $(mariadb_config --plugindir)
mysql -e "CREATE FUNCTION kc_to_ascii RETURNS STRING SONAME 'kc_idn.so';"
mysql -e "CREATE FUNCTION kc_to_utf8  RETURNS STRING SONAME 'kc_idn.so';"
```

`CREATE FUNCTION` 需要 root 权限，注册信息存于 `mysql.func` 表，MariaDB 重启后自动加载。
**注意：UDF 是运行在 mariadbd 进程内的 C 代码**——请自行审阅源码（单文件、约 350 行），
并确认插件目录权限；MariaDB 大版本升级后需用新版本头文件重新编译 `.so`。

## 使用

Postfix `mysql:` 映射（`/etc/postfix/mysql-virtual-mailbox-maps.cf`）：

```
query = SELECT 1 FROM mailbox WHERE local_part = kc_to_ascii('%u') AND domain = kc_to_ascii('%d') AND active = 1
```

Dovecot `auth-sql.conf.ext`：

```sql
password_query = SELECT username, password FROM mailbox WHERE username = kc_to_ascii('%u')
```

出库展示（把存的 punycode 用户名还原成可读 UTF-8）：

```sql
SELECT kc_to_utf8(username) AS display FROM mailbox WHERE ...
```

Dovecot 侧还需放行非 ASCII 用户名（`auth_username_chars = utf8`），Postfix 侧如需
UTF8 发件人则开 `smtputf8_enable = yes` 并补 `sender_canonical_maps`。

## 语义（与 PHP 参照实现完全一致，两个方向都一样）

按顺序：

1. `trim()`（PHP 默认字符集 `" \t\n\r\0\x0B"`）
2. 空输入 → 返回字符串 `no_input`
3. 输入含多于一个 `@` → 返回 `too_many_at_2+`
4. 输入超过 200 字节 → 返回 `input_too_long`
   （这三个哨兵值只是"查不到任何行"，与 PHP 原版行为一致——查表失败即拒信）
5. 过滤危险字符 `[<>"';=&|\?`{}()[]%*/\s]`，再把连续 `.` 折叠成一个
   （两个 preg_replace，**先过滤后折叠**）
6. 按**第一个** `@` 拆本地名/域名；前导 `@` 表示"只有域名"；尾随 `@`（域名为空）
   返回本地名部分
7. 本地名、域名**分别**做转换；已 punycode / 纯 ASCII 输入原样返回（幂等）
   - `kc_to_ascii` → `idn_to_ascii(..., UTS46)`
   - `kc_to_utf8`  → `idn_to_utf8 (..., UTS46)`
8. 转换失败 → PHP 返回 `false`，字符串上下文中即 `''`

### 与 PHP 生产版的唯一差异

PHP 原版在过滤后有一段 `mb_detect_encoding($s, ['UTF-8','GBK','ASCII'])` +
`mb_convert_encoding()` 的**编码猜测**，本 UDF **整段移除**，入参恒按 UTF-8 处理。原因：
Postfix/Dovecot 投递的地址只可能是 UTF-8（SMTPUTF8）或 ASCII，而该猜测实测有三类故障
（详见 `docs/robustness-report.md`）：把 4 字节 UTF-8（emoji）误判为 GBK 损坏字节、
把与 UTF-8 碰撞的 GBK 字节误判为 UTF-8 得到空结果、遇到未知编码直接抛未捕获的
`ValueError`。若你的上层确实可能提交 GBK，请在调用方先转 UTF-8。

## 验证

在 Debian 13 / PHP 8.4.25（intl）/ libidn2 2.3.8 上，以仓库内 PHP 参照实现
（`php_idn_kc_convert.php`）为基准：

| 测试 | 结果 |
|---|---|
| `compare_idn.php` A/B/C 对拍（A 编码 41 例 / B 解码 22 例 / C 往返 41 例） | **104/104 逐字节一致** |
| `test/test_robustness.php`（边界硬断言 + 幂等 + 模糊 200 例 + 双向对拍） | **全部通过，0 抛出** |
| `test/test_gbk.php`（GBK/非法字节输入） | 全部 AGREE（均返回空、不崩溃） |
| `.so` UDF 接口分支 | 桩头文件 `-fsyntax-only` 通过（`-Wall -Wextra` 无警告） |

复现：

```bash
make standalone
php compare_idn.php
php test/test_robustness.php
php test/test_gbk.php
```

几个值得知道的设计决策（都有实测证据，见报告）：

- **必须用 `IDN2_TRANSITIONAL`**：PHP/ICU 的 transitional 处理把 `faß.de` 映射为
  `fass.de`，而非过渡处理会给 `xn--fa-hia.de`——用错标志会让所有含 ß 的邮箱查不到。
  解码方向同样使用此标志，保证 `kc_to_utf8(kc_to_ascii(x)) == x`。
- **入口先做严格 UTF-8 校验**：libidn2 的解码器是宽松的，会把非法字节（如 GBK 的
  `d6 d0 b9 fa`）跳过坏字节后"解出"字符并生成假 ACE；ICU 则是严格失败。校验后两者一致。
- 测试二进制提供 `--hex <hex>` 模式：把输入按十六进制传入，避开 shell/argv 对原始
  字节的不稳定传递（在 PHP `shell_exec` 链路上实测观察到过 GBK 字节被破坏）。`--utf8`
  切换解码方向。UDF 在 SQL 中由客户端库直接传字节，不经 shell，不受影响。

## 生产部署注意事项（实测踩坑）

以下每一条都在 Debian 13 / MariaDB 11.8.6 / Postfix 3.10 的真实邮局上踩到并验证过，
代价是 MariaDB 崩溃一次 + IDN 邮箱退信一次。改前请先看这里。

### 1. UDF 字符串参数不是 NUL 结尾的

MariaDB 传给 UDF 的字符串是**长度前缀、不带 `\0`**。直接对 `args->args[0]`
用 `strlen()` / `strchr()` 会越过参数读到相邻内存。曾因此静默损坏多标签 ACE 域名：

    kc_to_ascii('xn--fiqs8s.xn--nqv7f')  ->  xn--fiqs8s.xn--nqv7ffiqs8s   ← 串入了标签

入口必须按 `args->lengths[0]` 复制并手动补 `\0`（见 `kc_idn.c` 两处 `inbuf`）。

### 2. 必须保留前导 `@`（catch-all 的命门）

`alias` 表的 catch-all 行存成 `@domain`（如 `@vche.net`）。查表时会用
`kc_to_ascii(address) = CONCAT('@', ...)` 去匹配，**如果 `kc_to_ascii()` 把前导 `@`
吃掉，左边变 `vche.net`、右边是 `@vche.net`，catch-all 永远匹配不上**，而且不报错、
只是静默失效。所以本 UDF 明确保留前导 `@`：

    kc_to_ascii('@vche.net')    -> '@vche.net'
    kc_to_ascii('@机构.中国')   -> '@xn--nqv7f.xn--fiqs8s'

### 3. 别名域里"恒等映射"必须排除，否则 IDN 邮箱退信

存在一种行：`alias_domain` 把域名的 **UTF-8 写法映射到它自己的 ACE 形式**
（如 `的.中国 → xn--hxy.xn--fiqs8s`、`α.cc → xn--mxa.cc`）。这不是真正的别名域，
只是同一域名的 UTF-8 拼写索引；而它同时在 `domain` 表里（是邮箱域）。

一旦把它当别名域用，Postfix 会认为该域"同时在 virtual_alias_domains 和
virtual_mailbox_domains"，于是按别名域处理，该域下**所有邮箱退信**：

    dsn=5.1.1, status=bounced (User unknown in virtual alias table)

解决：两个映射都加上排除条件
`AND kc_to_ascii(target_domain) <> kc_to_ascii(alias_domain)`。
（旧 PHP 守护是裸比较列值，UTF-8 存的行从来匹配不上，所以"歪打正着"没这个问题——
这正是它的行为需要被复刻的原因。）

### 4. `postmap -q` 与线上结果不一致是正常的——且它决定收件优先级

Postfix 的 `mail_addr_find()` 对 `virtual_alias_maps` **自带 `@domain` catch-all 回退**：
先查完整地址，**只有返回 NOTFOUND 时**才自动再查字面键 `@domain`。而 `postmap -q` 只查
你给的那个键、**不做回退**。所以会看到：

    postmap -q nic@vche.net  ->  (空)
    线上投递                ->  injy@qq.com      ← 第二次 @vche.net 查到的

**这个回退机制直接决定收件优先级**：本地邮箱存在时，映射必须返回**地址本身**
（`THEN '%s'`）而不是 NULL。返回 NULL = NOTFOUND = 触发回退 = 真实邮箱被 catch-all
劫持；返回地址本身 = 查询成功 = 不回退 = 落到 `virtual_mailbox_maps` 本地投递。
最终优先级：

    1对1转发(alias 行) > 真实邮箱(返回自身) > catch-all(@domain)

排查时别误判成 UDF 不确定；要验证最终路由，用真实投递看 `/var/log/postfix/postfix.log`。

### 5. 更新 `.so` 的顺序：先 DROP，再换文件，再 CREATE

覆盖一个**已被加载**的 `.so` 会让 MariaDB 崩溃（实测触发 crash recovery）。
正确顺序：

```bash
mysql -e "DROP FUNCTION IF EXISTS kc_to_ascii; DROP FUNCTION IF EXISTS kc_to_utf8;"
cp kc_idn.so $(mariadb_config --plugindir)/     # 此时未被加载
mysql < create.sql                               # 重新从磁盘加载
```

另外 `CREATE FUNCTION ... SONAME` 在 MariaDB 上要用**双引号**：`SONAME "kc_idn.so"`。

## 文件

```
kc_idn.c                 UDF 源码（单文件；#ifdef STANDALONE_TEST 内含测试 main）
looptest.c               libidn2 转换（UTS46 transitional）幂等性独立验证
Makefile                 standalone / udf / test / clean
php_idn_kc_convert.php   PHP 参照实现（kc_to_ascii / kc_to_utf8，语义基准）
compare_idn.php          A/B 对拍：C UDF vs PHP 参照（编码 + 解码 + 往返）
test/test_robustness.php 边界/幂等/往返/模糊 + 双向对拍
test/test_gbk.php        编码处理专项（GBK、非法字节、emoji）
docs/robustness-report.md 验证报告与设计决策
patch_leading_at.py      给 kc_idn.c 打"保留前导 @"补丁（幂等锚点校验）
create.sql / drop.sql    CREATE / DROP FUNCTION（注册与卸载 UDF）
verify_udf.sql           UDF 自测（前导@、catch-all 键、emoji、哨兵值等）
smoke.sql                注册 + 示例 + 往返冒烟
```

## License

MIT
