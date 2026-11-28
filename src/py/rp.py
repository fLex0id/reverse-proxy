#!/usr/bin/env python3
# rp.py — генератор конфигов VPS-1 и пакета для VPS-2. Только стандартная библиотека (3.9+).
# Ничего не меняет в системе: пишет файлы в каталог, который передал rp.sh.
# Ошибки: die("…") → «Ошибка: …».
import hashlib
import io
import ipaddress
import json
import re
import os
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

CONF = os.environ.get("RP_CONF", "/etc/rp/rp.conf")
CLIENTS = os.environ.get("RP_CLIENTS", "/etc/rp/clients.tsv")
ETC = os.environ.get("RP_ETC", "/etc/rp")
TPROXY_PORT = 14205
DNS_HIJACK_PORT = 14206
SOCKS_PORT = 1080
ECHO_PORT = 7000
EXIT_MARK = 255          # метка исходящих пакетов Xray в режимах hy2 (ip rule → таблица 200)
EXIT_TABLE = 200
PROBE_URL = "https://www.gstatic.com/generate_204"

# Транспорты. reality-tcp убран: ТСПУ замораживает один TCP-поток после ~16 КБ,
# XHTTP делит передачу на несколько запросов и этого не боится.
ALL_TR = ("hy2-wg", "hy2o-wg", "reality-xhttp", "reality-xhttp2")
LEGACY = {"reality-tcp": "reality-xhttp2"}
# Единый согласованный с Bash порядок предпочтения транспортов.
DEFAULT_ORDER = "reality-xhttp2 reality-xhttp hy2-wg hy2o-wg"
VARIANTS = {
    "reality-xhttp": {"tag": "rx", "port": "RXH_PORT", "sni": "RXH_SNI", "path": "XHTTP_PATH",
                      "uuid": "RL_UUID_X", "probe": "RL_UUID_PX", "rev": "r-xhttp", "mode": "stream-up"},
    "reality-xhttp2": {"tag": "rx2", "port": "RXH2_PORT", "sni": "RXH2_SNI", "path": "XHTTP2_PATH",
                       "uuid": "RL_UUID_T", "probe": "RL_UUID_PT", "rev": "r-xhttp2", "mode": "packet-up"},
}

# DNS через туннель: DoH (RFC 8484, HTTPS), адреса по IP — имя сервера резолвить не нужно.
DNS_PRESETS = {
    "quad9": ["https://9.9.9.9/dns-query", "https://149.112.112.112/dns-query"],
    "cloudflare": ["https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query"],
    "google": ["https://8.8.8.8/dns-query", "https://8.8.4.4/dns-query"],
    "adguard": ["https://94.140.14.14/dns-query", "https://94.140.15.15/dns-query"],
}


def die(msg):
    sys.stderr.write("Ошибка: %s\n" % msg)
    sys.exit(1)


def load_conf(path=CONF):
    cfg = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] == '"':
                    v = v[1:-1]
                cfg[k.strip()] = v
    except OSError as e:
        die("не удалось прочитать %s: %s" % (path, e))
    return cfg


def need(cfg, *keys):
    miss = [k for k in keys if not cfg.get(k)]
    if miss:
        die("в rp.conf не заданы: %s" % ", ".join(miss))


def write_atomic(path, data, mode=0o644):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_list(path):
    """Один домен на строку, # комментарии; без дублей, порядок сохраняется."""
    out, seen = [], set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.split("#", 1)[0].strip().lower()
                if not s or s in seen:
                    continue
                s = domain_ascii(s)
                seen.add(s)
                out.append(s)
    except OSError:
        pass
    return out


def read_clients():
    rows = []
    try:
        with open(CLIENTS, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 5 and not line.startswith("#"):
                    rows.append({"name": p[0], "priv": p[1], "pub": p[2], "psk": p[3], "ip": p[4]})
    except OSError:
        pass
    return rows


def transports(cfg):
    raw = cfg.get("TRANSPORT_ORDER", DEFAULT_ORDER).split()
    order = []
    for t in raw:
        t = LEGACY.get(t, t)
        if t not in ALL_TR:
            die("неизвестный транспорт в TRANSPORT_ORDER: %s" % t)
        if t not in order:
            order.append(t)
    force = cfg.get("TRANSPORT_FORCE", "").strip()
    if force:
        force = LEGACY.get(force, force)
        if force not in ALL_TR:
            die("TRANSPORT_FORCE: неизвестный транспорт «%s»" % force)
        order = [force]
    if not order:
        die("TRANSPORT_ORDER пуст")
    return order


def has_hy2(order):
    return any(t.startswith("hy2") for t in order)


def doors(cfg):
    """DOORS="имя=порт=хост:порт;…" → [(имя, порт, хост, порт_цели)]"""
    out = []
    for item in cfg.get("DOORS", "ssh=2222=127.0.0.1:22").split(";"):
        item = item.strip()
        if not item:
            continue
        try:
            name, lport, target = item.split("=", 2)
            host, tport = target.rsplit(":", 1)
            ipaddress.ip_address(host)
            out.append((name, int(lport), host, int(tport)))
        except ValueError:
            die("DOORS: неверная запись «%s» (нужно имя=порт=ip:порт)" % item)
    return out


def dns_remote(cfg):
    """DNS_REMOTE — пресеты и/или адреса DoH через пробел; порядок = порядок опроса (запасные следом)."""
    urls = []
    for it in cfg.get("DNS_REMOTE", "quad9 cloudflare").split():
        if it in DNS_PRESETS:
            urls += DNS_PRESETS[it]
        elif it.startswith("https://") and "\"" not in it:
            urls.append(it)
        else:
            die("DNS_REMOTE: неизвестный пресет или адрес «%s» (пресеты: %s)" % (it, ", ".join(sorted(DNS_PRESETS))))
    out = []
    for u in urls:
        if u not in out:
            out.append(u)
    if not out:
        die("DNS_REMOTE пуст")
    return out


def dns_hosts(cfg):
    """IP первых двух DoH-серверов — для строки DNS в конфигах клиентов WG (запросы всё равно перехватываются)."""
    hosts = []
    for u in dns_remote(cfg):
        h = u.split("//", 1)[1].split("/", 1)[0]
        try:
            ipaddress.ip_address(h)
            hosts.append(h)
        except ValueError:
            pass
    return hosts[:2] or ["9.9.9.9", "149.112.112.112"]


# Stable critical services. Narrow suffixes only; operator ru-proxy and guard win.
# This is a fallback when upstream geosite categories change, NOT a wildcard for *.com.
RU_DIRECT_CORE = tuple(dict.fromkeys((
    "ozon.ru", "ozonusercontent.com", "wildberries.ru", "wb.ru", "wbstatic.net",
    "avito.ru", "avito.st", "megamarket.ru", "dns-shop.ru", "citilink.ru",
    "mvideo.ru", "eldorado.ru", "lamoda.ru", "market.yandex.ru",
    "sberbank.ru", "sber.ru", "vtb.ru", "tbank.ru", "tinkoff.ru",
    "alfabank.ru", "gazprombank.ru", "raiffeisen.ru", "cbr.ru",
    "nspk.ru", "mironline.ru", "moex.com",
    "gosuslugi.ru", "gu-st.ru", "nalog.gov.ru", "government.ru",
    "kremlin.ru", "mos.ru", "gov.ru", "rosreestr.gov.ru",
    "zakupki.gov.ru", "rospotrebnadzor.ru"
)))
RU_FOREIGN_GUARD = ("google.com", "youtube.com", "instagram.com", "telegram.org",
                    "cloudflare.com", "github.com", "openai.com", "whatsapp.com")


def rule_domain_list(names):
    return ["domain:" + s for s in names]


def domain_ascii(s):
    s = s.strip().lower().rstrip(".")
    try:
        s = s.encode("idna").decode("ascii")
    except UnicodeError:
        die("ошибка IDNA в доменном списке: %s" % s)
    if not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", s) or len(s) > 253:
        die("некорректное имя домена: %s" % s)
    return s

# ── Xray на VPS-1 ───────────────────────────────────────────────────────

def xh_settings(cfg, v, server):
    s = {"path": cfg.get(v["path"]) or "/rp", "mode": "auto" if server else v["mode"],
         "xPaddingBytes": "100-1000"}
    if not server and v["mode"] == "packet-up":
        # второй вариант: запросы POST разной длины и случайный срок жизни соединений
        s["scMaxEachPostBytes"] = "500000-1000000"
        s["scMinPostsIntervalMs"] = "20-60"
        s["xmux"] = {"maxConcurrency": "8-16", "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000"}
    return s


def reality_stream(cfg, t):
    v = VARIANTS[t]
    sni = cfg[v["sni"]]
    return {"network": "xhttp", "security": "reality",
            "realitySettings": {"show": False, "target": "%s:443" % sni, "xver": 0,
                                "serverNames": [sni], "privateKey": cfg["RL_PRIV"],
                                "shortIds": [cfg["RL_SID"]]},
            "xhttpSettings": xh_settings(cfg, v, True)}


def xray_server(cfg):
    order = transports(cfg)
    xh = [t for t in order if t in VARIANTS]
    hy = has_hy2(order)
    need(cfg, "SOCKS_USER", "SOCKS_PASS")
    if xh:
        need(cfg, "RL_PRIV", "RL_SID")
    for t in xh:
        v = VARIANTS[t]
        need(cfg, v["port"], v["sni"], v["uuid"], v["probe"])

    # Local-only metadata used to route RU domains; routeOnly preserves the actual destination IP.
    # Turning it off would remove domain-based split rules for IP-only WireGuard flows.
    sniff = {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}
    wg_tp = {"tag": "wg-tp", "listen": "0.0.0.0", "port": TPROXY_PORT, "protocol": "tunnel",
             "settings": {"network": "tcp,udp", "followRedirect": True},
             "streamSettings": {"sockopt": {"tproxy": "tproxy"}}}
    if cfg.get("SNIFF", "1") == "1":
        wg_tp["sniffing"] = sniff
    inb = [wg_tp,
           # Conntrack reverses the DNS redirect to the resolver originally
           # queried by the client. A normal socket avoids Xray full-cone
           # sessions reusing the first resolver's transparent reply address.
           {"tag": "dns-hijack", "listen": "0.0.0.0", "port": DNS_HIJACK_PORT, "protocol": "tunnel",
            "settings": {"network": "tcp,udp", "address": "127.0.0.1", "port": 53}},
           # локальный SOCKS только с паролем (127.0.0.1): пароль в rp.conf, в аргументы процессов не попадает
           {"tag": "socks-in", "listen": "127.0.0.1", "port": SOCKS_PORT, "protocol": "socks",
            "settings": {"auth": "password", "accounts": [{"user": cfg["SOCKS_USER"], "pass": cfg["SOCKS_PASS"]}],
                         "udp": False}}]
    in_tags = []
    for t in xh:
        v = VARIANTS[t]
        in_tags.append(v["tag"])
        inb.append({"tag": v["tag"], "listen": "0.0.0.0", "port": int(cfg[v["port"]]), "protocol": "vless",
                    "settings": {"decryption": "none", "clients": [
                        {"id": cfg[v["uuid"]], "reverse": {"tag": v["rev"]}},
                        {"id": cfg[v["probe"]]}]},
                    "streamSettings": reality_stream(cfg, t)})
    door_tags = []
    if xh:
        for name, lport, host, tport in doors(cfg):
            tag = "door-%s" % name
            door_tags.append(tag)
            inb.append({"tag": tag, "listen": "127.0.0.1", "port": lport, "protocol": "tunnel",
                        "settings": {"address": host, "port": tport, "network": "tcp"}})

    # Первый outbound — по умолчанию: blackhole (при любой путанице трафик не уходит напрямую).
    out = [{"tag": "block", "protocol": "blackhole"},
           {"tag": "direct", "protocol": "freedom",
            "streamSettings": {"sockopt": {"domainStrategy": "ForceIPv4"}}}]
    if hy:
        out.append({"tag": "to-exit", "protocol": "freedom",
                    "streamSettings": {"sockopt": {"mark": EXIT_MARK, "domainStrategy": "ForceIPv4"}}})
    if xh:
        # ipsBlocked=[]: Xray 26.x иначе блокирует 127.0.0.1 («blocked target IP») и проба к эхо не проходит;
        # сюда попадает только трафик с reality-входов по правилу «127.0.0.1:ECHO_PORT», остальное — block
        out.append({"tag": "local-echo", "protocol": "freedom",
                    "settings": {"redirect": "127.0.0.1:%d" % ECHO_PORT, "ipsBlocked": []}})
    # Xray 26.4.25 does not implement DNS-out action 'return' (startup error).
    # 'drop' is supported. Only A/AAAA are hijacked into split DNS; HTTPS/SVCB
    # and other qtypes cannot fall back to a plaintext/system resolver.
    # Unknown query types are deliberately dropped, NOT misreported as REFUSED.
    out.append({"tag": "dns-out", "protocol": "dns", "settings": {"rules": [
        {"action": "drop", "qType": "64-65"},
        {"action": "hijack", "qType": "1,28"},
        {"action": "drop"}
    ]}})

    rev_tags = [VARIANTS[t]["rev"] for t in xh]
    sel = (["to-exit"] if hy else []) + rev_tags
    use_bal = bool(rev_tags)       # балансировщик нужен, только если есть reverse-транспорты
    exit_ref = {"balancerTag": "exit"} if use_bal else {"outboundTag": "to-exit"}

    ru_dns = cfg.get("DNS_RU", "77.88.8.8")
    try:
        if ipaddress.ip_address(ru_dns).version != 4: raise ValueError("IPv4 only")
    except ValueError:
        die("DNS_RU: сейчас поддерживается только числовой IPv4 (например 77.88.8.8)")
    ru_on = cfg.get("RU_DIRECT", "1") == "1"
    ru_sets = [s for s in cfg.get("RU_SETS", "category-ru yandex vk category-gov-ru 2gis").split() if s]
    ru_domains = ["geosite:%s" % s for s in ru_sets]
    # domain: — суффиксное сопоставление (быстрее regexp, который Xray проверяет перебором по каждому запросу)
    ru_domains += ["domain:ru", "domain:su", "domain:xn--p1ai"]
    ru_domains += rule_domain_list(RU_DIRECT_CORE)

    def rule(**kw):
        kw["type"] = "field"
        return kw

    rules = [rule(inboundTag=["socks-in"], **exit_ref),
             rule(inboundTag=["dns-hijack"], outboundTag="dns-out"),
             rule(inboundTag=["wg-tp"], port="53", network="tcp,udp", outboundTag="dns-out")]
    if in_tags:
        rules.append(rule(inboundTag=in_tags, ip=["127.0.0.1"], port=str(ECHO_PORT), outboundTag="local-echo"))
        rules.append(rule(inboundTag=in_tags, outboundTag="block"))
    if door_tags:
        rules.append(rule(inboundTag=door_tags, balancerTag="rev"))
    if ru_on:
        rules.append(rule(inboundTag=["dns-in"], ip=[ru_dns], outboundTag="direct"))
    rules.append(rule(inboundTag=["dns-in"], **exit_ref))
    priv = ["geoip:private"]
    if cfg.get("PUBLIC_IP"):
        priv.append("%s/32" % cfg["PUBLIC_IP"])
    rules.append(rule(inboundTag=["wg-tp"], ip=priv, outboundTag="block"))
    etc = cfg.get("ETC", ETC)
    force_proxy = read_list(os.path.join(etc, "ru-proxy.list"))
    force_direct = read_list(os.path.join(etc, "ru-direct.list"))
    # Foreign control domains never direct, even if an operator or a bad geo
    # database later assigns a Russian IP or adds one to ru-direct.list.
    rules.append(rule(inboundTag=["wg-tp"], domain=rule_domain_list(RU_FOREIGN_GUARD), **exit_ref))
    if force_proxy:
        rules.append(rule(inboundTag=["wg-tp"], domain=["domain:%s" % d for d in force_proxy], **exit_ref))
    if ru_on and cfg.get("RU_GUARD", "1") == "1":
        rules.append(rule(inboundTag=["wg-tp"], domain=["geosite:ru-blocked"], **exit_ref))
    if ru_on and force_direct:
        rules.append(rule(inboundTag=["wg-tp"], domain=rule_domain_list(force_direct), outboundTag="direct"))
    if ru_on:
        rules.append(rule(inboundTag=["wg-tp"], domain=ru_domains, outboundTag="direct"))
        if cfg.get("RU_GEOIP", "1") == "1":
            rules.append(rule(inboundTag=["wg-tp"], ip=["geoip:ru"], outboundTag="direct"))
    rules.append(rule(inboundTag=["wg-tp"], **exit_ref))

    # Three disjoint DNS priority layers. Priority on match is NOT sufficient:
    # overlapping .ru domains also match the direct server, so the final remote
    # guard DoH must use finalQuery to avoid fallthrough into Russian DNS.
    remotes = dns_remote(cfg)
    dns_servers = []
    if ru_on:
        forced = rule_domain_list(RU_FOREIGN_GUARD) + rule_domain_list(force_proxy)
        if cfg.get("RU_GUARD", "1") == "1":
            forced.append("geosite:ru-blocked")
        if forced:
            for idx, address in enumerate(remotes):
                dns_servers.append({"address": address, "domains": forced,
                                    "skipFallback": True,
                                    "finalQuery": idx == len(remotes) - 1})
        # Russian DNS is NEVER a fallback for other domains, even during DoH outage.
        direct_domains = rule_domain_list(force_direct) + ru_domains
        dns_servers.append({"address": ru_dns, "domains": direct_domains,
                            "skipFallback": True, "finalQuery": True})
    # All other names: encrypted DoH routed over the exit tunnel only.
    for idx, address in enumerate(remotes):
        dns_servers.append({"address": address, "finalQuery": idx == len(remotes) - 1})

    routing = {"domainStrategy": "AsIs", "rules": rules}
    res = {"log": {"loglevel": "warning", "access": "none"},
           "dns": {"tag": "dns-in", "servers": dns_servers,
                   "queryStrategy": "UseIPv4", "disableFallbackIfMatch": True},
           "inbounds": inb, "outbounds": out, "routing": routing}
    if use_bal:
        # gRPC control plane: local loopback ONLY; no external firewall port.
        # VPS-1 mirrors the actual active transport selected by VPS-2, avoiding
        # an independent leastPing choice during a manual/automatic failover.
        res["api"] = {"tag": "rp-route-api", "listen": "127.0.0.1:10085",
                      "services": ["RoutingService"]}
        bals = [{"tag": "exit", "selector": sel, "strategy": {"type": "leastPing"}, "fallbackTag": "block"}]
        if door_tags:
            bals.append({"tag": "rev", "selector": rev_tags, "strategy": {"type": "leastPing"}, "fallbackTag": "block"})
        routing["balancers"] = bals
        res["observatory"] = {"subjectSelector": sel, "probeUrl": cfg.get("PROBE_URL", PROBE_URL),
                              # 10 s, not 45 s: leastPing has no live outbound until the first probe after a
                              # bridge (re)connects, and the SSH door / T3 stay closed for that long.
                              "probeInterval": "10s", "enableConcurrency": True}
    return json.dumps(res, indent=2, ensure_ascii=False) + "\n"


# ── Hysteria2, WireGuard ────────────────────────────────────────────────

def hy2_bind_ip(cfg):
    """Bind only an assigned underlay IPv4, including servers behind NAT.

    A wildcard UDP/443 listener prevents Xray's transparent UDP reply socket
    from binding a foreign destination such as 1.1.1.1:443 (EADDRINUSE).
    """
    try:
        interfaces = json.loads(subprocess.check_output(
            ['ip', '-j', '-4', 'address', 'show'], text=True, timeout=5))
        assigned = {a['local'] for iface in interfaces
                    if iface.get('ifname') not in ('lo', 'wg0', 'wg-exit')
                    for a in iface.get('addr_info', []) if a.get('family') == 'inet'}
        address = cfg.get('HY2_BIND_IP', '')
        if not address:
            public = str(ipaddress.IPv4Address(cfg['PUBLIC_IP']))
            if public in assigned:
                address = public
            else:
                route = json.loads(subprocess.check_output(
                    ['ip', '-j', '-4', 'route', 'get', public], text=True, timeout=5))
                address = route[0].get('prefsrc', '')
        parsed = ipaddress.IPv4Address(address)
        if parsed.is_unspecified or parsed.is_loopback or str(parsed) not in assigned:
            raise ValueError('HY2_BIND_IP must be an assigned underlay IPv4 address')
        return str(parsed)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError) as exc:
        die('Не удалось выбрать локальный адрес Hysteria2; задайте HY2_BIND_IP: %s' % exc)


def hy2_server(cfg, obfs=False):
    port = "HY2O_PORT" if obfs else "HY2_PORT"
    need(cfg, port, "HY2_PASS", "HY2_MASQ")
    if obfs:
        need(cfg, "HY2O_OBFS")
    etc = cfg.get("ETC", ETC)
    s = ("listen: %s:%s\n"
         "tls:\n  cert: %s/hy2.crt\n  key: %s/hy2.key\n  sniGuard: disable\n"
         "auth:\n  type: password\n  password: \"%s\"\n"
         % (hy2_bind_ip(cfg), cfg[port], etc, etc, cfg["HY2_PASS"]))
    if obfs:
        s += "obfs:\n  type: salamander\n  salamander:\n    password: \"%s\"\n" % cfg["HY2O_OBFS"]
    s += ("masquerade:\n  type: proxy\n  proxy:\n    url: %s\n    rewriteHost: true\n"
          "udp:\n  enabled: true\n  idleTimeout: 120s\n"
          # Do not turn Hysteria into an unrestricted forward proxy into VPS-1.
          # Built-in ACL 'reject' must be terminal; no other destinations allowed.
          "acl:\n  inline:\n    - direct(127.0.0.1, udp/51821)\n    - reject(all)\n"
          "# Без bandwidth (Brutal): остаётся BBR.%s\n"
          % (cfg["HY2_MASQ"], " Salamander включён: пакеты не похожи на QUIC." if obfs
             else " Без obfs: трафик похож на HTTP/3."))
    return s


def hy2_client(cfg, obfs=False):
    port = "HY2O_PORT" if obfs else "HY2_PORT"
    need(cfg, "PUBLIC_IP", port, "HY2_PASS", "HY2_SNI", "HY2_PIN")
    pin = cfg["HY2_PIN"].upper()
    if ":" not in pin:
        pin = ":".join(pin[i:i + 2] for i in range(0, len(pin), 2))
    s = ("server: %s:%s\nauth: \"%s\"\n"
         "tls:\n  sni: %s\n  insecure: true\n  pinSHA256: \"%s\"\n"
         % (cfg["PUBLIC_IP"], cfg[port], cfg["HY2_PASS"], cfg["HY2_SNI"], pin))
    if obfs:
        need(cfg, "HY2O_OBFS")
        s += "obfs:\n  type: salamander\n  salamander:\n    password: \"%s\"\n" % cfg["HY2O_OBFS"]
    s += ("transport:\n  type: udp\n"
          "udpForwarding:\n  - listen: 127.0.0.1:51820\n    remote: 127.0.0.1:51821\n    timeout: 120s\n")
    return s


def exit_mtu(cfg):
    value = str(cfg.get("EXIT_MTU", "1280"))
    # IPv4 (20) + UDP (8) + minimum QUIC datagram (1200); no DF-clearing hack.
    # Hysteria fragments/reassembles its UDP payload above the outer QUIC layer.
    if not re.fullmatch(r"[0-9]+", value) or not 1228 <= int(value) <= 65535:
        die("EXIT_MTU должен быть 1228..65535 для QUIC/HTTP3; рекомендуется 1280. "
            "Измените на VPS-1, выполните rp apply и rp push")
    return value


def wg_exit_server(cfg):
    need(cfg, "EXIT_PRIV1", "EXIT_PUB2", "EXIT_PSK")
    mtu = exit_mtu(cfg)
    # rp_filter=2 (loose): ответы из интернета приходят в wg-exit, а обратный маршрут к их адресам
    # в основной таблице ведёт в публичный интерфейс — при strict (1) ядро такие ответы выбрасывает.
    return ("[Interface]\nAddress = 10.77.0.1/30\nListenPort = 51821\nPrivateKey = %s\nMTU = %s\nTable = off\n"
            "PostUp = sysctl -q -w net.ipv4.conf.%%i.rp_filter=2 || true\n"
            "PostUp = ip route replace default dev wg-exit table %d metric 10\n"
            "PostDown = ip route del default dev wg-exit table %d metric 10 || true\n\n"
            "[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 0.0.0.0/0\n"
            % (cfg["EXIT_PRIV1"], mtu, EXIT_TABLE, EXIT_TABLE, cfg["EXIT_PUB2"], cfg["EXIT_PSK"]))


def wg_exit_client(cfg):
    need(cfg, "EXIT_PRIV2", "EXIT_PUB1", "EXIT_PSK")
    return ("[Interface]\nAddress = 10.77.0.2/30\nPrivateKey = %s\nMTU = %s\nTable = off\n\n"
            "[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = 127.0.0.1:51820\n"
            "AllowedIPs = 10.77.0.1/32\n"
            "# Bootstrap handshake via probe; refresh inner WG link at a non-default 28s.\n"
            "# VPS-2 initiates to loopback; WG is encapsulated by Hysteria2, not public UDP.\n"
            "PersistentKeepalive = 28\n"
            % (cfg["EXIT_PRIV2"], exit_mtu(cfg), cfg["EXIT_PUB1"], cfg["EXIT_PSK"]))


def wg0_server(cfg):
    need(cfg, "WG_PORT", "WG_PRIV", "WG_NET_GW")
    s = ("[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\nMTU = %s\n"
         "# Правила перехвата и kill switch ставит rp-net.service (до подъёма wg0)\n"
         % (cfg["WG_NET_GW"], cfg["WG_PORT"], cfg["WG_PRIV"], cfg.get("WG_MTU", "1380")))
    for c in read_clients():
        s += "\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n" % (c["name"], c["pub"], c["psk"], c["ip"])
    return s


def client_conf(cfg, name):
    for c in read_clients():
        if c["name"] == name:
            need(cfg, "WG_PUB", "PUBLIC_IP", "WG_PORT")
            return ("[Interface]\nPrivateKey = %s\nAddress = %s/32, fd66::%s/128\nDNS = %s\nMTU = %s\n\n"
                    "[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\n"
                    "AllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n"
                    % (c["priv"], c["ip"], c["ip"].split(".")[-1], cfg.get("WG_NET_GW", "10.66.0.1"),
                       cfg.get("WG_MTU", "1380"), cfg["WG_PUB"], c["psk"], cfg["PUBLIC_IP"], cfg["WG_PORT"]))
    die("клиент «%s» не найден" % name)


def nft_rules(cfg):
    """Fail-closed: WG forward blocked; DNS redirected, other TCP/UDP TPROXY, IPv6 blocked."""
    net = cfg.get("WG_NET", "10.66.0.0/24")
    return """#!/usr/sbin/nft -f
# Сгенерировано rp. Правка вручную не сохраняется — используйте rp apply.
table inet rp_guard
delete table inet rp_guard
table inet rp_guard {
  chain output {
    type filter hook output priority -100; policy accept;
    # Defense in depth if the source-routing rule is missing or changed.
    ip saddr 10.77.0.1 oifname != "wg-exit" oifname != "lo" counter drop
  }
  chain forward {
    type filter hook forward priority -100; policy accept;
    iifname "wg0" counter drop
    oifname "wg0" counter drop
  }
  chain input {
    type filter hook input priority -100; policy accept;
    # DNS interception is accessible only through the client WG interface.
    iifname != "wg0" iifname != "lo" meta l4proto { tcp, udp } th dport %(dns)d drop
    # WG между VPS слушает только loopback: снаружи порт закрыт
    iifname != "lo" udp dport 51821 drop
    # эхо-сервер для проб доступен только с loopback и из внутреннего WG-интерфейса
    iifname != "lo" iifname != "wg-exit" tcp dport 7000 drop
  }
}
table ip rp_tp
delete table ip rp_tp
table ip rp_tp {
  chain pre {
    type filter hook prerouting priority -150; policy accept;
    # Let conntrack redirect DNS at dstnat priority; never forward it directly.
    iifname "wg0" meta l4proto { tcp, udp } th dport 53 return
    iifname "wg0" ip daddr %(gw)s icmp type echo-request accept
    iifname "wg0" meta l4proto tcp tproxy to :%(tp)d meta mark set 1 accept
    iifname "wg0" meta l4proto udp tproxy to :%(tp)d meta mark set 1 accept
    iifname "wg0" drop
  }
  chain dns_redirect {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "wg0" meta l4proto { tcp, udp } th dport 53 redirect to :%(dns)d
  }
  chain in {
    type filter hook input priority -50; policy accept;
    iifname "wg0" ip saddr != %(net)s drop
  }
}
table ip6 rp_block6
delete table ip6 rp_block6
table ip6 rp_block6 {
  chain pre {
    type filter hook prerouting priority -150; policy accept;
    iifname "wg0" drop
  }
}
""" % {"tp": TPROXY_PORT, "dns": DNS_HIJACK_PORT, "net": net, "gw": cfg.get("WG_NET_GW", "10.66.0.1")}


# ── Пакет для VPS-2 ──────────────────────────────────────────────────────

def xray_client(cfg, t):
    """Мост VLESS Reverse + проба 127.0.0.1:7777 → эхо VPS-1."""
    v = VARIANTS[t]
    need(cfg, "PUBLIC_IP", "RL_PUB", "RL_SID", v["port"], v["sni"], v["uuid"], v["probe"])
    port = int(cfg[v["port"]])
    rs = {"serverName": cfg[v["sni"]], "fingerprint": cfg.get("RL_FP", "chrome"), "publicKey": cfg["RL_PUB"],
          "shortId": cfg["RL_SID"], "spiderX": "/"}
    stream = {"network": "xhttp", "security": "reality", "realitySettings": rs,
              "xhttpSettings": xh_settings(cfg, v, False)}

    def vless(tag, user_id, reverse=None):
        # Xray 26.x: для reverse (и для единообразия — для пробы) нужен «упрощённый» стиль outbound
        # (address/port/id без vnext/users); со старым vnext Xray отвечает «VLESS users: please use
        # simplified outbound's config style to use "reverse"» и мост не стартует (проверено xray run -test).
        st = {"address": cfg["PUBLIC_IP"], "port": port, "id": user_id, "encryption": "none"}
        if reverse:
            st["reverse"] = {"tag": reverse}
        return {"tag": tag, "protocol": "vless", "settings": st, "streamSettings": stream}

    rules = [{"type": "field", "inboundTag": ["probe-in"], "outboundTag": "probe"}]
    for name, lport, host, tport in doors(cfg):
        rules.append({"type": "field", "inboundTag": ["r-in"], "ip": ["%s/32" % host],
                      "port": str(tport), "network": "tcp", "outboundTag": "direct"})
    rules += [{"type": "field", "inboundTag": ["r-in"], "ip": ["geoip:private"], "outboundTag": "block"},
              {"type": "field", "inboundTag": ["r-in"], "outboundTag": "direct"}]
    return json.dumps({
        "log": {"loglevel": "warning", "access": "none"},
        "inbounds": [{"tag": "probe-in", "listen": "127.0.0.1", "port": 7777, "protocol": "tunnel",
                      "settings": {"address": "127.0.0.1", "port": ECHO_PORT, "network": "tcp"}}],
        # Xray 26.x: freedom по умолчанию блокирует частные адреса (127.0.0.1…) для трафика reverse-входа —
        # «дверь» к SSH VPS-2 и проба иначе получают «blocked target IP». Защита остаётся в маршрутах r-in:
        # только адреса дверей идут в direct, geoip:private → block (проверено xray run на localhost).
        "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {"ipsBlocked": []}},
                      {"tag": "block", "protocol": "blackhole"},
                      vless("bridge", cfg[v["uuid"]], reverse="r-in"),
                      vless("probe", cfg[v["probe"]])],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }, indent=2) + "\n"


def vps2_conf(cfg, order):
    keys = ["PUBLIC_IP", "TRANSPORT_FORCE", "HY2_PORT", "HY2O_PORT", "RXH_PORT", "RXH2_PORT",
            "XRAY_VER", "HY2_VER", "SSH_PUB"]
    lines = ["# /etc/rp/rp2.conf — параметры VPS-2 (создан блоком из VPS-1)",
             'TRANSPORT_ORDER="%s"' % " ".join(order)]
    for k in keys:
        lines.append('%s="%s"' % (k, cfg.get(k, "1" if k == "DISABLE_IPV6" else "")))
    # 10..15 s default: bounded health cadence; full transport tests unchanged.
    # Keep values in rp2.conf to avoid changes silently reverting on rp push.
    def watch_interval(key, default):
        try:
            n = int(cfg.get(key, str(default)))
        except ValueError:
            die("%s: требуется целое количество секунд" % key)
        if n < 5 or n > 120:
            die("%s: допустимо 5..120 секунд" % key)
        return n
    wmin = watch_interval("WATCH_MIN", 10)
    wmax = watch_interval("WATCH_MAX", 15)
    if wmax < wmin:
        die("WATCH_MAX должен быть >= WATCH_MIN")
    lines += [f'WATCH_MIN="{wmin}"', f'WATCH_MAX="{wmax}"']
    lines.append('ECHO_PORT="%d"' % ECHO_PORT)
    return "\n".join(lines) + "\n"


def build_bundle(cfg, outdir, extra_files):
    """tar.gz с файлами VPS-2. extra_files: {путь_в_архиве: (байты, режим)} от rp.sh (юниты, скрипты)."""
    order = transports(cfg)
    files = {
        "etc/rp/rp2.conf": (vps2_conf(cfg, order).encode(), 0o640),
    }
    if any(t in order for t in ("hy2-wg", "hy2o-wg")):
        files["etc/rp/rp-wg.conf"] = (wg_exit_client(cfg).encode(), 0o600)
    if "hy2-wg" in order:
        files["etc/rp/hy2.yaml"] = (hy2_client(cfg).encode(), 0o640)
    if "hy2o-wg" in order:
        files["etc/rp/hy2o.yaml"] = (hy2_client(cfg, True).encode(), 0o640)
    if "reality-xhttp" in order:
        files["etc/rp/xray-xhttp.json"] = (xray_client(cfg, "reality-xhttp").encode(), 0o640)
    if "reality-xhttp2" in order:
        files["etc/rp/xray-xhttp2.json"] = (xray_client(cfg, "reality-xhttp2").encode(), 0o640)
    files.update(extra_files)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name in sorted(files):
            data, mode = files[name]
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(data))
    raw = buf.getvalue()
    write_atomic(os.path.join(outdir, "bundle.tgz"), raw)
    return hashlib.sha256(raw).hexdigest(), order


# ── Команды ─────────────────────────────────────────────────────────────

def cmd_render(args):
    """render <stage-dir> — все конфиги VPS-1 + манифест (файл|путь|режим|владелец|действие)."""
    if len(args) != 1:
        die("render: нужен каталог")
    stage = args[0]
    cfg = load_conf()
    cfg["ETC"] = ETC
    order = transports(cfg)
    man = []

    def put(name, text, path, mode, owner, action):
        write_atomic(os.path.join(stage, name), text, 0o600)
        man.append("%s|%s|%s|%s|%s" % (name, path, mode, owner, action))

    put("xray.json", xray_server(cfg), "/etc/rp/xray.json", "0640", "root:rp", "restart:rp-xray")
    put("wg0.conf", wg0_server(cfg), "/etc/wireguard/wg0.conf", "0600", "root:root", "wg0")
    put("rp.nft", nft_rules(cfg), "/etc/rp/rp.nft", "0644", "root:root", "nft")
    if "hy2-wg" in order:
        put("hy2.yaml", hy2_server(cfg), "/etc/rp/hy2.yaml", "0640", "root:rp", "restart:rp-hy2")
    if "hy2o-wg" in order:
        put("hy2o.yaml", hy2_server(cfg, True), "/etc/rp/hy2o.yaml", "0640", "root:rp", "restart:rp-hy2o")
    if has_hy2(order):
        put("wg-exit.conf", wg_exit_server(cfg), "/etc/wireguard/wg-exit.conf", "0600", "root:root", "wgexit")
    sys.stdout.write("\n".join(man) + "\n")


def cmd_client(args):
    if len(args) != 1:
        die("client: нужно имя")
    sys.stdout.write(client_conf(load_conf(), args[0]))


def cmd_bundle(args):
    """bundle <outdir> <extra-dir> — пакет VPS-2; extra-dir: каталог с юнитами/скриптами (путь внутри = путь в архиве)."""
    if len(args) != 2:
        die("bundle: нужны каталоги")
    outdir, extra = args
    extra_files = {}
    for root, _, names in os.walk(extra):
        for n in names:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, extra)
            with open(p, "rb") as f:
                extra_files[rel] = (f.read(), 0o755 if rel.startswith("usr/") else 0o644)
    cfg = load_conf()
    h, order = build_bundle(cfg, outdir, extra_files)
    sys.stdout.write("%s %s\n" % (h, " ".join(order)))


def cmd_next_ip(args):
    cfg = load_conf()
    net = ipaddress.ip_network(cfg.get("WG_NET", "10.66.0.0/24"))
    used = {c["ip"] for c in read_clients()} | {cfg.get("WG_NET_GW", "")}
    for h in list(net.hosts())[1:]:
        if str(h) not in used:
            print(h)
            return
    die("в подсети %s нет свободных адресов" % net)


def cmd_dns(args):
    """dns — адреса DoH из DNS_REMOTE по одному в строке (пресеты раскрыты)."""
    for u in dns_remote(load_conf()):
        print(u)


def cmd_chunk(args):
    """chunk <файл-b64> <размер> <каталог> — делит строку base64 на части."""
    src, size, outdir = args[0], int(args[1]), args[2]
    with open(src, encoding="ascii") as f:
        data = f.read().strip()
    n = 0
    for i in range(0, len(data), size):
        n += 1
        write_atomic(os.path.join(outdir, "part%02d" % n), data[i:i + size] + "\n", 0o600)
    print(n)


def cmd_probe(args):
    """probe <ip> <порт> — TCP-соединение с меткой выхода (как у Xray), без участия Xray. Для rp diag."""
    ip, port = args[0], int(args[1])
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(6)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, EXIT_MARK)
        t0 = time.time()
        s.connect((ip, port))
        print("ok %d" % int((time.time() - t0) * 1000))
    except socket.timeout:
        print("timeout")
    except OSError as e:
        print("err %s" % (e.strerror or e.errno))
    finally:
        s.close()


def cmd_rpf(args):
    """rpf — счётчик отбрасываний по rp_filter (TcpExt IPReversePathFilter)."""
    try:
        with open("/proc/net/netstat", encoding="ascii") as f:
            rows = [ln.split() for ln in f]
        for i in range(0, len(rows) - 1, 2):
            if rows[i][0] == "TcpExt:" and "IPReversePathFilter" in rows[i]:
                print(rows[i + 1][rows[i].index("IPReversePathFilter")])
                return
    except OSError:
        pass
    print(0)


def cmd_echo(args):
    """Эхо-сервер для проб T3: «DN n» — отдать n байт, «UP n» — принять n байт и ответить «OK n»."""
    import asyncio

    async def handle(r, w):
        try:
            line = (await asyncio.wait_for(r.readline(), 10)).decode("ascii", "ignore").split()
            if len(line) != 2 or not line[1].isdigit() or int(line[1]) > 8 * 1024 * 1024:
                return
            n = int(line[1])
            if line[0] == "DN":
                chunk = b"\x55" * 16384
                while n > 0:
                    w.write(chunk[:min(n, len(chunk))])
                    n -= min(n, len(chunk))
                    await w.drain()
            elif line[0] == "UP":
                while n > 0:
                    b = await asyncio.wait_for(r.read(min(n, 65536)), 20)
                    if not b:
                        return
                    n -= len(b)
                w.write(("OK %s\n" % line[1]).encode())
                await w.drain()
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            w.close()

    async def main():
        srv = await asyncio.start_server(handle, "0.0.0.0", ECHO_PORT)
        async with srv:
            await srv.serve_forever()

    asyncio.run(main())


# ── QR-код (ISO/IEC 18004): байтовый режим, коррекция L, версии 1–14 (до 458 байт) ──────────────
# Свой генератор вместо qrencode: пакет из EPEL на практике ставился десятки минут и падал, а QR нужен
# только для конфигов клиентов WG. Проверено декодированием всех версий (OpenCV).
_QR_L = {1: (26, 7, 1, 19, 0, 0), 2: (44, 10, 1, 34, 0, 0), 3: (70, 15, 1, 55, 0, 0), 4: (100, 20, 1, 80, 0, 0),
         5: (134, 26, 1, 108, 0, 0), 6: (172, 18, 2, 68, 0, 0), 7: (196, 20, 2, 78, 0, 0), 8: (242, 24, 2, 97, 0, 0),
         9: (292, 30, 2, 116, 0, 0), 10: (346, 18, 2, 68, 2, 69), 11: (404, 20, 4, 81, 0, 0),
         12: (466, 24, 2, 92, 2, 93), 13: (532, 26, 4, 107, 0, 0), 14: (581, 30, 3, 115, 1, 116)}
_QR_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
             9: [6, 26, 46], 10: [6, 28, 50], 11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62], 14: [6, 26, 46, 66]}


def _gf_tables():
    exp, log = [0] * 512, [0] * 256
    x = 1
    for i in range(255):
        exp[i] = x
        log[x] = i
        x <<= 1
        if x & 0x100:
            x ^= 0x11d
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


_EXP, _LOG = _gf_tables()


def _rs_ec(data, n):
    gen = [1]
    for i in range(n):
        nxt = [0] * (len(gen) + 1)
        for j, c in enumerate(gen):
            nxt[j] ^= c
            if c:
                nxt[j + 1] ^= _EXP[_LOG[c] + i]
        gen = nxt
    rem = [0] * n
    for b in data:
        f = b ^ rem[0]
        rem = rem[1:] + [0]
        if f:
            for i in range(n):
                if gen[i + 1]:
                    rem[i] ^= _EXP[_LOG[gen[i + 1]] + _LOG[f]]
    return rem


def qr_matrix(data):
    """Матрица модулей (список строк bool) для байтов data."""
    ver = None
    for v in sorted(_QR_L):
        total, ec, b1, d1, b2, d2 = _QR_L[v]
        cap = b1 * d1 + b2 * d2
        need = 4 + (8 if v < 10 else 16) + 8 * len(data)
        if need <= cap * 8:
            ver = v
            break
    if ver is None:
        die("QR: данных слишком много (%d байт, максимум 458)" % len(data))
    total, ec, b1, d1, b2, d2 = _QR_L[ver]
    cap = b1 * d1 + b2 * d2
    bits = [0, 1, 0, 0]
    n = len(data)
    bits += [(n >> i) & 1 for i in range(7 if ver < 10 else 15, -1, -1)]
    for b in data:
        bits += [(b >> i) & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, cap * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    cw = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = [0xEC, 0x11]
    while len(cw) < cap:
        cw.append(pad[(len(cw) - len(bits) // 8) % 2])
    blocks, pos = [], 0
    for cnt, dl in ((b1, d1), (b2, d2)):
        for _ in range(cnt):
            blocks.append(cw[pos:pos + dl])
            pos += dl
    ecs = [_rs_ec(b, ec) for b in blocks]
    out = []
    for i in range(max(len(b) for b in blocks)):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ec):
        for e in ecs:
            out.append(e[i])
    assert len(out) == total, "QR: ошибка таблицы версии %d" % ver
    allbits = []
    for c in out:
        allbits += [(c >> i) & 1 for i in range(7, -1, -1)]

    size = ver * 4 + 17
    mod = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def setfn(x, y, v):
        mod[y][x] = bool(v)
        fn[y][x] = True

    for i in range(size):
        setfn(6, i, i % 2 == 0)
        setfn(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    setfn(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    ap = _QR_ALIGN[ver]
    for i, cx in enumerate(ap):
        for j, cy in enumerate(ap):
            if (i == 0 and j == 0) or (i == 0 and j == len(ap) - 1) or (i == len(ap) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setfn(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)

    def fmt(mask):
        d = (1 << 3) | mask                       # уровень L = 01
        r = d
        for _ in range(10):
            r = (r << 1) ^ ((r >> 9) * 0x537)
        b = ((d << 10) | r) ^ 0x5412
        g = lambda i: (b >> i) & 1
        for i in range(6):
            setfn(8, i, g(i))
        setfn(8, 7, g(6))
        setfn(8, 8, g(7))
        setfn(7, 8, g(8))
        for i in range(9, 15):
            setfn(14 - i, 8, g(i))
        for i in range(8):
            setfn(size - 1 - i, 8, g(i))
        for i in range(8, 15):
            setfn(8, size - 15 + i, g(i))
        setfn(8, size - 8, True)

    fmt(0)
    if ver >= 7:
        r = ver
        for _ in range(12):
            r = (r << 1) ^ ((r >> 11) * 0x1F25)
        b = (ver << 12) | r
        for i in range(18):
            a, c = size - 11 + i % 3, i // 3
            setfn(a, c, (b >> i) & 1)
            setfn(c, a, (b >> i) & 1)
    k = 0
    for right in range(size - 1, 0, -2):
        if right <= 6:                            # вертикальный тайминг (x=6) пропускаем: пары 5-4, 3-2, 1-0
            right -= 1
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = size - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x] and k < len(allbits):
                    mod[y][x] = bool(allbits[k])
                    k += 1
    masks = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
             lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
             lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
             lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0]

    def penalty(m):
        p = 0
        for lines in (m, [list(c) for c in zip(*m)]):
            for row in lines:
                run = 1
                for i in range(1, size):
                    if row[i] == row[i - 1]:
                        run += 1
                    else:
                        if run >= 5:
                            p += 3 + run - 5
                        run = 1
                if run >= 5:
                    p += 3 + run - 5
                s = "".join("1" if v else "0" for v in row)
                p += 40 * (s.count("10111010000") + s.count("00001011101"))
        for y in range(size - 1):
            for x in range(size - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    p += 3
        dark = sum(v for row in m for v in row)
        p += 10 * int(abs(dark * 100 / (size * size) - 50) / 5)
        return p

    best, bm = None, 0
    base = [row[:] for row in mod]
    for mk in range(8):
        m = [row[:] for row in base]
        for y in range(size):
            for x in range(size):
                if not fn[y][x] and masks[mk](x, y):
                    m[y][x] = not m[y][x]
        mod = m
        fmt(mk)
        pen = penalty(mod)
        if best is None or pen < best:
            best, bm = pen, mk
    m = [row[:] for row in base]
    for y in range(size):
        for x in range(size):
            if not fn[y][x] and masks[bm](x, y):
                m[y][x] = not m[y][x]
    mod = m
    fmt(bm)
    return mod


def qr_text(data, quiet=2):
    """QR для терминала: чёрные модули на белом фоне (не зависит от темы), по две строки в знаке."""
    m = qr_matrix(data)
    n = len(m)
    q = quiet
    full = [[False] * (n + 2 * q) for _ in range(q)] + \
           [[False] * q + row + [False] * q for row in m] + [[False] * (n + 2 * q) for _ in range(q)]
    if len(full) % 2:
        full.append([False] * (n + 2 * q))
    lines = []
    for y in range(0, len(full), 2):
        s = "".join({(True, True): "█", (True, False): "▀", (False, True): "▄", (False, False): " "}[(t, b)]
                     for t, b in zip(full[y], full[y + 1]))
        lines.append("\x1b[30;47m%s\x1b[0m" % s)
    return "\n".join(lines)


def cmd_qr(args):
    """qr [файл] — QR из файла или stdin."""
    data = open(args[0], "rb").read() if args else sys.stdin.buffer.read()
    print(qr_text(data.rstrip(b"\n")))


def _pb_varint(data, pos, end):
    v, shift = 0, 0
    for _ in range(10):
        if pos >= end: raise ValueError("truncated varint")
        b = data[pos]; pos += 1
        v |= (b & 127) << shift
        if b < 128: return v, pos
        shift += 7
    raise ValueError("varint too long")


def _pb_fields(data, start=0, end=None):
    end = len(data) if end is None else end
    p = start
    while p < end:
        k, p = _pb_varint(data, p, end)
        field, wire = k >> 3, k & 7
        if not field: raise ValueError("field zero")
        if wire == 0: val, p = _pb_varint(data, p, end)
        elif wire == 1:
            val = (p, p + 8)
            p += 8
        elif wire == 5:
            val = (p, p + 4)
            p += 4
        elif wire == 2:
            ln, p = _pb_varint(data, p, end)
            val = (p, p + ln)
            p += ln
        else: raise ValueError("unsupported protobuf wire type %d" % wire)
        if p > end: raise ValueError("truncated protobuf field")
        yield field, wire, val


def _geo_entries(path, requested):
    # The outer GeoSiteList field #1 is repeated GeoSite; country_code #1,
    # repeated domain messages #2; domain type #1, value #2.
    import mmap
    result = {key.lower(): [] for key in requested}
    with open(path, 'rb') as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            for field, wire, span in _pb_fields(data):
                if field != 1 or wire != 2: continue
                a, b = span; code = None
                for sf, sw, sv in _pb_fields(data, a, b):
                    if sf == 1 and sw == 2:
                        code = data[sv[0]:sv[1]].decode('ascii', 'replace').lower()
                        break
                if code not in result: continue
                for sf, sw, sv in _pb_fields(data, a, b):
                    if sf != 2 or sw != 2: continue
                    typ, value = None, None
                    for df, dw, dv in _pb_fields(data, sv[0], sv[1]):
                        if df == 1 and dw == 0: typ = dv
                        if df == 2 and dw == 2:
                            value = data[dv[0]:dv[1]].decode('utf-8', 'replace').lower()
                    if typ in (0, 1, 2, 3) and value:
                        result[code].append((typ, value))
    return result


def _matches_geo(domain, entries):
    for typ, value in entries:
        if typ == 3 and domain == value: return True
        if typ == 2 and (domain == value or domain.endswith('.' + value)): return True
        if typ == 0 and value in domain: return True
        if typ == 1:
            try:
                if re.search(value, domain): return True
            except re.error:
                raise ValueError("bad regex in geosite")
    return False


def cmd_verify_geo(args):
    if len(args) != 1: die("verify-geo PATH")
    path = args[0]
    if not os.path.isfile(path) or not (1048576 <= os.stat(path).st_size <= 367001600):
        die("geosite.dat имеет недопустимый размер")
    cfg = load_conf()
    ru_sets = [s for s in cfg.get("RU_SETS", "category-ru yandex vk category-gov-ru 2gis").split() if s]
    needed = set(ru_sets) | {'ru-blocked'}
    try:
        groups = _geo_entries(path, needed)
    except (OSError, ValueError) as exc:
        die("ошибка структуры GeoSiteList: %s" % exc)
    missing = [name for name in needed if not groups.get(name)]
    if missing: die("в geosite.dat отсутствуют категории: %s" % ', '.join(sorted(missing)))
    blockers = groups['ru-blocked']
    for domain in RU_DIRECT_CORE:
        if _matches_geo(domain, blockers):
            die("критический российский домен %s включён в ru-blocked: обновление отменено" % domain)
    for domain in RU_FOREIGN_GUARD:
        if any(_matches_geo(domain, groups[name]) for name in ru_sets):
            die("зарубежный контрольный домен %s попал в RU-наборы: обновление отменено" % domain)
    # Core remains a fallback; do not reject an update just because an upstream
    # category removed a Russian domain. Audit only, not a circular requirement.
    uncovered = [d for d in RU_DIRECT_CORE if not any(_matches_geo(d, groups[n]) for n in ru_sets)]
    print("geo-check OK: %d Russian domains protected, %d foreign controls, %d guard entries" %
          (len(RU_DIRECT_CORE), len(RU_FOREIGN_GUARD), len(blockers)))
    if uncovered:
        print("notice: built-in direct core covers %d names absent upstream: %s" %
              (len(uncovered), ', '.join(uncovered[:8])))


def cmd_serve(args):
    """serve ПОРТ ТОКЕН ФАЙЛ СЕРТ КЛЮЧ ТТЛ_СЕК — одноразовая отдача файла по HTTPS (блок для VPS-2).
    Отдаёт только GET /ТОКЕН и только один раз; результат («ok»/«timeout») пишет в файл result рядом."""
    import hmac
    import http.server
    import socketserver
    import ssl
    import threading
    if len(args) != 6:
        die("serve ПОРТ ТОКЕН ФАЙЛ СЕРТ КЛЮЧ ТТЛ")
    port, token, path, crt, key, ttl = args[0], args[1], args[2], args[3], args[4], int(args[5])
    if ttl <= 0:
        die("TTL должен быть положительным")
    resf = os.path.join(os.path.dirname(os.path.abspath(path)), "result")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(crt, key)
    done, lock, state = threading.Event(), threading.Lock(), {"taken": False}
    expires = time.monotonic() + ttl

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        timeout = 15

        def setup(self):
            self.request.do_handshake()          # рукопожатие в потоке соединения: сканер не вешает сервер
            super().setup()

        def do_GET(self):
            if not hmac.compare_digest(self.path.encode(), ("/" + token).encode()):
                time.sleep(1)
                self.send_error(404)
                return
            with lock:
                if state["taken"] or time.monotonic() >= expires:
                    self.send_error(404)
                    return
                state["taken"] = True
            try:
                with open(path, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
            except Exception:
                with lock:
                    state["taken"] = False
                raise
            done.set()

        def log_message(self, *a):
            pass

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

        def get_request(self):
            s, a = self.socket.accept()
            s.settimeout(15)
            return ctx.wrap_socket(s, server_side=True, do_handshake_on_connect=False), a

        def handle_error(self, request, client_address):
            pass

    srv = S(("0.0.0.0", int(port)), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    ok = done.wait(max(0, expires - time.monotonic()))
    time.sleep(1)                                 # дать закончить отправку
    srv.shutdown()
    for p in (path, key):
        try:
            os.remove(p)
        except OSError:
            pass
    with open(resf, "w") as f:
        f.write("ok\n" if ok else "timeout\n")
    sys.exit(0 if ok else 3)


COMMANDS = {"qr": cmd_qr, "serve": cmd_serve, "echo": cmd_echo, "render": cmd_render, "client": cmd_client, "bundle": cmd_bundle,
            "next-ip": cmd_next_ip, "chunk": cmd_chunk, "probe": cmd_probe, "rpf": cmd_rpf, "dns": cmd_dns, "verify-geo": cmd_verify_geo}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("команды: %s" % ", ".join(sorted(COMMANDS)))
    COMMANDS[sys.argv[1]](sys.argv[2:])
