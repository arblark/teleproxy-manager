#!/bin/bash
# Teleproxy Manager v1.1
# bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-manager/main/teleproxy-manager.sh)
set -eo pipefail

GITHUB_REPO="teleproxy/teleproxy"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/teleproxy"
CONFIG_FILE="$CONFIG_DIR/config.toml"
DATA_DIR="/var/lib/teleproxy"
SERVICE_FILE="/etc/systemd/system/teleproxy.service"
SERVICE_USER="teleproxy"
DOCKER_IMAGE="ghcr.io/teleproxy/teleproxy:latest"
DOCKER_NAME="teleproxy"
VER="1.1"

if [ -t 1 ]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
    C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' NC='\033[0m'
    BOLD='\033[1m' UL='\033[4m'
else
    R='' G='' Y='' B='' C='' W='' D='' NC='' BOLD='' UL=''
fi

ok()      { printf "${G} ✓${NC} %s\n" "$1"; }
warn()    { printf "${Y} ⚠${NC} %s\n" "$1"; }
err()     { printf "${R} ✗${NC} %s\n" "$1" >&2; }
die()     { err "$1"; exit 1; }
hdr()     { printf "\n${B}──${NC} ${BOLD}%s${NC}\n" "$1"; }
line()    { printf "${D}  ──────────────────────────────────${NC}\n"; }
pause()   { printf "\n${D}  Enter — продолжить...${NC}"; read -r; }
menu_i()  { printf "  ${G}%2s${NC}) %s\n" "$1" "$2"; }

detect_method() {
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "$DOCKER_NAME"; then
        echo "docker"
    elif systemctl is-enabled teleproxy &>/dev/null 2>&1; then
        echo "binary"
    else
        echo "none"
    fi
}

detect_status() {
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$DOCKER_NAME" && echo "running" || echo "stopped"
    elif [ "$m" = "binary" ]; then
        systemctl is-active --quiet teleproxy 2>/dev/null && echo "running" || echo "stopped"
    else
        echo "none"
    fi
}

get_ip() {
    curl -s -4 --connect-timeout 3 --max-time 5 https://icanhazip.com 2>/dev/null \
        || curl -s -4 --connect-timeout 3 --max-time 5 https://ifconfig.me 2>/dev/null || true
}

check_root() { [ "$(id -u)" -eq 0 ] || die "Запустите от root"; }

check_os() {
    [ -f /etc/os-release ] || die "ОС не определена"
    . /etc/os-release
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             die "Архитектура $(uname -m) не поддерживается" ;;
    esac
}

install_deps() {
    local need=()
    for c in curl jq openssl; do command -v "$c" &>/dev/null || need+=("$c"); done
    command -v xxd &>/dev/null || need+=("xxd")
    [ ${#need[@]} -eq 0 ] && return
    ok "Ставим: ${need[*]}"
    if command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq "${need[@]}" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then dnf install -y -q "${need[@]}" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then yum install -y -q "${need[@]}" >/dev/null 2>&1; fi
}

gen_secret() {
    [ -x "$INSTALL_DIR/teleproxy" ] && "$INSTALL_DIR/teleproxy" generate-secret 2>/dev/null && return
    head -c 16 /dev/urandom | xxd -ps
}

read_val() {
    [ -f "$CONFIG_FILE" ] && grep -m1 "^${1} " "$CONFIG_FILE" 2>/dev/null | sed 's/.*= *//' | tr -d ' ' || true
}

secret_blocks() {
    [ -f "$CONFIG_FILE" ] || return
    awk '/^\[\[secret\]\]/{f=1;b=""} f{b=b$0"\n"} f&&/^$/{print b;f=0} END{if(f)print b}' "$CONFIG_FILE"
}

reload_cfg() {
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        docker exec "$DOCKER_NAME" kill -HUP 1 2>/dev/null && ok "SIGHUP отправлен" || warn "SIGHUP не удался"
    elif [ "$m" = "binary" ]; then
        systemctl reload teleproxy 2>/dev/null && ok "SIGHUP отправлен" || systemctl restart teleproxy 2>/dev/null
    fi
}

# ── Баннер + меню ──────────────────────────────────────────────────────
show_menu() {
    clear
    local st m ip st_txt m_txt
    st=$(detect_status); m=$(detect_method); ip=$(get_ip)
    case "$st" in
        running) st_txt="${G}●${NC} Работает" ;;
        stopped) st_txt="${R}●${NC} Остановлен" ;;
        *)       st_txt="${D}○${NC} Не установлен" ;;
    esac
    case "$m" in docker) m_txt="Docker";; binary) m_txt="Binary";; *) m_txt="—";; esac

    printf "\n"
    printf "  ${BOLD}Teleproxy Manager${NC} ${D}v${VER}${NC}\n"
    printf "  ${D}${st_txt}  │  ${m_txt}  │  ${C}${ip:-?}${NC}\n"
    line

    if [ "$st" = "none" ]; then
        printf "\n"
        menu_i 1 "Установить ${C}Docker${NC} (рекомендуется)"
        menu_i 2 "Установить бинарник + systemd"
    else
        printf "\n  ${D}УПРАВЛЕНИЕ${NC}\n"
        [ "$st" = "running" ] && menu_i 1 "Стоп" || menu_i 1 "Старт"
        menu_i 2 "Рестарт"
        menu_i 3 "Логи"
        menu_i 4 "Статус / метрики"
        menu_i 5 "Ссылки подключения"
        printf "\n  ${D}НАСТРОЙКА${NC}\n"
        menu_i 6 "Секреты"
        menu_i 7 "Fake-TLS"
        menu_i 8 "Порты"
        menu_i 9 "IP-фильтры"
        menu_i 10 "Расширенное"
        menu_i 11 "Конфиг вручную"
        printf "\n  ${D}СИСТЕМА${NC}\n"
        menu_i 12 "Обновить"
        menu_i 13 "Бэкап"
        menu_i 14 "Удалить"
    fi
    printf "\n"
    menu_i 0 "Выход"
    line
    printf "\n  ${BOLD}> ${NC}"
}

# ── Установка Docker ──────────────────────────────────────────────────
install_docker() {
    hdr "Docker-установка"
    if ! command -v docker &>/dev/null; then
        ok "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        ok "Docker есть"
    fi
    setup_interactive docker
    launch_docker
    pause
}

launch_docker() {
    local port stats ee
    port=$(read_val port); stats=$(read_val stats_port); ee=$(read_val domain | tr -d '"')
    port="${port:-443}"; stats="${stats:-8888}"

    local da=(-d --name "$DOCKER_NAME" -p "${port}:${port}" -p "${stats}:${stats}" --ulimit nofile=65536:65536 --restart unless-stopped)
    local ea=(-e "PORT=${port}" -e "STATS_PORT=${stats}" -e "DIRECT_MODE=true")
    [ -n "$ee" ] && ea+=(-e "EE_DOMAIN=${ee}")

    local csv="" idx=1
    while IFS= read -r bl; do
        [ -z "$bl" ] && continue
        local k; k=$(echo "$bl" | grep -oP 'key\s*=\s*"\K[^"]+' || true); [ -z "$k" ] && continue
        local lb; lb=$(echo "$bl" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        local lm; lm=$(echo "$bl" | grep -oP 'limit\s*=\s*\K[0-9]+' || true)
        [ -n "$csv" ] && csv="${csv},"
        csv="${csv}${k}"
        [ -n "$lb" ] && ea+=(-e "SECRET_LABEL_${idx}=${lb}")
        [ -n "$lm" ] && ea+=(-e "SECRET_LIMIT_${idx}=${lm}")
        idx=$((idx + 1))
    done < <(secret_blocks)
    [ -n "$csv" ] && ea+=(-e "SECRET=${csv}")

    docker rm -f "$DOCKER_NAME" &>/dev/null || true
    ok "Запускаем..."
    docker pull "$DOCKER_IMAGE"
    docker run "${da[@]}" "${ea[@]}" -v "${DATA_DIR}:/opt/teleproxy/data" "$DOCKER_IMAGE"
    sleep 3
    docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME" && ok "Работает" || { err "Не запустился:"; docker logs "$DOCKER_NAME" 2>&1 | tail -10; }
    echo ""; show_links_inner
}

# ── Установка бинарник ─────────────────────────────────────────────────
install_binary() {
    hdr "Бинарная установка"
    [ -d /run/systemd/system ] || die "Нет systemd — используйте Docker"
    local arch; arch=$(detect_arch)
    ok "Скачиваем ($arch)..."
    local tmp; tmp=$(mktemp)
    curl -fsSL -o "$tmp" "https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${arch}" || die "Ошибка загрузки"
    chmod +x "$tmp"; mv "$tmp" "$INSTALL_DIR/teleproxy"
    id "$SERVICE_USER" &>/dev/null || { useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; ok "Юзер $SERVICE_USER"; }
    mkdir -p "$CONFIG_DIR" "$DATA_DIR"; chown "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR"

    setup_interactive binary

    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Teleproxy MTProto Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=teleproxy
ExecStart=/usr/local/bin/teleproxy --config /etc/teleproxy/config.toml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/teleproxy /var/lib/teleproxy
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now teleproxy
    sleep 2
    systemctl is-active --quiet teleproxy && { ok "Сервис работает"; echo ""; show_links_inner; } || { err "Не стартанул:"; journalctl -u teleproxy --no-pager -n 15; }
    pause
}

# ── Интерактивная настройка ────────────────────────────────────────────
setup_interactive() {
    local mode="$1"
    hdr "Настройка"

    printf "  ${C}Порт${NC} [${W}443${NC}]: "; read -r p; p="${p:-443}"
    printf "  ${C}Порт статистики${NC} [${W}8888${NC}]: "; read -r sp; sp="${sp:-8888}"
    local cpus; cpus=$(nproc 2>/dev/null || echo 1)
    printf "  ${C}Воркеры${NC} [${W}${cpus}${NC}]: "; read -r w; w="${w:-$cpus}"
    printf "  ${C}Fake-TLS?${NC} [${W}Y${NC}/n]: "; read -r tls
    local dom=""
    [[ "${tls,,}" != "n" ]] && { printf "  ${C}Домен${NC} [${W}www.google.com${NC}]: "; read -r dom; dom="${dom:-www.google.com}"; }
    printf "  ${C}Секретов${NC} [${W}1${NC}] (1-16): "; read -r sc; sc="${sc:-1}"
    [[ "$sc" =~ ^[0-9]+$ ]] && [ "$sc" -ge 1 ] && [ "$sc" -le 16 ] || { warn "Используем 1"; sc=1; }

    local -a keys=() lbls=() lims=()
    for ((i=1;i<=sc;i++)); do
        local s; s=$(gen_secret); keys+=("$s")
        if [ "$sc" -gt 1 ]; then
            printf "  ${D}#${i}${NC} ${W}${s}${NC}  метка [secret_${i}]: "; read -r l; lbls+=("${l:-secret_${i}}")
            printf "     лимит [∞]: "; read -r li; lims+=("$li")
        else
            printf "  ${D}Секрет:${NC} ${W}${s}${NC}\n"; lbls+=("default"); lims+=("")
        fi
    done

    mkdir -p "$CONFIG_DIR"
    {
        echo "# Teleproxy — $(date '+%Y-%m-%d %H:%M')"
        echo "port = $p"
        echo "stats_port = $sp"
        echo "http_stats = true"
        echo "workers = $w"
        echo "direct = true"
        [ "$mode" = "binary" ] && echo "user = \"$SERVICE_USER\""
        [ -n "$dom" ] && echo "domain = \"$dom\""
        echo ""
        for ((i=0;i<${#keys[@]};i++)); do
            echo "[[secret]]"
            echo "key = \"${keys[$i]}\""
            [ -n "${lbls[$i]}" ] && echo "label = \"${lbls[$i]}\""
            [ -n "${lims[$i]}" ] && echo "limit = ${lims[$i]}"
            echo ""
        done
    } > "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    ok "Конфиг: $CONFIG_FILE"
}

# ── Управление ─────────────────────────────────────────────────────────
do_start()   { local m; m=$(detect_method); hdr "Старт"; [ "$m" = docker ] && docker start "$DOCKER_NAME" || systemctl start teleproxy; sleep 1; ok "OK"; pause; }
do_stop()    { local m; m=$(detect_method); hdr "Стоп";  [ "$m" = docker ] && docker stop "$DOCKER_NAME"  || systemctl stop teleproxy;  ok "OK"; pause; }
do_restart() { local m; m=$(detect_method); hdr "Рестарт"; [ "$m" = docker ] && docker restart "$DOCKER_NAME" || systemctl restart teleproxy; sleep 1; ok "OK"; pause; }

do_logs() {
    hdr "Логи (Ctrl+C выход)"
    local m; m=$(detect_method)
    [ "$m" = docker ] && docker logs -f --tail 50 "$DOCKER_NAME" || journalctl -u teleproxy -f --no-pager -n 50
}

do_status() {
    hdr "Статус"
    local m; m=$(detect_method)
    if [ "$m" = docker ]; then
        docker ps -a --filter "name=$DOCKER_NAME" --format "table {{.Status}}\t{{.Ports}}" | head -3
        docker stats --no-stream --format "  CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}  IO: {{.NetIO}}" "$DOCKER_NAME" 2>/dev/null || true
    else
        systemctl status teleproxy --no-pager 2>/dev/null | head -12
    fi
    local sp; sp=$(read_val stats_port); sp="${sp:-8888}"
    echo ""
    printf "  ${W}HTTP /stats:${NC}\n"
    curl -sf "http://127.0.0.1:${sp}/stats" 2>/dev/null | head -20 || warn "/stats недоступен — проверьте http_stats = true в конфиге"
    echo ""
    printf "  ${D}Prometheus:${NC} http://<IP>:${sp}/stats  ${D}(Accept: text/plain)${NC}\n"
    printf "  ${D}QR/ссылки:${NC} http://<IP>:${sp}/link\n"
    pause
}

# ── Ссылки подключения ─────────────────────────────────────────────────
show_links_inner() {
    local ip port dom
    ip=$(get_ip); ip="${ip:-<IP>}"
    [ -f "$CONFIG_FILE" ] && { port=$(read_val port); dom=$(read_val domain | tr -d '"'); }
    port="${port:-443}"
    local m; m=$(detect_method)
    [ "$m" = docker ] && { docker logs "$DOCKER_NAME" 2>&1 | grep -E "(tg://|t\.me/proxy)" | tail -16; echo ""; }

    while IFS= read -r bl; do
        [ -z "$bl" ] && continue
        local k lb fs
        k=$(echo "$bl" | grep -oP 'key\s*=\s*"\K[^"]+' || true); [ -z "$k" ] && continue
        lb=$(echo "$bl" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        if [ -n "$dom" ]; then fs="ee${k}$(printf '%s' "$dom" | xxd -ps | tr -d '\n')"; else fs="$k"; fi
        [ -n "$lb" ] && printf "  ${W}[${lb}]${NC} "
        printf "${C}tg://proxy?server=${ip}&port=${port}&secret=${fs}${NC}\n"
        printf "  ${D}https://t.me/proxy?server=${ip}&port=${port}&secret=${fs}${NC}\n"
    done < <(secret_blocks)
    local sp; sp=$(read_val stats_port); sp="${sp:-8888}"
    printf "\n  ${D}QR:${NC} http://${ip}:${sp}/link\n"
}

do_links() { hdr "Ссылки подключения"; show_links_inner; pause; }

# ── Секреты ────────────────────────────────────────────────────────────
do_secrets() {
    while true; do
        hdr "Секреты"
        [ -f "$CONFIG_FILE" ] && {
            local i=1
            while IFS= read -r bl; do
                [ -z "$bl" ] && continue
                local k lb lm
                k=$(echo "$bl" | grep -oP 'key\s*=\s*"\K[^"]+' || true); [ -z "$k" ] && continue
                lb=$(echo "$bl" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
                lm=$(echo "$bl" | grep -oP 'limit\s*=\s*\K[0-9]+' || true)
                printf "  ${G}%d${NC}) ${W}%.16s...${NC}" "$i" "$k"
                [ -n "$lb" ] && printf " ${D}[${lb}]${NC}"
                [ -n "$lm" ] && printf " ${Y}≤${lm}${NC}"
                printf "\n"; i=$((i+1))
            done < <(secret_blocks)
        }
        echo ""
        menu_i a "Добавить"; menu_i d "Удалить"; menu_i r "Перегенерировать"; menu_i 0 "Назад"
        printf "\n  > "; read -r ch
        case "$ch" in
            a) local s; s=$(gen_secret)
               printf "  Метка: "; read -r lb; lb="${lb:-new}"
               printf "  Лимит [∞]: "; read -r lm
               { echo ""; echo "[[secret]]"; echo "key = \"$s\""; echo "label = \"$lb\""; [ -n "$lm" ] && echo "limit = $lm"; echo ""; } >> "$CONFIG_FILE"
               ok "Добавлен: $s"; reload_cfg ;;
            d) printf "  Номер: "; read -r n; [[ "$n" =~ ^[0-9]+$ ]] || continue
               local t; t=$(mktemp)
               awk -v n="$n" 'BEGIN{c=0;s=0} /^\[\[secret\]\]/{c++;if(c==n){s=1;next}} s&&/^$/{s=0;next} s&&/^\[/{s=0} !s' "$CONFIG_FILE" > "$t"
               mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"; ok "#${n} удалён"; reload_cfg ;;
            r) local t; t=$(mktemp); local ins=0
               while IFS= read -r ln; do
                   [[ "$ln" =~ ^\[\[secret\]\] ]] && ins=1
                   if [ "$ins" -eq 1 ] && [[ "$ln" =~ ^key ]]; then echo "key = \"$(gen_secret)\"" >> "$t"; else echo "$ln" >> "$t"; fi
                   [ "$ins" -eq 1 ] && { [[ -z "$ln" || "$ln" =~ ^\[ ]] && ins=0; }
               done < "$CONFIG_FILE"
               mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"; ok "Перегенерированы"; reload_cfg ;;
            0) return ;;
        esac
    done
}

# ── Fake-TLS ──────────────────────────────────────────────────────────
do_faketls() {
    hdr "Fake-TLS"
    local cur; cur=$(read_val domain | tr -d '"')
    [ -n "$cur" ] && printf "  Текущий: ${W}${cur}${NC}\n" || printf "  ${D}Отключён${NC}\n"
    menu_i 1 "Включить/изменить"; menu_i 2 "Отключить"; menu_i 0 "Назад"
    printf "\n  > "; read -r ch
    case "$ch" in
        1) printf "  Домен [www.google.com]: "; read -r d; d="${d:-www.google.com}"
           grep -q '^domain ' "$CONFIG_FILE" 2>/dev/null && sed -i "s|^domain .*|domain = \"$d\"|" "$CONFIG_FILE" || sed -i "/^port /a domain = \"$d\"" "$CONFIG_FILE"
           ok "$d"; reload_cfg ;;
        2) sed -i '/^domain /d' "$CONFIG_FILE"; ok "Отключён"; reload_cfg ;;
    esac
    pause
}

# ── Порты ──────────────────────────────────────────────────────────────
do_ports() {
    hdr "Порты"
    local cp cs; cp=$(read_val port); cs=$(read_val stats_port)
    printf "  ${C}Клиент${NC} [${W}${cp:-443}${NC}]: "; read -r np; np="${np:-${cp:-443}}"
    printf "  ${C}Статистика${NC} [${W}${cs:-8888}${NC}]: "; read -r ns; ns="${ns:-${cs:-8888}}"
    sed -i "s|^port = .*|port = $np|;s|^stats_port = .*|stats_port = $ns|" "$CONFIG_FILE"
    ok "Порты: $np / $ns"
    local m; m=$(detect_method)
    [ "$m" = docker ] && { warn "Docker: нужно пересоздать контейнер"; printf "  Да? [Y/n]: "; read -r y; [[ "${y,,}" != "n" ]] && recreate_docker; } || reload_cfg
    pause
}

# ── IP-фильтры ────────────────────────────────────────────────────────
do_ipfilter() {
    hdr "IP-фильтрация"
    menu_i 1 "Блоклист"; menu_i 2 "Вайтлист"; menu_i 3 "Сети для /stats"; menu_i 0 "Назад"
    printf "\n  > "; read -r ch
    case "$ch" in
        1) printf "  Файл блоклиста: "; read -r f; [ -n "$f" ] && { _set_kv ip_blocklist "\"$f\""; reload_cfg; } ;;
        2) printf "  Файл вайтлиста: "; read -r f; [ -n "$f" ] && { _set_kv ip_allowlist "\"$f\""; reload_cfg; } ;;
        3) printf "  CIDR через запятую: "; read -r n; [ -n "$n" ] && {
           local fmt; fmt=$(echo "$n" | sed 's/,/", "/g'); _set_kv stats_allow_net "[\"$fmt\"]"; reload_cfg; } ;;
        0) return ;;
    esac
    pause
}

_set_kv() {
    grep -q "^${1} " "$CONFIG_FILE" 2>/dev/null && sed -i "s|^${1} .*|${1} = ${2}|" "$CONFIG_FILE" || echo "${1} = ${2}" >> "$CONFIG_FILE"
    ok "${1} обновлён"
}

# ── Расширенные ────────────────────────────────────────────────────────
do_advanced() {
    while true; do
        hdr "Расширенные"
        menu_i 1 "PROXY Protocol v1/v2"
        menu_i 2 "SOCKS5 upstream"
        menu_i 3 "Bind IP"
        menu_i 4 "IPv6"
        menu_i 5 "DC Override"
        menu_i 6 "DC Probes (интервал)"
        menu_i 7 "Proxy Tag (@MTProxybot)"
        menu_i 8 "Макс. соединений"
        menu_i 9 "Квоты/rate limit секретов"
        menu_i 0 "Назад"
        printf "\n  > "; read -r ch
        case "$ch" in
            1) _toggle proxy_protocol "PROXY Protocol" ;;
            2) printf "  SOCKS5 (host:port): "; read -r v; _str socks5 "$v" ;;
            3) printf "  Bind IP: "; read -r v; _str bind "$v" ;;
            4) _toggle ipv6 "IPv6" ;;
            5) _dc_override ;;
            6) printf "  Интервал сек [30]: "; read -r v; _int dc_probe_interval "${v:-30}" ;;
            7) printf "  Tag: "; read -r v; _str proxy_tag "$v" ;;
            8) printf "  Макс [60000]: "; read -r v; _int maxconn "${v:-60000}" ;;
            9) _secret_adv ;;
            0) return ;;
        esac
    done
}

_toggle() {
    local cur; cur=$(read_val "$1")
    [ "$cur" = "true" ] && { sed -i "/^${1} /d" "$CONFIG_FILE"; ok "$2 выкл"; } || { _set_kv "$1" "true"; ok "$2 вкл"; }
    reload_cfg; pause
}

_str() {
    [ -z "$2" ] && { sed -i "/^${1} /d" "$CONFIG_FILE"; ok "${1} удалён"; } || _set_kv "$1" "\"$2\""
    reload_cfg; pause
}

_int() {
    [ "$2" = "0" ] || [ -z "$2" ] && { sed -i "/^${1} /d" "$CONFIG_FILE"; ok "${1} удалён"; } || _set_kv "$1" "$2"
    reload_cfg; pause
}

_dc_override() {
    hdr "DC Override"
    printf "  ${D}Формат: DC:HOST:PORT,...${NC}\n  > "; read -r inp
    sed -i '/^\[\[dc_override\]\]/,/^$/d' "$CONFIG_FILE"
    [ -z "$inp" ] && { ok "Очищено"; reload_cfg; pause; return; }
    IFS=',' read -ra dcs <<< "$inp"
    for dc in "${dcs[@]}"; do
        dc=$(echo "$dc" | tr -d ' '); IFS=':' read -r did dh dp <<< "$dc"
        { echo ""; echo "[[dc_override]]"; echo "dc = $did"; echo "host = \"$dh\""; echo "port = $dp"; } >> "$CONFIG_FILE"
    done
    ok "Настроено"; reload_cfg; pause
}

_secret_adv() {
    hdr "Квоты секретов"
    local i=1
    while IFS= read -r bl; do
        [ -z "$bl" ] && continue
        local k lb; k=$(echo "$bl"|grep -oP 'key\s*=\s*"\K[^"]+'||true); [ -z "$k" ] && continue
        lb=$(echo "$bl"|grep -oP 'label\s*=\s*"\K[^"]+'||true)
        printf "  ${G}%d${NC}) %.16s... ${D}[${lb}]${NC}\n" "$i" "$k"; i=$((i+1))
    done < <(secret_blocks)
    printf "\n  Номер: "; read -r n; [[ "$n" =~ ^[0-9]+$ ]] || return
    printf "  Квота байт [∞]: "; read -r q
    printf "  Rate limit (100mb/h) [∞]: "; read -r rl
    printf "  Макс IP [∞]: "; read -r mi
    printf "  Expires (unix/ISO) [∞]: "; read -r ex

    local t; t=$(mktemp); local cnt=0 ins=0 done=0
    while IFS= read -r ln; do
        [[ "$ln" =~ ^\[\[secret\]\] ]] && { cnt=$((cnt+1)); ins=1; }
        if [ "$ins" -eq 1 ] && [ "$cnt" -eq "$n" ] && [ "$done" -eq 0 ] && [[ -z "$ln" || "$ln" =~ ^\[ ]]; then
            [ -n "$q" ] && echo "quota = $q" >> "$t"
            [ -n "$rl" ] && echo "rate_limit = \"$rl\"" >> "$t"
            [ -n "$mi" ] && echo "max_ips = $mi" >> "$t"
            [ -n "$ex" ] && echo "expires = $ex" >> "$t"
            done=1; ins=0
        fi
        echo "$ln" >> "$t"
    done < "$CONFIG_FILE"
    [ "$ins" -eq 1 ] && [ "$cnt" -eq "$n" ] && [ "$done" -eq 0 ] && {
        [ -n "$q" ] && echo "quota = $q" >> "$t"
        [ -n "$rl" ] && echo "rate_limit = \"$rl\"" >> "$t"
        [ -n "$mi" ] && echo "max_ips = $mi" >> "$t"
        [ -n "$ex" ] && echo "expires = $ex" >> "$t"
    }
    mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    ok "Обновлено"; reload_cfg; pause
}

# ── Конфиг вручную ─────────────────────────────────────────────────────
do_edit() {
    [ -f "$CONFIG_FILE" ] || { err "Нет конфига"; pause; return; }
    hdr "Конфиг ($CONFIG_FILE)"
    cat -n "$CONFIG_FILE"; echo ""
    local ed; ed="${EDITOR:-$(command -v nano||command -v vim||command -v vi||true)}"
    [ -n "$ed" ] && { printf "  Открыть ($ed)? [Y/n]: "; read -r y; [[ "${y,,}" != "n" ]] && { "$ed" "$CONFIG_FILE"; reload_cfg; }; } || warn "Редактор не найден"
    pause
}

# ── Обновление ─────────────────────────────────────────────────────────
do_update() {
    hdr "Обновление"
    local m; m=$(detect_method)
    if [ "$m" = docker ]; then
        docker pull "$DOCKER_IMAGE"; recreate_docker; ok "Обновлено"
    elif [ "$m" = binary ]; then
        local a; a=$(detect_arch)
        systemctl stop teleproxy 2>/dev/null || true
        local t; t=$(mktemp); curl -fsSL -o "$t" "https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${a}" || die "Ошибка"
        chmod +x "$t"; mv "$t" "$INSTALL_DIR/teleproxy"; systemctl start teleproxy; ok "Обновлено"
    fi
    pause
}

# ── Бэкап ──────────────────────────────────────────────────────────────
do_backup() {
    [ -f "$CONFIG_FILE" ] || { err "Нет конфига"; pause; return; }
    hdr "Бэкап"
    local d="/root/teleproxy-backups"; mkdir -p "$d"
    local f="${d}/config_$(date '+%Y%m%d_%H%M%S').toml"
    cp "$CONFIG_FILE" "$f"; ok "Сохранён: $f"
    ls -1t "$d"/ | head -5
    printf "\n  Восстановить? [y/N]: "; read -r y
    [[ "${y,,}" == "y" ]] && { printf "  Файл: "; read -r rf; [ -f "$rf" ] && { cp "$rf" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"; ok "Восстановлен"; reload_cfg; } || err "Не найден"; }
    pause
}

# ── Удаление ──────────────────────────────────────────────────────────
do_uninstall() {
    hdr "Удаление"
    printf "  ${R}Введите DELETE для подтверждения:${NC} "; read -r c
    [ "$c" != "DELETE" ] && { ok "Отменено"; pause; return; }
    local m; m=$(detect_method)
    [ "$m" = docker ] && { docker stop "$DOCKER_NAME" &>/dev/null; docker rm "$DOCKER_NAME" &>/dev/null; docker rmi "$DOCKER_IMAGE" &>/dev/null; ok "Docker удалён"; }
    [ "$m" = binary ] && { systemctl disable --now teleproxy &>/dev/null; rm -f "$SERVICE_FILE"; systemctl daemon-reload &>/dev/null; rm -f "$INSTALL_DIR/teleproxy"; userdel "$SERVICE_USER" &>/dev/null; ok "Бинарник удалён"; }
    printf "  Удалить конфиги? [y/N]: "; read -r y; [[ "${y,,}" == "y" ]] && { rm -rf "$CONFIG_DIR" "$DATA_DIR"; ok "Конфиги удалены"; }
    ok "Готово"; pause
}

# ── Docker recreate ────────────────────────────────────────────────────
recreate_docker() {
    local port stats ee; port=$(read_val port); stats=$(read_val stats_port); ee=$(read_val domain|tr -d '"')
    port="${port:-443}"; stats="${stats:-8888}"
    local ea=(-e "PORT=${port}" -e "STATS_PORT=${stats}" -e "DIRECT_MODE=true")
    [ -n "$ee" ] && ea+=(-e "EE_DOMAIN=${ee}")
    local csv=""
    while IFS= read -r bl; do
        [ -z "$bl" ] && continue; local k; k=$(echo "$bl"|grep -oP 'key\s*=\s*"\K[^"]+'||true); [ -z "$k" ] && continue
        [ -n "$csv" ] && csv="${csv},"; csv="${csv}${k}"
    done < <(secret_blocks)
    [ -n "$csv" ] && ea+=(-e "SECRET=${csv}")
    docker stop "$DOCKER_NAME" &>/dev/null; docker rm "$DOCKER_NAME" &>/dev/null
    docker run -d --name "$DOCKER_NAME" -p "${port}:${port}" -p "${stats}:${stats}" --ulimit nofile=65536:65536 --restart unless-stopped "${ea[@]}" -v "${DATA_DIR}:/opt/teleproxy/data" "$DOCKER_IMAGE"
    sleep 2; docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME" && ok "Контейнер пересоздан" || err "Ошибка запуска"
}

# ── Main ───────────────────────────────────────────────────────────────
main() {
    check_root; check_os; install_deps
    while true; do
        show_menu; read -r ch
        local st; st=$(detect_status)
        if [ "$st" = "none" ]; then
            case "$ch" in 1) install_docker;; 2) install_binary;; 0) echo ""; exit 0;; *) warn "?"; pause;; esac
        else
            case "$ch" in
                1)  [ "$st" = running ] && do_stop || do_start;;
                2)  do_restart;; 3) do_logs;; 4) do_status;; 5) do_links;;
                6)  do_secrets;; 7) do_faketls;; 8) do_ports;; 9) do_ipfilter;;
                10) do_advanced;; 11) do_edit;; 12) do_update;; 13) do_backup;; 14) do_uninstall;;
                0)  echo ""; exit 0;; *) warn "?"; pause;;
            esac
        fi
    done
}

main "$@"
