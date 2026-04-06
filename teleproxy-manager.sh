#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Teleproxy Manager — установка, настройка и управление MTProto-прокси
#  Версия: 1.0
#  Однострочная установка:
#    bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-install/main/teleproxy-manager.sh)
# ═══════════════════════════════════════════════════════════════════════
set -eo pipefail

# ── Константы ──────────────────────────────────────────────────────────
GITHUB_REPO="teleproxy/teleproxy"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/teleproxy"
CONFIG_FILE="$CONFIG_DIR/config.toml"
DATA_DIR="/var/lib/teleproxy"
SERVICE_FILE="/etc/systemd/system/teleproxy.service"
SERVICE_USER="teleproxy"
DOCKER_IMAGE="ghcr.io/teleproxy/teleproxy:latest"
DOCKER_NAME="teleproxy"
SCRIPT_VERSION="1.0"

# ── Цвета и форматирование ────────────────────────────────────────────
if [ -t 1 ]; then
    R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'
    B='\033[0;34m'   C='\033[0;36m'   M='\033[0;35m'
    W='\033[1;37m'   D='\033[0;90m'   NC='\033[0m'
    BOLD='\033[1m'   DIM='\033[2m'    UNDERLINE='\033[4m'
else
    R='' G='' Y='' B='' C='' M='' W='' D='' NC='' BOLD='' DIM='' UNDERLINE=''
fi

# ── Утилиты ────────────────────────────────────────────────────────────
info()    { printf "${G}  ✓${NC} %s\n" "$1"; }
warn()    { printf "${Y}  ⚠${NC} %s\n" "$1"; }
error()   { printf "${R}  ✗${NC} %s\n" "$1" >&2; }
die()     { error "$1"; exit 1; }
header()  { printf "\n${B}━━━${NC} ${BOLD}%s${NC}\n\n" "$1"; }
divider() { printf "${D}  ────────────────────────────────────────${NC}\n"; }

press_enter() {
    echo ""
    printf "  ${D}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ── Баннер ─────────────────────────────────────────────────────────────
show_banner() {
    clear
    cat << 'BANNER'

  ╔══════════════════════════════════════════════════╗
  ║                                                  ║
  ║   ████████╗███████╗██╗     ███████╗██████╗       ║
  ║      ██╔══╝██╔════╝██║     ██╔════╝██╔══██╗      ║
  ║      ██║   █████╗  ██║     █████╗  ██████╔╝      ║
  ║      ██║   ██╔══╝  ██║     ██╔══╝  ██╔═══╝       ║
  ║      ██║   ███████╗███████╗███████╗██║            ║
  ║      ╚═╝   ╚══════╝╚══════╝╚══════╝╚═╝            ║
  ║                                                  ║
  ║      Teleproxy Manager v1.0                      ║
  ║      MTProto Proxy с защитой от DPI              ║
  ║                                                  ║
  ╚══════════════════════════════════════════════════╝

BANNER
}

# ── Определение текущего метода установки ──────────────────────────────
detect_install_method() {
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "$DOCKER_NAME"; then
        echo "docker"
    elif systemctl is-enabled teleproxy &>/dev/null 2>&1; then
        echo "binary"
    else
        echo "none"
    fi
}

detect_status() {
    local method
    method=$(detect_install_method)
    if [ "$method" = "docker" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$DOCKER_NAME"; then
            echo "running"
        else
            echo "stopped"
        fi
    elif [ "$method" = "binary" ]; then
        if systemctl is-active --quiet teleproxy 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not_installed"
    fi
}

get_external_ip() {
    curl -s -4 --connect-timeout 5 --max-time 10 https://icanhazip.com 2>/dev/null \
        || curl -s -4 --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null \
        || echo ""
}

# ── Системные проверки ─────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" -eq 0 ] || die "Запустите скрипт от root (sudo bash ...)"
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        die "Не удалось определить ОС. Поддерживаются Ubuntu/Debian/CentOS/AlmaLinux."
    fi
    . /etc/os-release
    OS_NAME="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "Неподдерживаемая архитектура: $arch" ;;
    esac
}

install_deps() {
    local pkgs_needed=()
    for cmd in curl jq openssl; do
        command -v "$cmd" &>/dev/null || pkgs_needed+=("$cmd")
    done
    command -v xxd &>/dev/null || pkgs_needed+=("xxd")

    if [ ${#pkgs_needed[@]} -gt 0 ]; then
        info "Установка зависимостей: ${pkgs_needed[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${pkgs_needed[@]}" >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y -q "${pkgs_needed[@]}" >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${pkgs_needed[@]}" >/dev/null 2>&1
        fi
    fi
}

# ── Генерация секретов ─────────────────────────────────────────────────
generate_secret() {
    if [ -x "$INSTALL_DIR/teleproxy" ]; then
        "$INSTALL_DIR/teleproxy" generate-secret 2>/dev/null || head -c 16 /dev/urandom | xxd -ps
    else
        head -c 16 /dev/urandom | xxd -ps
    fi
}

# ── Главное меню ───────────────────────────────────────────────────────
show_main_menu() {
    local status method status_text method_text ip
    status=$(detect_status)
    method=$(detect_install_method)
    ip=$(get_external_ip)

    case "$status" in
        running)       status_text="${G}● Работает${NC}" ;;
        stopped)       status_text="${R}● Остановлен${NC}" ;;
        not_installed) status_text="${D}○ Не установлен${NC}" ;;
    esac

    case "$method" in
        docker) method_text="Docker" ;;
        binary) method_text="Бинарный" ;;
        none)   method_text="—" ;;
    esac

    printf "\n"
    printf "  ${D}Статус:${NC} ${status_text}   ${D}Метод:${NC} ${W}${method_text}${NC}   ${D}IP:${NC} ${C}${ip:-не определён}${NC}\n"
    printf "\n"
    divider
    printf "\n"

    if [ "$status" = "not_installed" ]; then
        printf "  ${W}УСТАНОВКА${NC}\n\n"
        printf "    ${G}1${NC})  Установить через Docker ${C}(рекомендуется)${NC}\n"
        printf "    ${G}2${NC})  Установить бинарник + systemd\n"
        printf "\n"
    else
        printf "  ${W}УПРАВЛЕНИЕ${NC}\n\n"
        if [ "$status" = "running" ]; then
            printf "    ${G}1${NC})  Остановить прокси\n"
            printf "    ${G}2${NC})  Перезапустить прокси\n"
        else
            printf "    ${G}1${NC})  Запустить прокси\n"
            printf "    ${G}2${NC})  Перезапустить прокси\n"
        fi
        printf "    ${G}3${NC})  Показать логи\n"
        printf "    ${G}4${NC})  Показать статус и метрики\n"
        printf "    ${G}5${NC})  Показать ссылки подключения\n"
        printf "\n"
        divider
        printf "\n"
        printf "  ${W}НАСТРОЙКА${NC}\n\n"
        printf "    ${G}6${NC})  Управление секретами\n"
        printf "    ${G}7${NC})  Настроить Fake-TLS (домен)\n"
        printf "    ${G}8${NC})  Настроить порты\n"
        printf "    ${G}9${NC})  Настроить IP-фильтрацию\n"
        printf "   ${G}10${NC})  Расширенные настройки\n"
        printf "   ${G}11${NC})  Редактировать конфиг вручную\n"
        printf "\n"
        divider
        printf "\n"
        printf "  ${W}ОБСЛУЖИВАНИЕ${NC}\n\n"
        printf "   ${G}12${NC})  Обновить Teleproxy\n"
        printf "   ${G}13${NC})  Резервное копирование конфига\n"
        printf "   ${G}14${NC})  Удалить Teleproxy\n"
    fi

    printf "\n"
    printf "    ${D}0${NC})  Выход\n"
    printf "\n"
    divider
    printf "\n"
    printf "  ${BOLD}Выберите действие:${NC} "
}

# ═══════════════════════════════════════════════════════════════════════
#  УСТАНОВКА — Docker
# ═══════════════════════════════════════════════════════════════════════
install_docker() {
    header "Установка через Docker"

    if ! command -v docker &>/dev/null; then
        info "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        info "Docker установлен"
    else
        info "Docker уже установлен"
    fi

    configure_interactive "docker"

    local port ee_domain
    port=$(read_config_value port)
    ee_domain=$(read_config_value domain)
    local stats_port
    stats_port=$(read_config_value stats_port)

    local docker_args=()
    docker_args+=(-d --name "$DOCKER_NAME")
    docker_args+=(-p "${port:-443}:${port:-443}")
    docker_args+=(-p "${stats_port:-8888}:${stats_port:-8888}")
    docker_args+=(--ulimit nofile=65536:65536)
    docker_args+=(--restart unless-stopped)

    local env_args=()
    env_args+=(-e "PORT=${port:-443}")
    env_args+=(-e "STATS_PORT=${stats_port:-8888}")
    env_args+=(-e "DIRECT_MODE=true")

    if [ -n "$ee_domain" ] && [ "$ee_domain" != '""' ]; then
        local clean_domain
        clean_domain=$(echo "$ee_domain" | tr -d '"')
        env_args+=(-e "EE_DOMAIN=${clean_domain}")
    fi

    local secrets_csv=""
    local idx=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local key label limit
        key=$(echo "$line" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
        label=$(echo "$line" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        limit=$(echo "$line" | grep -oP 'limit\s*=\s*\K[0-9]+' || true)
        [ -z "$key" ] && continue

        if [ -n "$secrets_csv" ]; then
            secrets_csv="${secrets_csv},"
        fi
        secrets_csv="${secrets_csv}${key}"

        if [ -n "$label" ]; then
            env_args+=(-e "SECRET_LABEL_${idx}=${label}")
        fi
        if [ -n "$limit" ]; then
            env_args+=(-e "SECRET_LIMIT_${idx}=${limit}")
        fi
        idx=$((idx + 1))
    done < <(extract_secret_blocks)

    if [ -n "$secrets_csv" ]; then
        env_args+=(-e "SECRET=${secrets_csv}")
    fi

    docker rm -f "$DOCKER_NAME" &>/dev/null || true

    info "Запускаем контейнер..."
    docker pull "$DOCKER_IMAGE"
    docker run "${docker_args[@]}" "${env_args[@]}" -v "${DATA_DIR}:/opt/teleproxy/data" "$DOCKER_IMAGE"

    sleep 3
    if docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME"; then
        info "Teleproxy успешно запущен через Docker"
        echo ""
        show_connection_links
    else
        error "Контейнер не запустился. Логи:"
        docker logs "$DOCKER_NAME" 2>&1 | tail -20
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  УСТАНОВКА — Бинарник
# ═══════════════════════════════════════════════════════════════════════
install_binary() {
    header "Установка бинарника + systemd"

    if [ ! -d /run/systemd/system ]; then
        die "systemd не обнаружен. Используйте Docker."
    fi

    local arch
    arch=$(detect_arch)
    local url="https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${arch}"

    info "Скачиваем teleproxy (${arch})..."
    local tmp
    tmp=$(mktemp)
    curl -fsSL -o "$tmp" "$url" || die "Не удалось скачать бинарник"
    chmod +x "$tmp"
    mv "$tmp" "$INSTALL_DIR/teleproxy"
    info "Установлен: $INSTALL_DIR/teleproxy"

    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        info "Создан системный пользователь: $SERVICE_USER"
    fi

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    chown "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR"

    configure_interactive "binary"

    cat > "$SERVICE_FILE" << 'UNIT'
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
UNIT

    systemctl daemon-reload
    systemctl enable --now teleproxy
    info "Teleproxy запущен как systemd-сервис"

    sleep 2
    if systemctl is-active --quiet teleproxy; then
        info "Сервис работает"
        echo ""
        show_connection_links
    else
        error "Сервис не запустился:"
        journalctl -u teleproxy --no-pager -n 20
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Интерактивная настройка
# ═══════════════════════════════════════════════════════════════════════
configure_interactive() {
    local mode="$1"
    header "Настройка Teleproxy"

    # Порт
    printf "  ${C}Порт для клиентов${NC} [${W}443${NC}]: "
    read -r input_port
    local port="${input_port:-443}"

    # Порт статистики
    printf "  ${C}Порт статистики${NC} [${W}8888${NC}]: "
    read -r input_stats
    local stats_port="${input_stats:-8888}"

    # Воркеры
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    printf "  ${C}Воркеры${NC} [${W}${cpu_count}${NC}] (ядер: ${cpu_count}): "
    read -r input_workers
    local workers="${input_workers:-$cpu_count}"

    # Fake-TLS
    printf "\n  ${C}Включить Fake-TLS маскировку?${NC} [${W}Y${NC}/n]: "
    read -r input_tls
    local ee_domain=""
    if [[ "${input_tls,,}" != "n" ]]; then
        printf "  ${C}Домен для маскировки${NC} [${W}www.google.com${NC}]: "
        read -r input_domain
        ee_domain="${input_domain:-www.google.com}"
    fi

    # Секреты
    printf "\n  ${C}Количество секретов${NC} [${W}1${NC}] (макс. 16): "
    read -r input_count
    local secret_count="${input_count:-1}"
    if ! [[ "$secret_count" =~ ^[0-9]+$ ]] || [ "$secret_count" -lt 1 ] || [ "$secret_count" -gt 16 ]; then
        warn "Некорректное число, используем 1"
        secret_count=1
    fi

    local -a secrets=()
    local -a labels=()
    local -a limits=()

    for ((i=1; i<=secret_count; i++)); do
        local sec
        sec=$(generate_secret)
        secrets+=("$sec")

        if [ "$secret_count" -gt 1 ]; then
            printf "  ${D}Секрет #${i}:${NC} ${W}${sec}${NC}\n"
            printf "    ${C}Метка${NC} [${W}secret_${i}${NC}]: "
            read -r input_label
            labels+=("${input_label:-secret_${i}}")

            printf "    ${C}Лимит подключений${NC} [${W}без лимита${NC}]: "
            read -r input_limit
            limits+=("${input_limit:-}")
        else
            labels+=("default")
            limits+=("")
            printf "  ${D}Секрет:${NC} ${W}${sec}${NC}\n"
        fi
    done

    # Запись конфига
    mkdir -p "$CONFIG_DIR"
    {
        echo "# Teleproxy configuration"
        echo "# Generated by Teleproxy Manager v${SCRIPT_VERSION}"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "port = $port"
        echo "stats_port = $stats_port"
        echo "http_stats = true"
        echo "workers = $workers"
        echo "direct = true"
        if [ "$mode" = "binary" ]; then
            echo "user = \"$SERVICE_USER\""
        fi
        if [ -n "$ee_domain" ]; then
            echo "domain = \"$ee_domain\""
        fi
        echo ""
        for ((i=0; i<${#secrets[@]}; i++)); do
            echo "[[secret]]"
            echo "key = \"${secrets[$i]}\""
            if [ -n "${labels[$i]}" ]; then
                echo "label = \"${labels[$i]}\""
            fi
            if [ -n "${limits[$i]}" ]; then
                echo "limit = ${limits[$i]}"
            fi
            echo ""
        done
    } > "$CONFIG_FILE"

    chmod 640 "$CONFIG_FILE"
    info "Конфигурация сохранена: $CONFIG_FILE"
}

# ── Чтение конфига ─────────────────────────────────────────────────────
read_config_value() {
    local key="$1"
    if [ -f "$CONFIG_FILE" ]; then
        grep -m1 "^${key} " "$CONFIG_FILE" 2>/dev/null | sed 's/.*= *//' | tr -d ' '
    fi
}

extract_secret_blocks() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi
    awk '/^\[\[secret\]\]/{found=1; block=""} found{block=block $0 "\n"} found && /^$/{print block; found=0} END{if(found) print block}' "$CONFIG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════
#  УПРАВЛЕНИЕ
# ═══════════════════════════════════════════════════════════════════════
proxy_start() {
    local method
    method=$(detect_install_method)
    header "Запуск Teleproxy"
    if [ "$method" = "docker" ]; then
        docker start "$DOCKER_NAME"
    else
        systemctl start teleproxy
    fi
    sleep 2
    info "Teleproxy запущен"
    press_enter
}

proxy_stop() {
    local method
    method=$(detect_install_method)
    header "Остановка Teleproxy"
    if [ "$method" = "docker" ]; then
        docker stop "$DOCKER_NAME"
    else
        systemctl stop teleproxy
    fi
    info "Teleproxy остановлен"
    press_enter
}

proxy_restart() {
    local method
    method=$(detect_install_method)
    header "Перезапуск Teleproxy"
    if [ "$method" = "docker" ]; then
        docker restart "$DOCKER_NAME"
    else
        systemctl restart teleproxy
    fi
    sleep 2
    info "Teleproxy перезапущен"
    press_enter
}

proxy_logs() {
    header "Логи Teleproxy (Ctrl+C для выхода)"
    local method
    method=$(detect_install_method)
    if [ "$method" = "docker" ]; then
        docker logs -f --tail 50 "$DOCKER_NAME"
    else
        journalctl -u teleproxy -f --no-pager -n 50
    fi
}

proxy_status() {
    header "Статус и метрики"
    local method
    method=$(detect_install_method)

    if [ "$method" = "docker" ]; then
        echo ""
        printf "  ${W}Docker контейнер:${NC}\n"
        docker ps -a --filter "name=$DOCKER_NAME" --format "table {{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null | head -5
        echo ""
        printf "  ${W}Ресурсы:${NC}\n"
        docker stats --no-stream --format "  CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}  Net I/O: {{.NetIO}}" "$DOCKER_NAME" 2>/dev/null || true
    else
        printf "  ${W}Systemd сервис:${NC}\n"
        systemctl status teleproxy --no-pager 2>/dev/null | head -15
    fi

    echo ""
    local stats_port
    stats_port=$(read_config_value stats_port)
    stats_port="${stats_port:-8888}"
    printf "  ${W}HTTP статистика:${NC}\n"
    local stats
    stats=$(curl -sf "http://127.0.0.1:${stats_port}/stats" 2>/dev/null || echo "Недоступна")
    printf "  %s\n" "$stats" | head -30

    echo ""
    printf "  ${W}Prometheus метрики:${NC} ${UNDERLINE}http://<IP>:${stats_port}/metrics${NC}\n"

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Ссылки подключения
# ═══════════════════════════════════════════════════════════════════════
show_connection_links() {
    header "Ссылки для подключения"

    local ip port ee_domain
    ip=$(get_external_ip)
    ip="${ip:-<YOUR_SERVER_IP>}"

    if [ -f "$CONFIG_FILE" ]; then
        port=$(read_config_value port)
        ee_domain=$(read_config_value domain | tr -d '"')
    fi
    port="${port:-443}"

    local method
    method=$(detect_install_method)

    if [ "$method" = "docker" ]; then
        printf "  ${D}Ссылки из логов Docker:${NC}\n\n"
        docker logs "$DOCKER_NAME" 2>&1 | grep -E "(tg://|t\.me/proxy)" | tail -20
        echo ""
        divider
        echo ""
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Конфиг не найден, генерирую ссылки из стандартных значений"
    fi

    while IFS= read -r block; do
        [ -z "$block" ] && continue
        local key label
        key=$(echo "$block" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
        label=$(echo "$block" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        [ -z "$key" ] && continue

        local full_secret
        if [ -n "$ee_domain" ]; then
            local domain_hex
            domain_hex=$(printf '%s' "$ee_domain" | xxd -ps | tr -d '\n')
            full_secret="ee${key}${domain_hex}"
        else
            full_secret="$key"
        fi

        local tg_link="tg://proxy?server=${ip}&port=${port}&secret=${full_secret}"
        local tm_link="https://t.me/proxy?server=${ip}&port=${port}&secret=${full_secret}"

        if [ -n "$label" ]; then
            printf "  ${W}[${label}]${NC}\n"
        fi
        printf "  ${C}TG:${NC}  %s\n" "$tg_link"
        printf "  ${C}Web:${NC} %s\n" "$tm_link"
        echo ""
    done < <(extract_secret_blocks)

    local stats_port
    stats_port=$(read_config_value stats_port)
    stats_port="${stats_port:-8888}"
    printf "  ${D}QR-коды:${NC} http://${ip}:${stats_port}/link\n"

    if [ "$method" = "binary" ] && [ -x "$INSTALL_DIR/teleproxy" ]; then
        echo ""
        printf "  ${D}QR из CLI:${NC}\n"
        while IFS= read -r block; do
            [ -z "$block" ] && continue
            local key label
            key=$(echo "$block" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
            label=$(echo "$block" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
            [ -z "$key" ] && continue

            local full_secret
            if [ -n "$ee_domain" ]; then
                local domain_hex
                domain_hex=$(printf '%s' "$ee_domain" | xxd -ps | tr -d '\n')
                full_secret="ee${key}${domain_hex}"
            else
                full_secret="$key"
            fi

            local label_arg=""
            [ -n "$label" ] && label_arg="--label $label"
            "$INSTALL_DIR/teleproxy" link --server "$ip" --port "$port" --secret "$full_secret" $label_arg 2>/dev/null || true
        done < <(extract_secret_blocks)
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Управление секретами
# ═══════════════════════════════════════════════════════════════════════
manage_secrets() {
    while true; do
        header "Управление секретами"

        if [ -f "$CONFIG_FILE" ]; then
            printf "  ${W}Текущие секреты:${NC}\n\n"
            local idx=1
            while IFS= read -r block; do
                [ -z "$block" ] && continue
                local key label limit
                key=$(echo "$block" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
                label=$(echo "$block" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
                limit=$(echo "$block" | grep -oP 'limit\s*=\s*\K[0-9]+' || true)
                [ -z "$key" ] && continue

                printf "    ${G}${idx}${NC}) ${W}${key}${NC}"
                [ -n "$label" ] && printf "  ${D}[${label}]${NC}"
                [ -n "$limit" ] && printf "  ${Y}лимит: ${limit}${NC}"
                printf "\n"
                idx=$((idx + 1))
            done < <(extract_secret_blocks)
        else
            warn "Конфиг не найден"
        fi

        printf "\n"
        printf "    ${G}a${NC})  Добавить секрет\n"
        printf "    ${G}d${NC})  Удалить секрет\n"
        printf "    ${G}r${NC})  Перегенерировать все секреты\n"
        printf "    ${G}0${NC})  Назад\n"
        printf "\n  ${BOLD}Выберите:${NC} "
        read -r choice

        case "$choice" in
            a) add_secret ;;
            d) remove_secret ;;
            r) regenerate_secrets ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

add_secret() {
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Конфиг не найден"
    fi

    local sec
    sec=$(generate_secret)
    printf "  ${C}Метка нового секрета${NC}: "
    read -r label
    label="${label:-new_secret}"
    printf "  ${C}Лимит подключений${NC} [без лимита]: "
    read -r limit

    {
        echo ""
        echo "[[secret]]"
        echo "key = \"$sec\""
        echo "label = \"$label\""
        [ -n "$limit" ] && echo "limit = $limit"
        echo ""
    } >> "$CONFIG_FILE"

    info "Секрет добавлен: ${sec}"
    reload_config
}

remove_secret() {
    printf "  ${C}Номер секрета для удаления:${NC} "
    read -r num
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        warn "Введите число"
        return
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Конфиг не найден"
        return
    fi

    local tmp
    tmp=$(mktemp)
    awk -v n="$num" '
        BEGIN { count=0; skip=0 }
        /^\[\[secret\]\]/ { count++; if(count==n) { skip=1; next } }
        skip && /^$/ { skip=0; next }
        skip && /^\[/ { skip=0 }
        !skip { print }
    ' "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"

    info "Секрет #${num} удалён"
    reload_config
}

regenerate_secrets() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Конфиг не найден"
        return
    fi

    local tmp
    tmp=$(mktemp)
    local in_secret=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[\[secret\]\] ]]; then
            in_secret=1
            echo "$line" >> "$tmp"
        elif [ "$in_secret" -eq 1 ] && [[ "$line" =~ ^key ]]; then
            local new_sec
            new_sec=$(generate_secret)
            echo "key = \"$new_sec\"" >> "$tmp"
        else
            if [ "$in_secret" -eq 1 ] && [[ -z "$line" || "$line" =~ ^\[ ]]; then
                in_secret=0
            fi
            echo "$line" >> "$tmp"
        fi
    done < "$CONFIG_FILE"
    mv "$tmp" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"

    info "Все секреты перегенерированы"
    reload_config
}

# ═══════════════════════════════════════════════════════════════════════
#  Настройка Fake-TLS
# ═══════════════════════════════════════════════════════════════════════
configure_faketls() {
    header "Настройка Fake-TLS"

    local current
    current=$(read_config_value domain | tr -d '"')

    if [ -n "$current" ]; then
        printf "  ${D}Текущий домен:${NC} ${W}${current}${NC}\n\n"
    else
        printf "  ${D}Fake-TLS отключён${NC}\n\n"
    fi

    printf "    ${G}1${NC})  Включить / изменить домен\n"
    printf "    ${G}2${NC})  Отключить Fake-TLS\n"
    printf "    ${G}0${NC})  Назад\n"
    printf "\n  ${BOLD}Выберите:${NC} "
    read -r choice

    case "$choice" in
        1)
            printf "  ${C}Домен${NC} [${W}www.google.com${NC}]: "
            read -r domain
            domain="${domain:-www.google.com}"
            if grep -q '^domain ' "$CONFIG_FILE" 2>/dev/null; then
                sed -i "s|^domain .*|domain = \"$domain\"|" "$CONFIG_FILE"
            else
                sed -i "/^port /a domain = \"$domain\"" "$CONFIG_FILE"
            fi
            info "Fake-TLS домен: $domain"
            reload_config
            ;;
        2)
            sed -i '/^domain /d' "$CONFIG_FILE"
            info "Fake-TLS отключён"
            reload_config
            ;;
        0) return ;;
    esac
    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Настройка портов
# ═══════════════════════════════════════════════════════════════════════
configure_ports() {
    header "Настройка портов"

    local current_port current_stats
    current_port=$(read_config_value port)
    current_stats=$(read_config_value stats_port)

    printf "  ${D}Текущий порт клиентов:${NC} ${W}${current_port:-443}${NC}\n"
    printf "  ${D}Текущий порт статистики:${NC} ${W}${current_stats:-8888}${NC}\n\n"

    printf "  ${C}Новый порт клиентов${NC} [${W}${current_port:-443}${NC}]: "
    read -r new_port
    new_port="${new_port:-${current_port:-443}}"

    printf "  ${C}Новый порт статистики${NC} [${W}${current_stats:-8888}${NC}]: "
    read -r new_stats
    new_stats="${new_stats:-${current_stats:-8888}}"

    sed -i "s|^port = .*|port = $new_port|" "$CONFIG_FILE"
    sed -i "s|^stats_port = .*|stats_port = $new_stats|" "$CONFIG_FILE"

    info "Порты обновлены: клиенты=$new_port, статистика=$new_stats"

    local method
    method=$(detect_install_method)
    if [ "$method" = "docker" ]; then
        warn "Для Docker необходимо пересоздать контейнер"
        printf "  ${C}Пересоздать сейчас?${NC} [Y/n]: "
        read -r recreate
        if [[ "${recreate,,}" != "n" ]]; then
            recreate_docker_container
        fi
    else
        reload_config
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  IP-фильтрация
# ═══════════════════════════════════════════════════════════════════════
configure_ip_filter() {
    header "IP-фильтрация"

    printf "    ${G}1${NC})  Настроить блоклист IP (CIDR)\n"
    printf "    ${G}2${NC})  Настроить вайтлист IP (CIDR)\n"
    printf "    ${G}3${NC})  Настроить разрешённые сети для статистики\n"
    printf "    ${G}0${NC})  Назад\n"
    printf "\n  ${BOLD}Выберите:${NC} "
    read -r choice

    case "$choice" in
        1)
            printf "  ${C}Путь к файлу блоклиста${NC} (CIDR, по одному на строку): "
            read -r blocklist_path
            if [ -n "$blocklist_path" ]; then
                if grep -q '^ip_blocklist' "$CONFIG_FILE" 2>/dev/null; then
                    sed -i "s|^ip_blocklist .*|ip_blocklist = \"$blocklist_path\"|" "$CONFIG_FILE"
                else
                    echo "ip_blocklist = \"$blocklist_path\"" >> "$CONFIG_FILE"
                fi
                info "Блоклист: $blocklist_path"
                reload_config
            fi
            ;;
        2)
            printf "  ${C}Путь к файлу вайтлиста${NC} (CIDR, по одному на строку): "
            read -r allowlist_path
            if [ -n "$allowlist_path" ]; then
                if grep -q '^ip_allowlist' "$CONFIG_FILE" 2>/dev/null; then
                    sed -i "s|^ip_allowlist .*|ip_allowlist = \"$allowlist_path\"|" "$CONFIG_FILE"
                else
                    echo "ip_allowlist = \"$allowlist_path\"" >> "$CONFIG_FILE"
                fi
                info "Вайтлист: $allowlist_path"
                reload_config
            fi
            ;;
        3)
            printf "  ${C}CIDR-сети для доступа к статистике${NC} (через запятую, напр. 100.64.0.0/10): "
            read -r stats_nets
            if [ -n "$stats_nets" ]; then
                local formatted
                formatted=$(echo "$stats_nets" | sed 's/,/", "/g')
                if grep -q '^stats_allow_net' "$CONFIG_FILE" 2>/dev/null; then
                    sed -i "s|^stats_allow_net .*|stats_allow_net = [\"$formatted\"]|" "$CONFIG_FILE"
                else
                    echo "stats_allow_net = [\"$formatted\"]" >> "$CONFIG_FILE"
                fi
                info "Сети для статистики обновлены"
                reload_config
            fi
            ;;
        0) return ;;
    esac
    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Расширенные настройки
# ═══════════════════════════════════════════════════════════════════════
advanced_settings() {
    while true; do
        header "Расширенные настройки"
        printf "    ${G}1${NC})  PROXY Protocol (v1/v2) для балансировщиков\n"
        printf "    ${G}2${NC})  SOCKS5 прокси для upstream\n"
        printf "    ${G}3${NC})  Привязка к определённому IP\n"
        printf "    ${G}4${NC})  Предпочитать IPv6\n"
        printf "    ${G}5${NC})  DC Override (переопределить адреса DC)\n"
        printf "    ${G}6${NC})  Интервал DC-проб (мониторинг задержек)\n"
        printf "    ${G}7${NC})  Proxy Tag от @MTProxybot\n"
        printf "    ${G}8${NC})  Макс. соединений\n"
        printf "    ${G}9${NC})  Расширенные настройки секретов (квоты, rate limit, TTL)\n"
        printf "    ${G}0${NC})  Назад\n"
        printf "\n  ${BOLD}Выберите:${NC} "
        read -r choice

        case "$choice" in
            1) toggle_config_bool "proxy_protocol" "PROXY Protocol" ;;
            2)
                printf "  ${C}SOCKS5 прокси${NC} (формат host:port или user:pass@host:port): "
                read -r socks5
                set_config_string "socks5" "$socks5"
                ;;
            3)
                printf "  ${C}Привязать к IP${NC}: "
                read -r bind_addr
                set_config_string "bind" "$bind_addr"
                ;;
            4) toggle_config_bool "ipv6" "Предпочитать IPv6" ;;
            5) configure_dc_override ;;
            6)
                printf "  ${C}Интервал DC-проб в секундах${NC} [${W}30${NC}] (0 — отключить): "
                read -r interval
                set_config_int "dc_probe_interval" "${interval:-30}"
                ;;
            7)
                printf "  ${C}Proxy Tag от @MTProxybot${NC}: "
                read -r tag
                set_config_string "proxy_tag" "$tag"
                ;;
            8)
                printf "  ${C}Макс. соединений${NC} [${W}60000${NC}]: "
                read -r maxconn
                set_config_int "maxconn" "${maxconn:-60000}"
                ;;
            9) configure_secret_advanced ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

toggle_config_bool() {
    local key="$1" name="$2"
    local current
    current=$(read_config_value "$key")
    if [ "$current" = "true" ]; then
        sed -i "/^${key} /d" "$CONFIG_FILE"
        info "${name} отключён"
    else
        if grep -q "^${key} " "$CONFIG_FILE" 2>/dev/null; then
            sed -i "s|^${key} .*|${key} = true|" "$CONFIG_FILE"
        else
            echo "${key} = true" >> "$CONFIG_FILE"
        fi
        info "${name} включён"
    fi
    reload_config
    press_enter
}

set_config_string() {
    local key="$1" value="$2"
    if [ -z "$value" ]; then
        sed -i "/^${key} /d" "$CONFIG_FILE"
        info "${key} удалён из конфига"
    elif grep -q "^${key} " "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key} .*|${key} = \"${value}\"|" "$CONFIG_FILE"
        info "${key} = ${value}"
    else
        echo "${key} = \"${value}\"" >> "$CONFIG_FILE"
        info "${key} = ${value}"
    fi
    reload_config
    press_enter
}

set_config_int() {
    local key="$1" value="$2"
    if [ "$value" = "0" ] || [ -z "$value" ]; then
        sed -i "/^${key} /d" "$CONFIG_FILE"
        info "${key} удалён из конфига"
    elif grep -q "^${key} " "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key} .*|${key} = ${value}|" "$CONFIG_FILE"
        info "${key} = ${value}"
    else
        echo "${key} = ${value}" >> "$CONFIG_FILE"
        info "${key} = ${value}"
    fi
    reload_config
    press_enter
}

configure_dc_override() {
    header "DC Override"
    printf "  ${D}Формат: DC_ID:HOST:PORT (через запятую для нескольких)${NC}\n"
    printf "  ${D}Пример: 2:149.154.167.50:443,2:149.154.167.51:443${NC}\n\n"
    printf "  ${C}DC Override${NC}: "
    read -r dc_input
    if [ -z "$dc_input" ]; then
        sed -i '/^\[\[dc_override\]\]/,/^$/d' "$CONFIG_FILE"
        info "DC Override очищены"
    else
        sed -i '/^\[\[dc_override\]\]/,/^$/d' "$CONFIG_FILE"
        IFS=',' read -ra dcs <<< "$dc_input"
        for dc in "${dcs[@]}"; do
            dc=$(echo "$dc" | tr -d ' ')
            local dc_id dc_host dc_port
            IFS=':' read -r dc_id dc_host dc_port <<< "$dc"
            {
                echo ""
                echo "[[dc_override]]"
                echo "dc = $dc_id"
                echo "host = \"$dc_host\""
                echo "port = $dc_port"
            } >> "$CONFIG_FILE"
        done
        info "DC Override настроены"
    fi
    reload_config
    press_enter
}

configure_secret_advanced() {
    header "Расширенные настройки секретов"

    printf "  ${D}Настройка квот, rate limit, max IPs и срока действия для каждого секрета.${NC}\n\n"

    local idx=1
    while IFS= read -r block; do
        [ -z "$block" ] && continue
        local key label
        key=$(echo "$block" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
        label=$(echo "$block" | grep -oP 'label\s*=\s*"\K[^"]+' || true)
        [ -z "$key" ] && continue
        printf "    ${G}${idx}${NC}) ${key} ${D}[${label}]${NC}\n"
        idx=$((idx + 1))
    done < <(extract_secret_blocks)

    printf "\n  ${C}Номер секрета для настройки${NC}: "
    read -r num
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        return
    fi

    printf "  ${C}Квота (байт, напр. 1073741824 = 1GB)${NC} [без квоты]: "
    read -r quota
    printf "  ${C}Rate limit${NC} (напр. 100mb/h или 1gb/d) [без лимита]: "
    read -r rate_limit
    printf "  ${C}Макс. уникальных IP${NC} [без лимита]: "
    read -r max_ips
    printf "  ${C}Срок действия${NC} (Unix timestamp или ISO 8601) [бессрочно]: "
    read -r expires

    local tmp
    tmp=$(mktemp)
    local count=0
    local in_secret=0
    local done_modify=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[\[secret\]\] ]]; then
            count=$((count + 1))
            in_secret=1
            echo "$line" >> "$tmp"
        elif [ "$in_secret" -eq 1 ] && [ "$count" -eq "$num" ] && [ "$done_modify" -eq 0 ] && [[ -z "$line" || "$line" =~ ^\[ ]]; then
            [ -n "$quota" ] && echo "quota = $quota" >> "$tmp"
            [ -n "$rate_limit" ] && echo "rate_limit = \"$rate_limit\"" >> "$tmp"
            [ -n "$max_ips" ] && echo "max_ips = $max_ips" >> "$tmp"
            [ -n "$expires" ] && echo "expires = $expires" >> "$tmp"
            done_modify=1
            in_secret=0
            echo "$line" >> "$tmp"
        else
            echo "$line" >> "$tmp"
        fi
    done < "$CONFIG_FILE"

    if [ "$in_secret" -eq 1 ] && [ "$count" -eq "$num" ] && [ "$done_modify" -eq 0 ]; then
        [ -n "$quota" ] && echo "quota = $quota" >> "$tmp"
        [ -n "$rate_limit" ] && echo "rate_limit = \"$rate_limit\"" >> "$tmp"
        [ -n "$max_ips" ] && echo "max_ips = $max_ips" >> "$tmp"
        [ -n "$expires" ] && echo "expires = $expires" >> "$tmp"
    fi

    mv "$tmp" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    info "Расширенные настройки секрета #${num} обновлены"
    reload_config
    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Перезагрузка конфига
# ═══════════════════════════════════════════════════════════════════════
reload_config() {
    local method
    method=$(detect_install_method)
    if [ "$method" = "docker" ]; then
        docker exec "$DOCKER_NAME" kill -HUP 1 2>/dev/null && info "Конфиг перезагружен (SIGHUP)" || warn "Не удалось отправить SIGHUP"
    elif [ "$method" = "binary" ]; then
        systemctl reload teleproxy 2>/dev/null && info "Конфиг перезагружен (SIGHUP)" || systemctl restart teleproxy 2>/dev/null
    fi
}

recreate_docker_container() {
    info "Пересоздание Docker контейнера..."
    local port stats_port ee_domain
    port=$(read_config_value port)
    stats_port=$(read_config_value stats_port)
    ee_domain=$(read_config_value domain | tr -d '"')
    port="${port:-443}"
    stats_port="${stats_port:-8888}"

    local env_args=()
    env_args+=(-e "PORT=${port}")
    env_args+=(-e "STATS_PORT=${stats_port}")
    env_args+=(-e "DIRECT_MODE=true")

    if [ -n "$ee_domain" ]; then
        env_args+=(-e "EE_DOMAIN=${ee_domain}")
    fi

    local secrets_csv=""
    while IFS= read -r block; do
        [ -z "$block" ] && continue
        local key
        key=$(echo "$block" | grep -oP 'key\s*=\s*"\K[^"]+' || true)
        [ -z "$key" ] && continue
        [ -n "$secrets_csv" ] && secrets_csv="${secrets_csv},"
        secrets_csv="${secrets_csv}${key}"
    done < <(extract_secret_blocks)

    [ -n "$secrets_csv" ] && env_args+=(-e "SECRET=${secrets_csv}")

    docker stop "$DOCKER_NAME" &>/dev/null || true
    docker rm "$DOCKER_NAME" &>/dev/null || true

    docker run -d --name "$DOCKER_NAME" \
        -p "${port}:${port}" \
        -p "${stats_port}:${stats_port}" \
        --ulimit nofile=65536:65536 \
        --restart unless-stopped \
        "${env_args[@]}" \
        -v "${DATA_DIR}:/opt/teleproxy/data" \
        "$DOCKER_IMAGE"

    sleep 2
    if docker ps --format '{{.Names}}' | grep -qw "$DOCKER_NAME"; then
        info "Контейнер пересоздан и запущен"
    else
        error "Не удалось запустить контейнер"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  Редактирование конфига
# ═══════════════════════════════════════════════════════════════════════
edit_config() {
    header "Редактирование конфига"

    if [ ! -f "$CONFIG_FILE" ]; then
        die "Конфиг не найден: $CONFIG_FILE"
    fi

    printf "  ${W}Текущий конфиг:${NC}\n\n"
    cat -n "$CONFIG_FILE"
    echo ""

    local editor
    editor="${EDITOR:-$(command -v nano || command -v vim || command -v vi || echo "")}"
    if [ -n "$editor" ]; then
        printf "  ${C}Открыть в редакторе (${editor})?${NC} [Y/n]: "
        read -r open_editor
        if [[ "${open_editor,,}" != "n" ]]; then
            "$editor" "$CONFIG_FILE"
            reload_config
        fi
    else
        warn "Редактор не найден. Отредактируйте вручную: $CONFIG_FILE"
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Обновление
# ═══════════════════════════════════════════════════════════════════════
update_proxy() {
    header "Обновление Teleproxy"
    local method
    method=$(detect_install_method)

    if [ "$method" = "docker" ]; then
        info "Обновляем Docker образ..."
        docker pull "$DOCKER_IMAGE"
        recreate_docker_container
    elif [ "$method" = "binary" ]; then
        local arch
        arch=$(detect_arch)
        local url="https://github.com/$GITHUB_REPO/releases/latest/download/teleproxy-linux-${arch}"

        local current_version=""
        current_version=$("$INSTALL_DIR/teleproxy" --version 2>/dev/null | head -1 || echo "unknown")
        printf "  ${D}Текущая версия:${NC} ${W}${current_version}${NC}\n"

        systemctl stop teleproxy 2>/dev/null || true

        info "Скачиваем последнюю версию..."
        local tmp
        tmp=$(mktemp)
        curl -fsSL -o "$tmp" "$url" || die "Не удалось скачать"
        chmod +x "$tmp"
        mv "$tmp" "$INSTALL_DIR/teleproxy"

        systemctl start teleproxy

        local new_version=""
        new_version=$("$INSTALL_DIR/teleproxy" --version 2>/dev/null | head -1 || echo "unknown")
        info "Обновлено до: ${new_version}"
    else
        die "Teleproxy не установлен"
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Резервное копирование
# ═══════════════════════════════════════════════════════════════════════
backup_config() {
    header "Резервное копирование"

    if [ ! -f "$CONFIG_FILE" ]; then
        die "Конфиг не найден"
    fi

    local backup_dir="/root/teleproxy-backups"
    mkdir -p "$backup_dir"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${backup_dir}/config_${timestamp}.toml"
    cp "$CONFIG_FILE" "$backup_file"
    info "Бэкап сохранён: ${backup_file}"

    printf "\n  ${W}Существующие бэкапы:${NC}\n"
    ls -la "$backup_dir"/ 2>/dev/null

    printf "\n  ${C}Восстановить из бэкапа?${NC} [y/N]: "
    read -r restore
    if [[ "${restore,,}" == "y" ]]; then
        printf "  ${C}Файл для восстановления:${NC} "
        read -r restore_file
        if [ -f "$restore_file" ]; then
            cp "$restore_file" "$CONFIG_FILE"
            chmod 640 "$CONFIG_FILE"
            info "Конфиг восстановлен из: $restore_file"
            reload_config
        else
            error "Файл не найден: $restore_file"
        fi
    fi

    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Удаление
# ═══════════════════════════════════════════════════════════════════════
uninstall_proxy() {
    header "Удаление Teleproxy"

    printf "  ${R}Вы уверены, что хотите удалить Teleproxy?${NC}\n"
    printf "  ${C}Введите${NC} ${W}DELETE${NC} ${C}для подтверждения:${NC} "
    read -r confirm
    if [ "$confirm" != "DELETE" ]; then
        info "Отменено"
        press_enter
        return
    fi

    local method
    method=$(detect_install_method)

    if [ "$method" = "docker" ]; then
        docker stop "$DOCKER_NAME" &>/dev/null || true
        docker rm "$DOCKER_NAME" &>/dev/null || true
        docker rmi "$DOCKER_IMAGE" &>/dev/null || true
        info "Docker контейнер и образ удалены"
    fi

    if [ "$method" = "binary" ]; then
        systemctl disable --now teleproxy &>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload &>/dev/null || true
        rm -f "$INSTALL_DIR/teleproxy"
        userdel "$SERVICE_USER" &>/dev/null || true
        info "Бинарник и сервис удалены"
    fi

    printf "  ${C}Удалить конфигурационные файлы?${NC} [y/N]: "
    read -r remove_config
    if [[ "${remove_config,,}" == "y" ]]; then
        rm -rf "$CONFIG_DIR" "$DATA_DIR"
        info "Конфиги удалены"
    else
        info "Конфиги сохранены в $CONFIG_DIR"
    fi

    info "Teleproxy полностью удалён"
    press_enter
}

# ═══════════════════════════════════════════════════════════════════════
#  Главный цикл
# ═══════════════════════════════════════════════════════════════════════
main() {
    check_root
    check_os
    install_deps

    while true; do
        show_banner
        local status
        status=$(detect_status)
        show_main_menu
        read -r choice

        if [ "$status" = "not_installed" ]; then
            case "$choice" in
                1) install_docker ;;
                2) install_binary ;;
                0) printf "\n  ${G}До свидания!${NC}\n\n"; exit 0 ;;
                *) warn "Неверный выбор" ; press_enter ;;
            esac
        else
            case "$choice" in
                1)
                    if [ "$status" = "running" ]; then
                        proxy_stop
                    else
                        proxy_start
                    fi
                    ;;
                2) proxy_restart ;;
                3) proxy_logs ;;
                4) proxy_status ;;
                5) show_connection_links ;;
                6) manage_secrets ;;
                7) configure_faketls ;;
                8) configure_ports ;;
                9) configure_ip_filter ;;
                10) advanced_settings ;;
                11) edit_config ;;
                12) update_proxy ;;
                13) backup_config ;;
                14) uninstall_proxy ;;
                0) printf "\n  ${G}До свидания!${NC}\n\n"; exit 0 ;;
                *) warn "Неверный выбор" ; press_enter ;;
            esac
        fi
    done
}

main "$@"
