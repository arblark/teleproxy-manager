#!/bin/bash
# Teleproxy Manager v1.2
# bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-manager/main/teleproxy-manager.sh)
set -eo pipefail

# Гарантируем что stdin — терминал (нужно при curl|bash и bash <(...))
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec </dev/tty
fi

GITHUB_REPO="teleproxy/teleproxy"
SCRIPT_REPO="arblark/teleproxy-manager"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/teleproxy"
CONFIG_FILE="$CONFIG_DIR/config.toml"
DATA_DIR="/var/lib/teleproxy"
SERVICE_FILE="/etc/systemd/system/teleproxy.service"
SERVICE_USER="teleproxy"
DOCKER_IMAGE="ghcr.io/teleproxy/teleproxy:latest"
DOCKER_NAME="teleproxy"
SELF_PATH="$INSTALL_DIR/teleproxy-manager"
VER="1.2"

# ── Цвета ──────────────────────────────────────────────────────────────
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
line()    { printf "${D}  ──────────────────────────────────────────────${NC}\n"; }
pause()   { printf "\n${D}  Enter — продолжить...${NC}"; read -r; }
menu_i()  { printf "  \033[0;32m%2s\033[0m) %-30s \033[0;90m%s\033[0m\n" "$1" "$2" "$3"; }

# ── Утилиты ────────────────────────────────────────────────────────────
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

check_root() { [ "$(id -u)" -eq 0 ] || die "Запустите от root (sudo)"; }

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
    ok "Установка зависимостей: ${need[*]}"
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

count_secrets() {
    [ -f "$CONFIG_FILE" ] || { echo "0"; return; }
    grep -c '^\[\[secret\]\]' "$CONFIG_FILE" 2>/dev/null | tr -dc '0-9' || echo "0"
}

reload_cfg() {
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        docker exec "$DOCKER_NAME" kill -HUP 1 2>/dev/null && ok "Конфиг перезагружен (SIGHUP)" || warn "Не удалось отправить SIGHUP"
    elif [ "$m" = "binary" ]; then
        systemctl reload teleproxy 2>/dev/null && ok "Конфиг перезагружен (SIGHUP)" || systemctl restart teleproxy 2>/dev/null
    fi
}

# ── Самоустановка скрипта ──────────────────────────────────────────────
self_install() {
    local src="${BASH_SOURCE[0]}"
    local need_download=0
    if [ -z "$src" ] || [ "$src" = "bash" ] || [ "$src" = "/dev/stdin" ] || [[ "$src" == /dev/fd/* ]] || [[ "$src" == /proc/self/fd/* ]]; then
        need_download=1
    elif [ "$(realpath "$src" 2>/dev/null)" != "$(realpath "$SELF_PATH" 2>/dev/null)" ] && [ -f "$src" ] && [ -s "$src" ]; then
        cp "$src" "$SELF_PATH"
        chmod +x "$SELF_PATH"
    else
        need_download=1
    fi
    if [ "$need_download" = "1" ] && { [ ! -x "$SELF_PATH" ] || [ ! -s "$SELF_PATH" ]; }; then
        local tmp; tmp=$(mktemp)
        curl -fsSL "https://raw.githubusercontent.com/${SCRIPT_REPO}/main/teleproxy-manager.sh" -o "$tmp" 2>/dev/null
        if [ -s "$tmp" ]; then
            chmod +x "$tmp"; mv "$tmp" "$SELF_PATH"
        else
            rm -f "$tmp"
        fi
    fi
    [ -x "$SELF_PATH" ] && [ -s "$SELF_PATH" ] && ok "CLI: teleproxy-manager" || true
}

# ── Проверка обновлений скрипта ────────────────────────────────────────
check_script_update() {
    local remote_ver
    remote_ver=$(curl -fsSL --max-time 3 "https://raw.githubusercontent.com/${SCRIPT_REPO}/main/teleproxy-manager.sh" 2>/dev/null | grep -m1 '^VER=' | cut -d'"' -f2 || true)
    if [ -n "$remote_ver" ] && [ "$remote_ver" != "$VER" ]; then
        printf "  ${Y}⬆${NC}  Доступна новая версия скрипта: ${W}v${remote_ver}${NC} ${D}(текущая: v${VER})${NC}\n"
        printf "      Обновить: ${C}teleproxy-manager update-self${NC}\n"
    fi
}

# ── Версия и uptime ────────────────────────────────────────────────────
get_proxy_version() {
    local m out ver; m=$(detect_method)
    if [ "$m" = "binary" ] && [ -x "$INSTALL_DIR/teleproxy" ]; then
        out=$("$INSTALL_DIR/teleproxy" --version 2>&1 || true)
    elif [ "$m" = "docker" ]; then
        out=$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$DOCKER_NAME" 2>/dev/null || true)
        [ "$out" = "<no value>" ] && out=""
        if [ -z "$out" ]; then
            out=$(docker inspect --format '{{ .Config.Image }}' "$DOCKER_NAME" 2>/dev/null || true)
        fi
    fi
    [ -z "$out" ] && return
    ver=$(echo "$out" | { grep -oE '[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?' || true; } | head -1)
    [ -n "$ver" ] && echo "$ver"
}

get_uptime() {
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        local started; started=$(docker inspect -f '{{.State.StartedAt}}' "$DOCKER_NAME" 2>/dev/null || true)
        [ -z "$started" ] && return
        local start_ts now_ts diff
        start_ts=$(date -d "$started" +%s 2>/dev/null || true)
        now_ts=$(date +%s)
        [ -z "$start_ts" ] && return
        diff=$((now_ts - start_ts))
    elif [ "$m" = "binary" ]; then
        local prop; prop=$(systemctl show teleproxy --property=ActiveEnterTimestamp 2>/dev/null || true)
        [ -z "$prop" ] || [ "$prop" = "ActiveEnterTimestamp=" ] && return
        local ts; ts=$(echo "$prop" | cut -d= -f2)
        local start_ts now_ts diff
        start_ts=$(date -d "$ts" +%s 2>/dev/null || true)
        now_ts=$(date +%s)
        [ -z "$start_ts" ] && return
        diff=$((now_ts - start_ts))
    else
        return
    fi
    if [ "$diff" -ge 86400 ]; then echo "$((diff/86400))д $((diff%86400/3600))ч"
    elif [ "$diff" -ge 3600 ]; then echo "$((diff/3600))ч $((diff%3600/60))м"
    elif [ "$diff" -ge 60 ]; then echo "$((diff/60))м"
    else echo "${diff}с"
    fi
}

get_brief_stats() {
    local sp; sp=$(read_val stats_port); sp="${sp:-8888}"
    local raw; raw=$(curl -sf --max-time 2 "http://127.0.0.1:${sp}/stats" 2>/dev/null || true)
    [ -z "$raw" ] && return
    local conns traffic
    conns=$(echo "$raw" | sed -n 's/.*active_connections[= ]*\([0-9]*\).*/\1/p' | head -1 | tr -dc '0-9')
    [ -z "$conns" ] && conns=$(echo "$raw" | sed -n 's/.*current_connections[= ]*\([0-9]*\).*/\1/p' | head -1 | tr -dc '0-9')
    traffic=$(echo "$raw" | sed -n 's/.*total_bytes[= ]*\([0-9]*\).*/\1/p' | head -1 | tr -dc '0-9')
    local result=""
    [ -n "$conns" ] && [ "${conns:-0}" -ne 0 ] 2>/dev/null && result="${conns} подкл."
    if [ -n "$traffic" ] && [ "${traffic:-0}" -gt 0 ] 2>/dev/null; then
        local hr
        if [ "${traffic}" -ge 1073741824 ] 2>/dev/null; then hr="$((traffic/1073741824))GB"
        elif [ "${traffic}" -ge 1048576 ] 2>/dev/null; then hr="$((traffic/1048576))MB"
        elif [ "${traffic}" -ge 1024 ] 2>/dev/null; then hr="$((traffic/1024))KB"
        else hr="${traffic}B"; fi
        [ -n "$result" ] && result="${result}, "
        result="${result}${hr}"
    fi
    echo "$result"
}

# ── Баннер + меню ──────────────────────────────────────────────────────
show_menu() {
    clear 2>/dev/null || true
    local st m ip st_txt m_txt pv up
    st=$(detect_status); m=$(detect_method); ip=$(get_ip)
    pv=$(get_proxy_version)

    case "$st" in
        running) st_txt="${G}● Работает${NC}" ;;
        stopped) st_txt="${R}● Остановлен${NC}" ;;
        *)       st_txt="${D}○ Не установлен${NC}" ;;
    esac
    case "$m" in docker) m_txt="Docker";; binary) m_txt="Binary";; *) m_txt="—";; esac

    printf "\n  ${BOLD}Teleproxy Manager${NC} ${D}v${VER}${NC}"
    [ -n "$pv" ] && printf "  ${D}│  Teleproxy v${pv}${NC}"
    printf "\n  ${st_txt}  ${D}│${NC}  ${W}${m_txt}${NC}  ${D}│${NC}  ${C}${ip:-?}${NC}"
    if [ "$st" = "running" ]; then
        up=$(get_uptime)
        [ -n "$up" ] && printf "  ${D}│  ⏱ ${up}${NC}"
    fi
    printf "\n"
    line

    if [ "$st" = "none" ]; then
        printf "\n  ${D}УСТАНОВКА${NC}\n"
        menu_i 1 "Установить через Docker" "(рекомендуется)"
        menu_i 2 "Установить бинарник + systemd" ""
    else
        local brief_stats sec_count port sp dom workers ftls_txt
        [ "$st" = "running" ] && brief_stats=$(get_brief_stats)
        sec_count=$(count_secrets)
        port=$(read_val port); port="${port:-443}"
        sp=$(read_val stats_port); sp="${sp:-8888}"
        dom=$(read_val domain | tr -d '"')
        workers=$(read_val workers); workers="${workers:-1}"
        [ -n "$dom" ] && ftls_txt="✓ ${dom}" || ftls_txt="отключён"

        local sec_info="${sec_count} шт"
        local limits_count
        limits_count=$(grep -c '^limit ' "$CONFIG_FILE" 2>/dev/null | tr -dc '0-9') || true
        limits_count="${limits_count:-0}"
        [ "$limits_count" -gt 0 ] 2>/dev/null && sec_info="${sec_info}, ${limits_count} с лимитом"

        local up_txt=""
        [ "$st" = "running" ] && { up=$(get_uptime); [ -n "$up" ] && up_txt="работает ${up}"; }
        local stat_txt="${brief_stats:-—}"

        printf "\n  ${D}УПРАВЛЕНИЕ${NC}\n"
        if [ "$st" = "running" ]; then
            menu_i 1 "Остановить прокси" "${up_txt}"
        else
            menu_i 1 "Запустить прокси" ""
        fi
        menu_i 2 "Перезапустить" "${workers} воркер(а)"
        menu_i 3 "Логи" "$([ "$m" = docker ] && echo "docker logs" || echo "journalctl")"
        menu_i 4 "Статус и метрики" "${stat_txt}"
        menu_i 5 "Ссылки подключения" "${sec_count} секр., FakeTLS: ${ftls_txt}"

        printf "\n  ${D}НАСТРОЙКА${NC}\n"
        menu_i 6 "Секреты" "${sec_info}"
        menu_i 7 "Fake-TLS домен" "${ftls_txt}"
        menu_i 8 "Порты" "${port} / ${sp}"
        menu_i 9 "IP-фильтры" "$([ -n "$(read_val ip_blocklist)" ] && echo "блоклист задан" || echo "не заданы")"
        menu_i 10 "Расширенные настройки" "direct, ${workers} ворк."
        menu_i 11 "Редактировать конфиг" "${CONFIG_FILE}"

        printf "\n  ${D}СИСТЕМА${NC}\n"
        menu_i 12 "Обновить Teleproxy" ""
        menu_i 13 "Бэкап конфигурации" ""
        menu_i 14 "Удалить Teleproxy" ""
    fi
    printf "\n"
    menu_i 0 "Выход" ""
    line
    printf "\n  ${BOLD}> ${NC}"
}

# ── Установка Docker ──────────────────────────────────────────────────
install_docker() {
    hdr "Установка через Docker"
    if ! command -v docker &>/dev/null; then
        ok "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        ok "Docker уже установлен"
    fi
    setup_interactive docker
    launch_docker
    self_install
    show_post_install
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
    ok "Скачиваем образ и запускаем..."
    docker pull "$DOCKER_IMAGE"
    docker run "${da[@]}" "${ea[@]}" -v "${DATA_DIR}:/opt/teleproxy/data" "$DOCKER_IMAGE"
    sleep 3
    docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME" && ok "Контейнер запущен" || { err "Контейнер не запустился:"; docker logs "$DOCKER_NAME" 2>&1 | tail -10; }
}

# ── Установка бинарник ─────────────────────────────────────────────────
install_binary() {
    hdr "Установка бинарника + systemd"
    [ -d /run/systemd/system ] || die "systemd не обнаружен — используйте Docker"
    local arch; arch=$(detect_arch)
    ok "Скачиваем teleproxy ($arch)..."
    local tmp; tmp=$(mktemp)
    curl -fsSL -o "$tmp" "https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${arch}" || die "Ошибка загрузки"
    chmod +x "$tmp"; mv "$tmp" "$INSTALL_DIR/teleproxy"
    ok "Бинарник: $INSTALL_DIR/teleproxy"

    id "$SERVICE_USER" &>/dev/null || { useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; ok "Пользователь: $SERVICE_USER"; }
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
    systemctl daemon-reload
    systemctl enable --now teleproxy
    sleep 2
    systemctl is-active --quiet teleproxy && ok "Сервис запущен" || { err "Сервис не запустился:"; journalctl -u teleproxy --no-pager -n 15; }

    self_install
    show_post_install
    pause
}

# ── Интерактивная настройка ────────────────────────────────────────────
setup_interactive() {
    local mode="$1"
    hdr "Настройка Teleproxy"

    printf "  ${C}Порт для подключений клиентов${NC} [${W}443${NC}]: "; read -r p; p="${p:-443}"
    printf "  ${C}Порт HTTP-статистики и QR-кодов${NC} [${W}8888${NC}]: "; read -r sp; sp="${sp:-8888}"
    local cpus; cpus=$(nproc 2>/dev/null || echo 1)
    printf "  ${C}Воркеры${NC} (доступно ядер: ${W}${cpus}${NC}) [${W}${cpus}${NC}]: "; read -r w; w="${w:-$cpus}"

    printf "\n  ${C}Включить Fake-TLS маскировку?${NC}\n"
    printf "  ${D}Трафик будет неотличим от обычного HTTPS${NC}\n"
    printf "  [${W}Y${NC}/n]: "; read -r tls
    local dom=""
    [[ "${tls,,}" != "n" ]] && { printf "  ${C}Домен для маскировки${NC} [${W}www.google.com${NC}]: "; read -r dom; dom="${dom:-www.google.com}"; }

    printf "\n  ${C}Количество секретов${NC} (каждый = отдельная ссылка, макс 16) [${W}1${NC}]: "; read -r sc; sc="${sc:-1}"
    [[ "$sc" =~ ^[0-9]+$ ]] && [ "$sc" -ge 1 ] && [ "$sc" -le 16 ] || { warn "Некорректное число, используем 1"; sc=1; }

    local -a keys=() lbls=() lims=()
    for ((i=1;i<=sc;i++)); do
        local s; s=$(gen_secret); keys+=("$s")
        if [ "$sc" -gt 1 ]; then
            printf "\n  ${D}Секрет #${i}:${NC} ${W}${s}${NC}\n"
            printf "    Метка (имя пользователя/группы) [secret_${i}]: "; read -r l; lbls+=("${l:-secret_${i}}")
            printf "    Лимит подключений (пусто = безлимит): "; read -r li; lims+=("$li")
        else
            printf "\n  ${D}Секрет:${NC} ${W}${s}${NC}\n"; lbls+=("default"); lims+=("")
        fi
    done

    mkdir -p "$CONFIG_DIR"
    {
        echo "# Teleproxy config — $(date '+%Y-%m-%d %H:%M')"
        echo "# Docs: https://teleproxy.github.io"
        echo ""
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
    ok "Конфигурация сохранена: $CONFIG_FILE"
}

# ── Пост-установочный вывод ────────────────────────────────────────────
show_post_install() {
    local ip port sp
    ip=$(get_ip); ip="${ip:-<IP>}"
    port=$(read_val port); port="${port:-443}"
    sp=$(read_val stats_port); sp="${sp:-8888}"

    printf "\n"
    printf "  ${G}══════════════════════════════════════════════${NC}\n"
    printf "  ${G}  Teleproxy установлен и работает!${NC}\n"
    printf "  ${G}══════════════════════════════════════════════${NC}\n"

    printf "\n  ${BOLD}Подключение:${NC}\n"
    show_links_inner

    printf "\n  ${BOLD}Веб-интерфейс:${NC}\n"
    printf "    Статистика:  ${UL}http://${ip}:${sp}/stats${NC}\n"
    printf "    QR-коды:     ${UL}http://${ip}:${sp}/link${NC}\n"

    printf "\n  ${BOLD}Управление сервером:${NC}\n"
    printf "    ${C}teleproxy-manager${NC}            — интерактивное меню\n"
    printf "    ${C}teleproxy-manager status${NC}     — статус и метрики\n"
    printf "    ${C}teleproxy-manager links${NC}      — ссылки подключения\n"
    printf "    ${C}teleproxy-manager restart${NC}    — перезапуск\n"
    printf "    ${C}teleproxy-manager logs${NC}       — просмотр логов\n"
    printf "    ${C}teleproxy-manager help${NC}       — все команды\n"
    printf "\n  ${G}══════════════════════════════════════════════${NC}\n"
}

# ── Управление ─────────────────────────────────────────────────────────
do_start() {
    local m; m=$(detect_method)
    hdr "Запуск Teleproxy"
    if [ "$m" = "docker" ]; then docker start "$DOCKER_NAME"; else systemctl start teleproxy; fi
    sleep 1; ok "Teleproxy запущен"
    [ -z "$CLI_MODE" ] && pause
}

do_stop() {
    local m; m=$(detect_method)
    hdr "Остановка Teleproxy"
    if [ "$m" = "docker" ]; then docker stop "$DOCKER_NAME"; else systemctl stop teleproxy; fi
    ok "Teleproxy остановлен"
    [ -z "$CLI_MODE" ] && pause
}

do_restart() {
    local m; m=$(detect_method)
    hdr "Перезапуск Teleproxy"
    if [ "$m" = "docker" ]; then docker restart "$DOCKER_NAME"; else systemctl restart teleproxy; fi
    sleep 1; ok "Teleproxy перезапущен"
    [ -z "$CLI_MODE" ] && pause
}

do_logs() {
    local lines="${1:-50}"
    local m; m=$(detect_method)
    if [ -n "$CLI_MODE" ]; then
        if [ "$m" = "docker" ]; then docker logs --tail "$lines" "$DOCKER_NAME"
        else journalctl -u teleproxy --no-pager -n "$lines"; fi
    else
        hdr "Логи Teleproxy (Ctrl+C — выход)"
        if [ "$m" = "docker" ]; then docker logs -f --tail "$lines" "$DOCKER_NAME"
        else journalctl -u teleproxy -f --no-pager -n "$lines"; fi
    fi
}

do_status() {
    hdr "Статус Teleproxy"
    local m st; m=$(detect_method); st=$(detect_status)
    local ip; ip=$(get_ip)
    local pv up
    pv=$(get_proxy_version); up=$(get_uptime)

    printf "\n"
    printf "  ${D}Состояние:${NC}  "
    [ "$st" = "running" ] && printf "${G}● Работает${NC}" || printf "${R}● Остановлен${NC}"
    [ -n "$up" ] && printf "  ${D}(${up})${NC}"
    printf "\n"
    printf "  ${D}Метод:${NC}      ${W}${m}${NC}\n"
    [ -n "$pv" ] && printf "  ${D}Версия:${NC}     ${W}v${pv}${NC}\n"
    printf "  ${D}IP:${NC}         ${C}${ip:-?}${NC}\n"
    printf "  ${D}Конфиг:${NC}     ${CONFIG_FILE}\n"

    if [ "$m" = "docker" ]; then
        printf "\n  ${BOLD}Docker:${NC}\n"
        docker ps -a --filter "name=$DOCKER_NAME" --format "  {{.Status}}  {{.Ports}}" 2>/dev/null | head -3
        echo ""
        docker stats --no-stream --format "  CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}  Net I/O: {{.NetIO}}" "$DOCKER_NAME" 2>/dev/null || true
    else
        printf "\n  ${BOLD}Systemd:${NC}\n"
        systemctl status teleproxy --no-pager 2>/dev/null | sed 's/^/  /' | head -12
    fi

    local sp; sp=$(read_val stats_port); sp="${sp:-8888}"
    printf "\n  ${BOLD}HTTP-статистика (/stats):${NC}\n"
    local raw; raw=$(curl -sf --max-time 3 "http://127.0.0.1:${sp}/stats" 2>/dev/null || true)
    if [ -n "$raw" ]; then
        echo "$raw" | sed 's/^/  /' | head -25
    else
        warn "  /stats недоступен — убедитесь, что http_stats = true в конфиге"
    fi

    printf "\n  ${D}Endpoints:${NC}\n"
    printf "    Статистика: http://${ip:-<IP>}:${sp}/stats\n"
    printf "    QR-коды:    http://${ip:-<IP>}:${sp}/link\n"

    [ -z "$CLI_MODE" ] && pause
}

# ── Ссылки подключения ─────────────────────────────────────────────────
show_links_inner() {
    local ip port dom
    ip=$(get_ip); ip="${ip:-<IP>}"
    [ -f "$CONFIG_FILE" ] && { port=$(read_val port); dom=$(read_val domain | tr -d '"'); }
    port="${port:-443}"

    while IFS= read -r bl; do
        [ -z "$bl" ] && continue
        local k lb fs
        k=$(echo "$bl" | grep -oP 'key\s*=\s*"\K[^"]+' || true); [ -z "$k" ] && continue
        lb=$(echo "$bl" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        if [ -n "$dom" ]; then fs="ee${k}$(printf '%s' "$dom" | xxd -ps | tr -d '\n')"; else fs="$k"; fi
        [ -n "$lb" ] && printf "    ${W}[${lb}]${NC}\n"
        printf "    ${C}tg://proxy?server=${ip}&port=${port}&secret=${fs}${NC}\n"
        printf "    ${D}https://t.me/proxy?server=${ip}&port=${port}&secret=${fs}${NC}\n"
    done < <(secret_blocks)
}

do_links() {
    hdr "Ссылки для подключения к Telegram"
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        printf "\n  ${D}Из логов контейнера:${NC}\n"
        docker logs "$DOCKER_NAME" 2>&1 | { grep -E "(tg://|t\.me/proxy)" || true; } | sed 's/^/    /' | tail -16
        echo ""
    fi
    printf "\n  ${BOLD}Из конфигурации:${NC}\n"
    show_links_inner
    local sp; sp=$(read_val stats_port); sp="${sp:-8888}"
    local ip; ip=$(get_ip)
    printf "\n  ${D}QR-коды:${NC} http://${ip:-<IP>}:${sp}/link\n"
    [ -z "$CLI_MODE" ] && pause
}

# ── Секреты ────────────────────────────────────────────────────────────
do_secrets() {
    local subcmd="${1:-}"
    if [ -n "$CLI_MODE" ]; then
        case "$subcmd" in
            list|"") _secrets_list ;;
            add) _secret_add_cli ;;
            remove|rm) shift 2>/dev/null; _secret_remove_cli "$@" ;;
            *) err "Неизвестная подкоманда: $subcmd. Используйте: list, add, remove N" ;;
        esac
        return
    fi
    while true; do
        hdr "Управление секретами"
        _secrets_list
        echo ""
        menu_i a "Добавить новый секрет" ""
        menu_i d "Удалить секрет" ""
        menu_i r "Перегенерировать все секреты" ""
        menu_i 0 "Назад" ""
        printf "\n  > "; read -r ch
        case "$ch" in
            a) _secret_add_interactive ;;
            d) _secret_remove_interactive ;;
            r) _secrets_regenerate ;;
            0) return ;;
        esac
    done
}

_secrets_list() {
    [ -f "$CONFIG_FILE" ] || { warn "Конфиг не найден"; return; }
    local i=1
    while IFS= read -r bl; do
        [ -z "$bl" ] && continue
        local k lb lm qt ri mi ex
        k=$(echo "$bl" | grep -oP 'key\s*=\s*"\K[^"]+' || true); [ -z "$k" ] && continue
        lb=$(echo "$bl" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        lm=$(echo "$bl" | grep -oP 'limit\s*=\s*\K[0-9]+' || true)
        qt=$(echo "$bl" | grep -oP 'quota\s*=\s*\K[0-9]+' || true)
        ri=$(echo "$bl" | grep -oP 'rate_limit\s*=\s*"\K[^"]+' || true)
        mi=$(echo "$bl" | grep -oP 'max_ips\s*=\s*\K[0-9]+' || true)
        printf "  ${G}%d${NC}) ${W}${k}${NC}" "$i"
        [ -n "$lb" ] && printf "  ${D}[${lb}]${NC}"
        [ -n "$lm" ] && printf "  ${Y}≤${lm} подкл.${NC}"
        [ -n "$qt" ] && printf "  ${D}квота:${qt}${NC}"
        [ -n "$ri" ] && printf "  ${D}rate:${ri}${NC}"
        [ -n "$mi" ] && printf "  ${D}ip≤${mi}${NC}"
        printf "\n"; i=$((i+1))
    done < <(secret_blocks)
    [ "$i" -eq 1 ] && warn "Секретов нет"
}

_secret_add_interactive() {
    [ -f "$CONFIG_FILE" ] || { err "Конфиг не найден"; return; }
    local s; s=$(gen_secret)
    printf "  ${C}Метка${NC} (напр. имя пользователя) [new]: "; read -r lb; lb="${lb:-new}"
    printf "  ${C}Лимит подключений${NC} (пусто = безлимит): "; read -r lm
    { echo ""; echo "[[secret]]"; echo "key = \"$s\""; echo "label = \"$lb\""; [ -n "$lm" ] && echo "limit = $lm"; echo ""; } >> "$CONFIG_FILE"
    ok "Добавлен секрет: $s [$lb]"
    reload_cfg
}

_secret_add_cli() {
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден"
    local s; s=$(gen_secret)
    { echo ""; echo "[[secret]]"; echo "key = \"$s\""; echo "label = \"new\""; echo ""; } >> "$CONFIG_FILE"
    ok "Добавлен: $s"
    reload_cfg
}

_secret_remove_interactive() {
    printf "  ${C}Номер секрета для удаления:${NC} "; read -r n
    [[ "$n" =~ ^[0-9]+$ ]] || { warn "Введите число"; return; }
    printf "  ${R}Удалить секрет #${n}?${NC} [y/N]: "; read -r confirm
    [[ "${confirm,,}" == "y" ]] || { ok "Отменено"; return; }
    _do_remove_secret "$n"
}

_secret_remove_cli() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || die "Укажите номер секрета: teleproxy-manager secrets remove N"
    _do_remove_secret "$n"
}

_do_remove_secret() {
    local n="$1"
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден"
    local t; t=$(mktemp)
    awk -v n="$n" 'BEGIN{c=0;s=0} /^\[\[secret\]\]/{c++;if(c==n){s=1;next}} s&&/^$/{s=0;next} s&&/^\[/{s=0} !s' "$CONFIG_FILE" > "$t"
    mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    ok "Секрет #${n} удалён"
    reload_cfg
}

_secrets_regenerate() {
    [ -f "$CONFIG_FILE" ] || { warn "Конфиг не найден"; return; }
    printf "  ${R}Перегенерировать ВСЕ секреты? Старые ссылки перестанут работать.${NC} [y/N]: "
    read -r confirm
    [[ "${confirm,,}" == "y" ]] || { ok "Отменено"; return; }
    local t; t=$(mktemp); local ins=0
    while IFS= read -r ln; do
        [[ "$ln" =~ ^\[\[secret\]\] ]] && ins=1
        if [ "$ins" -eq 1 ] && [[ "$ln" =~ ^key ]]; then echo "key = \"$(gen_secret)\"" >> "$t"; else echo "$ln" >> "$t"; fi
        [ "$ins" -eq 1 ] && { [[ -z "$ln" || "$ln" =~ ^\[ ]] && ins=0; }
    done < "$CONFIG_FILE"
    mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    ok "Все секреты перегенерированы"
    reload_cfg
}

# ── Fake-TLS ──────────────────────────────────────────────────────────
do_faketls() {
    hdr "Fake-TLS маскировка"
    local cur; cur=$(read_val domain | tr -d '"')
    if [ -n "$cur" ]; then
        printf "  Текущий домен: ${W}${cur}${NC}\n"
        printf "  ${D}Трафик маскируется под HTTPS к этому домену${NC}\n"
    else
        printf "  ${D}Отключён — трафик не маскирован${NC}\n"
    fi
    echo ""
    menu_i 1 "Включить / изменить домен" ""
    menu_i 2 "Отключить Fake-TLS" ""
    menu_i 0 "Назад" ""
    printf "\n  > "; read -r ch
    case "$ch" in
        1) printf "  Домен [www.google.com]: "; read -r d; d="${d:-www.google.com}"
           grep -q '^domain ' "$CONFIG_FILE" 2>/dev/null && sed -i "s|^domain .*|domain = \"$d\"|" "$CONFIG_FILE" || sed -i "/^port /a domain = \"$d\"" "$CONFIG_FILE"
           ok "Fake-TLS включён: $d"; reload_cfg ;;
        2) sed -i '/^domain /d' "$CONFIG_FILE"; ok "Fake-TLS отключён"; reload_cfg ;;
    esac
    pause
}

# ── Порты ──────────────────────────────────────────────────────────────
do_ports() {
    hdr "Настройка портов"
    local cp cs; cp=$(read_val port); cs=$(read_val stats_port)
    printf "  ${D}Порт клиентов — куда подключаются пользователи Telegram${NC}\n"
    printf "  ${C}Порт клиентов${NC} [${W}${cp:-443}${NC}]: "; read -r np; np="${np:-${cp:-443}}"
    printf "\n  ${D}Порт статистики — HTTP-страница со статусом и QR-кодами${NC}\n"
    printf "  ${C}Порт статистики${NC} [${W}${cs:-8888}${NC}]: "; read -r ns; ns="${ns:-${cs:-8888}}"
    sed -i "s|^port = .*|port = $np|;s|^stats_port = .*|stats_port = $ns|" "$CONFIG_FILE"
    ok "Порты обновлены: клиенты = $np, статистика = $ns"
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        warn "Docker требует пересоздания контейнера для смены портов"
        printf "  Пересоздать сейчас? [Y/n]: "; read -r y
        [[ "${y,,}" != "n" ]] && recreate_docker
    else
        reload_cfg
    fi
    pause
}

# ── IP-фильтры ────────────────────────────────────────────────────────
do_ipfilter() {
    hdr "IP-фильтрация"
    printf "  ${D}Ограничение доступа к прокси по IP-адресам${NC}\n\n"
    local bl al sn
    bl=$(read_val ip_blocklist | tr -d '"')
    al=$(read_val ip_allowlist | tr -d '"')
    sn=$(read_val stats_allow_net)
    [ -n "$bl" ] && printf "  Блоклист:    ${W}${bl}${NC}\n" || printf "  Блоклист:    ${D}не задан${NC}\n"
    [ -n "$al" ] && printf "  Вайтлист:    ${W}${al}${NC}\n" || printf "  Вайтлист:    ${D}не задан${NC}\n"
    [ -n "$sn" ] && printf "  Сети /stats: ${W}${sn}${NC}\n" || printf "  Сети /stats: ${D}по умолчанию (RFC1918)${NC}\n"
    echo ""
    menu_i 1 "Блоклист IP" "(файл с CIDR, по одному на строку)"
    menu_i 2 "Вайтлист IP" "(только эти IP смогут подключиться)"
    menu_i 3 "Сети для /stats" "(расширить доступ к статистике)"
    menu_i 0 "Назад" ""
    printf "\n  > "; read -r ch
    case "$ch" in
        1) printf "  Путь к файлу блоклиста: "; read -r f; [ -n "$f" ] && { _set_kv ip_blocklist "\"$f\""; reload_cfg; } ;;
        2) printf "  Путь к файлу вайтлиста: "; read -r f; [ -n "$f" ] && { _set_kv ip_allowlist "\"$f\""; reload_cfg; } ;;
        3) printf "  CIDR через запятую (напр. 100.64.0.0/10,fd00::/8): "; read -r n; [ -n "$n" ] && {
           local fmt; fmt=$(echo "$n" | sed 's/,/", "/g'); _set_kv stats_allow_net "[\"$fmt\"]"; reload_cfg; } ;;
        0) return ;;
    esac
    pause
}

_set_kv() {
    grep -q "^${1} " "$CONFIG_FILE" 2>/dev/null && sed -i "s|^${1} .*|${1} = ${2}|" "$CONFIG_FILE" || echo "${1} = ${2}" >> "$CONFIG_FILE"
    ok "${1} обновлён"
}

# ── Расширенные настройки ──────────────────────────────────────────────
do_advanced() {
    while true; do
        hdr "Расширенные настройки"
        local pp=$(read_val proxy_protocol) ipv6=$(read_val ipv6)
        local sk=$(read_val socks5 | tr -d '"') bd=$(read_val bind | tr -d '"')
        local dci=$(read_val dc_probe_interval) pt=$(read_val proxy_tag | tr -d '"') mc=$(read_val maxconn)
        menu_i 1 "PROXY Protocol v1/v2" "$([ "$pp" = "true" ] && echo "✓ вкл" || echo "выкл")"
        menu_i 2 "SOCKS5 upstream прокси" "${sk:-не задан}"
        menu_i 3 "Bind IP (привязка к адресу)" "${bd:-все интерфейсы}"
        menu_i 4 "Предпочитать IPv6" "$([ "$ipv6" = "true" ] && echo "✓ вкл" || echo "выкл")"
        menu_i 5 "DC Override" "(переопределить адреса Telegram DC)"
        menu_i 6 "DC Probes (мониторинг задержек)" "${dci:-выкл}$([ -n "$dci" ] && echo "с")"
        menu_i 7 "Proxy Tag от @MTProxybot" "${pt:-не задан}"
        menu_i 8 "Макс. соединений" "${mc:-60000}"
        menu_i 9 "Квоты и rate limit секретов" ""
        menu_i 0 "Назад" ""
        printf "\n  > "; read -r ch
        case "$ch" in
            1) _toggle proxy_protocol "PROXY Protocol" ;;
            2) printf "  SOCKS5 (host:port или user:pass@host:port): "; read -r v; _str socks5 "$v" ;;
            3) printf "  Bind IP (пусто = все): "; read -r v; _str bind "$v" ;;
            4) _toggle ipv6 "IPv6" ;;
            5) _dc_override ;;
            6) printf "  Интервал DC-проб в секундах [30] (0 = выкл): "; read -r v; _int dc_probe_interval "${v:-30}" ;;
            7) printf "  Proxy Tag (из @MTProxybot): "; read -r v; _str proxy_tag "$v" ;;
            8) printf "  Макс. соединений [60000]: "; read -r v; _int maxconn "${v:-60000}" ;;
            9) _secret_adv ;;
            0) return ;;
        esac
    done
}

_toggle() {
    local cur; cur=$(read_val "$1")
    if [ "$cur" = "true" ]; then sed -i "/^${1} /d" "$CONFIG_FILE"; ok "$2: выключен"
    else _set_kv "$1" "true"; ok "$2: включен"; fi
    reload_cfg; pause
}

_str() {
    [ -z "$2" ] && { sed -i "/^${1} /d" "$CONFIG_FILE"; ok "${1}: удалён"; } || _set_kv "$1" "\"$2\""
    reload_cfg; pause
}

_int() {
    [ "$2" = "0" ] || [ -z "$2" ] && { sed -i "/^${1} /d" "$CONFIG_FILE"; ok "${1}: удалён"; } || _set_kv "$1" "$2"
    reload_cfg; pause
}

_dc_override() {
    hdr "DC Override — переопределение адресов Telegram DC"
    printf "  ${D}Формат: DC_ID:HOST:PORT через запятую${NC}\n"
    printf "  ${D}Пример: 2:149.154.167.50:443,2:149.154.167.51:443${NC}\n"
    printf "  ${D}Пусто = очистить${NC}\n\n  > "; read -r inp
    sed -i '/^\[\[dc_override\]\]/,/^$/d' "$CONFIG_FILE"
    if [ -z "$inp" ]; then ok "DC Override очищены"
    else
        IFS=',' read -ra dcs <<< "$inp"
        for dc in "${dcs[@]}"; do
            dc=$(echo "$dc" | tr -d ' '); IFS=':' read -r did dh dp <<< "$dc"
            { echo ""; echo "[[dc_override]]"; echo "dc = $did"; echo "host = \"$dh\""; echo "port = $dp"; } >> "$CONFIG_FILE"
        done
        ok "DC Override настроены (${#dcs[@]} записей)"
    fi
    reload_cfg; pause
}

_secret_adv() {
    hdr "Квоты и ограничения секретов"
    printf "  ${D}Настройка квот трафика, rate limit, макс. IP и срока действия${NC}\n\n"
    _secrets_list
    printf "\n  Номер секрета: "; read -r n; [[ "$n" =~ ^[0-9]+$ ]] || return
    printf "  ${C}Квота трафика${NC} в байтах (1073741824 = 1GB, пусто = безлимит): "; read -r q
    printf "  ${C}Rate limit${NC} (напр. 100mb/h или 1gb/d, пусто = безлимит): "; read -r rl
    printf "  ${C}Макс. уникальных IP${NC} (пусто = безлимит): "; read -r mi
    printf "  ${C}Срок действия${NC} (Unix timestamp, пусто = бессрочно): "; read -r ex

    local t; t=$(mktemp); local cnt=0 ins=0 dn=0
    while IFS= read -r ln; do
        [[ "$ln" =~ ^\[\[secret\]\] ]] && { cnt=$((cnt+1)); ins=1; }
        if [ "$ins" -eq 1 ] && [ "$cnt" -eq "$n" ] && [ "$dn" -eq 0 ] && [[ -z "$ln" || "$ln" =~ ^\[ ]]; then
            [ -n "$q" ] && echo "quota = $q" >> "$t"
            [ -n "$rl" ] && echo "rate_limit = \"$rl\"" >> "$t"
            [ -n "$mi" ] && echo "max_ips = $mi" >> "$t"
            [ -n "$ex" ] && echo "expires = $ex" >> "$t"
            dn=1; ins=0
        fi
        echo "$ln" >> "$t"
    done < "$CONFIG_FILE"
    if [ "$ins" -eq 1 ] && [ "$cnt" -eq "$n" ] && [ "$dn" -eq 0 ]; then
        [ -n "$q" ] && echo "quota = $q" >> "$t"
        [ -n "$rl" ] && echo "rate_limit = \"$rl\"" >> "$t"
        [ -n "$mi" ] && echo "max_ips = $mi" >> "$t"
        [ -n "$ex" ] && echo "expires = $ex" >> "$t"
    fi
    mv "$t" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    ok "Настройки секрета #${n} обновлены"
    reload_cfg; pause
}

# ── Конфиг вручную ─────────────────────────────────────────────────────
do_config() {
    local subcmd="${1:-}"
    if [ -n "$CLI_MODE" ]; then
        case "$subcmd" in
            show|"") [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || die "Конфиг не найден" ;;
            edit) local ed; ed="${EDITOR:-$(command -v nano||command -v vim||command -v vi||true)}"
                  [ -n "$ed" ] && "$ed" "$CONFIG_FILE" && reload_cfg || die "Редактор не найден" ;;
            *) die "Используйте: config show|edit" ;;
        esac
        return
    fi
    [ -f "$CONFIG_FILE" ] || { err "Конфиг не найден: $CONFIG_FILE"; pause; return; }
    hdr "Конфигурация ($CONFIG_FILE)"
    cat -n "$CONFIG_FILE"; echo ""
    local ed; ed="${EDITOR:-$(command -v nano||command -v vim||command -v vi||true)}"
    if [ -n "$ed" ]; then
        printf "  Открыть в ${W}${ed}${NC}? [Y/n]: "; read -r y
        [[ "${y,,}" != "n" ]] && { "$ed" "$CONFIG_FILE"; reload_cfg; }
    else
        warn "Текстовый редактор не найден. Редактируйте вручную: $CONFIG_FILE"
    fi
    pause
}

# ── Обновление ─────────────────────────────────────────────────────────
do_update() {
    hdr "Обновление Teleproxy"
    local m; m=$(detect_method)
    if [ "$m" = "docker" ]; then
        ok "Обновляем Docker-образ..."
        docker pull "$DOCKER_IMAGE"
        recreate_docker
        ok "Teleproxy обновлён (Docker)"
    elif [ "$m" = "binary" ]; then
        local a; a=$(detect_arch)
        local old_ver; old_ver=$(get_proxy_version)
        [ -n "$old_ver" ] && printf "  ${D}Текущая версия: v${old_ver}${NC}\n"
        systemctl stop teleproxy 2>/dev/null || true
        ok "Скачиваем последнюю версию..."
        local t; t=$(mktemp)
        curl -fsSL -o "$t" "https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${a}" || die "Ошибка загрузки"
        chmod +x "$t"; mv "$t" "$INSTALL_DIR/teleproxy"
        systemctl start teleproxy
        local new_ver; new_ver=$(get_proxy_version)
        ok "Обновлено${new_ver:+ до v$new_ver}"
    else
        die "Teleproxy не установлен"
    fi
    [ -z "$CLI_MODE" ] && pause
}

do_update_self() {
    hdr "Обновление скрипта Teleproxy Manager"
    local tmp; tmp=$(mktemp)
    curl -fsSL "https://raw.githubusercontent.com/${SCRIPT_REPO}/main/teleproxy-manager.sh" -o "$tmp" || die "Ошибка загрузки"
    local new_ver; new_ver=$(grep -m1 '^VER=' "$tmp" | cut -d'"' -f2)
    chmod +x "$tmp"; mv "$tmp" "$SELF_PATH"
    ok "Скрипт обновлён${new_ver:+ до v$new_ver}"
    printf "  ${D}Перезапустите: teleproxy-manager${NC}\n"
    exit 0
}

# ── Бэкап ──────────────────────────────────────────────────────────────
do_backup() {
    local subcmd="${1:-}"
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден"
    local bdir="/root/teleproxy-backups"; mkdir -p "$bdir"

    if [ "$subcmd" = "restore" ]; then
        local rf="$2"
        [ -z "$rf" ] && die "Укажите файл: teleproxy-manager backup restore FILE"
        [ -f "$rf" ] || die "Файл не найден: $rf"
        cp "$rf" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
        ok "Конфиг восстановлен из: $rf"
        reload_cfg
        return
    fi

    hdr "Резервное копирование"
    local f="${bdir}/config_$(date '+%Y%m%d_%H%M%S').toml"
    cp "$CONFIG_FILE" "$f"
    ok "Бэкап: $f"

    if [ -z "$CLI_MODE" ]; then
        printf "\n  ${D}Последние бэкапы:${NC}\n"
        ls -1t "$bdir"/*.toml 2>/dev/null | head -5 | sed 's/^/    /'
        printf "\n  Восстановить из бэкапа? [y/N]: "; read -r y
        if [[ "${y,,}" == "y" ]]; then
            printf "  Путь к файлу: "; read -r rf
            [ -f "$rf" ] && { cp "$rf" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"; ok "Восстановлен"; reload_cfg; } || err "Файл не найден"
        fi
        pause
    fi
}

# ── Удаление ──────────────────────────────────────────────────────────
do_uninstall() {
    hdr "Удаление Teleproxy"
    if [ -z "$CLI_MODE" ]; then
        printf "  ${R}Это удалит Teleproxy и остановит прокси.${NC}\n"
        printf "  Введите ${W}DELETE${NC} для подтверждения: "; read -r c
        [ "$c" != "DELETE" ] && { ok "Отменено"; pause; return; }
    fi
    local m; m=$(detect_method)
    [ "$m" = "docker" ] && { docker stop "$DOCKER_NAME" &>/dev/null; docker rm "$DOCKER_NAME" &>/dev/null; docker rmi "$DOCKER_IMAGE" &>/dev/null; ok "Docker: контейнер и образ удалены"; }
    [ "$m" = "binary" ] && { systemctl disable --now teleproxy &>/dev/null; rm -f "$SERVICE_FILE"; systemctl daemon-reload &>/dev/null; rm -f "$INSTALL_DIR/teleproxy"; userdel "$SERVICE_USER" &>/dev/null; ok "Бинарник и systemd-сервис удалены"; }
    if [ -z "$CLI_MODE" ]; then
        printf "  Удалить конфигурационные файлы? [y/N]: "; read -r y
        [[ "${y,,}" == "y" ]] && { rm -rf "$CONFIG_DIR" "$DATA_DIR"; ok "Конфиги удалены"; }
    fi
    rm -f "$SELF_PATH"
    ok "Teleproxy полностью удалён"
    [ -z "$CLI_MODE" ] && pause
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
    sleep 2; docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME" && ok "Контейнер пересоздан" || err "Ошибка запуска контейнера"
}

# ── Справка CLI ────────────────────────────────────────────────────────
show_help() {
    cat << 'HELP'
Teleproxy Manager — установка и управление MTProto-прокси

Использование:
  teleproxy-manager                    Интерактивное меню
  teleproxy-manager <команда>          Прямое выполнение

Команды:
  install [docker|binary]    Установить Teleproxy
  status                     Статус, метрики, информация
  start                      Запустить прокси
  stop                       Остановить прокси
  restart                    Перезапустить прокси
  logs [N]                   Показать N последних строк логов (по умолч. 50)
  links                      Ссылки подключения для Telegram

  secrets list               Список секретов
  secrets add                Добавить секрет
  secrets remove N           Удалить секрет #N

  config show                Показать конфиг
  config edit                Открыть конфиг в редакторе

  update                     Обновить Teleproxy до последней версии
  update-self                Обновить скрипт Teleproxy Manager
  backup                     Создать бэкап конфига
  backup restore FILE        Восстановить конфиг из бэкапа
  uninstall                  Полностью удалить Teleproxy

  help                       Эта справка

Файлы:
  /etc/teleproxy/config.toml    Конфигурация прокси
  /var/lib/teleproxy/            Данные (proxy-multi.conf)
  /root/teleproxy-backups/       Бэкапы конфигов

Документация: https://teleproxy.github.io
Исходники:    https://github.com/teleproxy/teleproxy
HELP
}

# ── CLI-парсер ─────────────────────────────────────────────────────────
cli_dispatch() {
    CLI_MODE=1
    check_root
    local cmd="${1:-help}"; shift 2>/dev/null || true
    case "$cmd" in
        install)
            check_os; install_deps
            local type="${1:-docker}"
            case "$type" in
                docker) install_docker ;;
                binary) install_binary ;;
                *) die "Используйте: install docker|binary" ;;
            esac ;;
        status)       do_status ;;
        start)        do_start ;;
        stop)         do_stop ;;
        restart)      do_restart ;;
        logs)         do_logs "$@" ;;
        links)        do_links ;;
        secrets)      do_secrets "$@" ;;
        config)       do_config "$@" ;;
        update)       do_update ;;
        update-self)  do_update_self ;;
        backup)       do_backup "$@" ;;
        uninstall)    do_uninstall ;;
        help|--help|-h) show_help ;;
        *)            err "Неизвестная команда: $cmd"; echo ""; show_help; exit 1 ;;
    esac
}

# ── Главный цикл ──────────────────────────────────────────────────────
main_interactive() {
    check_root; check_os; install_deps
    self_install 2>/dev/null || true
    check_script_update 2>/dev/null || true
    while true; do
        show_menu
        read -r ch || break
        local st; st=$(detect_status)
        if [ "$st" = "none" ]; then
            case "$ch" in 1) install_docker;; 2) install_binary;; 0) echo ""; exit 0;; *) warn "Неверный выбор"; pause;; esac
        else
            case "$ch" in
                1)  [ "$st" = running ] && do_stop || do_start;;
                2)  do_restart;; 3) do_logs;; 4) do_status;; 5) do_links;;
                6)  do_secrets;; 7) do_faketls;; 8) do_ports;; 9) do_ipfilter;;
                10) do_advanced;; 11) do_config;; 12) do_update;; 13) do_backup;; 14) do_uninstall;;
                0)  echo ""; exit 0;; *) warn "Неверный выбор"; pause;;
            esac
        fi
    done
}

# ── Точка входа ────────────────────────────────────────────────────────
if [ $# -gt 0 ]; then
    cli_dispatch "$@"
else
    main_interactive
fi
