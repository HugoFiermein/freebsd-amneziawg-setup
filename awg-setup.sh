#!/bin/sh
# =============================================================================
#  awg-setup.sh — Установщик AmneziaWG + split tunneling для FreeBSD
#
#  Использование:
#    sudo ./awg-setup.sh -c /path/to/vpn.conf [-d "domain1,domain2"] [-i awg0]
#    sudo ./awg-setup.sh -u   # удалить всё
# =============================================================================

set -e

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()     { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
die()    { printf "${RED}[ERR]${RESET}   %s\n" "$*" >&2; exit 1; }
header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$*"; }

# --- Defaults ---
IFACE="awg0"
DOMAINS=""
CONF_FILE=""
UNINSTALL=0
AWG_DIR="/usr/local/etc/amnezia"
LOG_FILE="/var/log/awg-setup.log"

usage() {
    cat <<EOF
Использование: $0 -c <conf_file> [опции]

  -c FILE   Готовый .conf файл AmneziaWG (обязательно)
  -d DOMAIN Домены через запятую (default: rutracker.org)
  -i IFACE  Имя интерфейса (default: awg0)
  -u        Удалить всё
  -h        Эта справка

Пример:
  sudo $0 -c /home/user/vpn.conf -d "rutracker.org,nnmclub.to"
EOF
    exit 0
}

while getopts "c:d:i:uh" opt; do
    case "$opt" in
        c) CONF_FILE="$OPTARG" ;;
        d) DOMAINS="$OPTARG"   ;;
        i) IFACE="$OPTARG"     ;;
        u) UNINSTALL=1         ;;
        h) usage               ;;
        *) usage               ;;
    esac
done

CONF_PATH="${AWG_DIR}/${IFACE}.conf"
ROUTE_SCRIPT="${AWG_DIR}/split-tunnel.sh"
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg"

# =============================================================================
check_root() {
    [ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0 $*"
}

# =============================================================================
do_uninstall() {
    header "Удаление AmneziaWG"

    awg-quick down "${CONF_PATH}" 2>/dev/null || true
    ifconfig "${IFACE}" destroy   2>/dev/null || true

    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    pkg delete -y amnezia-tools amnezia-kmod 2>/dev/null || true
    pkg autoremove -y 2>/dev/null || true

    rm -f "${RC_SCRIPT}" "${LOG_FILE}"
    rm -rf "${AWG_DIR}"

    sed -i '' '/amneziawg/d'   /etc/rc.conf      2>/dev/null || true
    sed -i '' '/if_amn_load/d' /boot/loader.conf  2>/dev/null || true
    sed -i '' '/if_wg_load/d'  /boot/loader.conf  2>/dev/null || true
    sed -i '' '/module_path/d' /boot/loader.conf  2>/dev/null || true

    ok "Удаление завершено"
    exit 0
}

# =============================================================================
check_os() {
    header "Проверка окружения"
    [ "$(uname -s)" = "FreeBSD" ] || die "Только FreeBSD"
    VER=$(uname -r | cut -d. -f1)
    [ "$VER" -ge 13 ] || die "Требуется FreeBSD 13+"
    ok "ОС: FreeBSD $(uname -r)"
}

# =============================================================================
check_conf() {
    header "Конфигурационный файл"
    [ -n "${CONF_FILE}" ] || die "Укажите конфиг: $0 -c /path/to/vpn.conf"
    [ -f "${CONF_FILE}" ] || die "Файл не найден: ${CONF_FILE}"
    grep -q "^Jc" "${CONF_FILE}" \
        && ok "Обнаружены параметры AWG-обфускации (Jc/Jmin/Jmax)" \
        || warn "Параметры Jc/Jmin/Jmax не найдены — возможно обычный WireGuard конфиг"
    ok "Конфиг: ${CONF_FILE}"
}

# =============================================================================
install_packages() {
    header "Установка пакетов"

    # Убедимся что pkg работает
    pkg -N 2>/dev/null || pkg bootstrap -y || die "Не удалось инициализировать pkg"

    # amnezia-tools (awg + awg-quick)
    if pkg info amnezia-tools > /dev/null 2>&1; then
        ok "amnezia-tools уже установлен"
    else
        info "Устанавливаем amnezia-tools..."
        pkg install -y amnezia-tools || die "Не удалось установить amnezia-tools"
        ok "amnezia-tools установлен"
    fi

    # amnezia-kmod (kernel module)
    if pkg info amnezia-kmod > /dev/null 2>&1; then
        ok "amnezia-kmod уже установлен"
    else
        info "Устанавливаем amnezia-kmod..."
        pkg install -y amnezia-kmod || die "Не удалось установить amnezia-kmod"
        ok "amnezia-kmod установлен"
    fi
}

# =============================================================================
load_kmod() {
    header "Модуль ядра"

    if kldstat 2>/dev/null | grep -qE "if_amn|if_wg"; then
        ok "Модуль уже загружен: $(kldstat | grep -E 'if_amn|if_wg' | awk '{print $5}')"
        return
    fi

    info "Загружаем модуль if_amn..."
    kldload if_amn || die "Не удалось загрузить модуль if_amn"
    ok "Модуль загружен: $(kldstat | grep if_amn | awk '{print $5}')"

    if ! grep -q "if_amn_load" /boot/loader.conf 2>/dev/null; then
        echo 'if_amn_load="YES"' >> /boot/loader.conf
        ok "Автозагрузка прописана в /boot/loader.conf"
    fi
}

# =============================================================================
prepare_config() {
    header "Конфигурация"

    mkdir -p "${AWG_DIR}"
    chmod 700 "${AWG_DIR}"

    cp "${CONF_FILE}" "${CONF_PATH}"
    chmod 600 "${CONF_PATH}"

    # Добавляем PostUp/PostDown только для split tunneling режима
    if [ -n "${DOMAINS}" ] && ! grep -q "split-tunnel" "${CONF_PATH}"; then
        sed -i '' "/^\[Interface\]/a\\
PostUp = ${ROUTE_SCRIPT} up %i\\
PostDown = ${ROUTE_SCRIPT} down %i
" "${CONF_PATH}"
    fi

    ok "Конфиг: ${CONF_PATH}"
}

# =============================================================================
create_route_script() {
    header "Split tunneling"

    DOMAINS_LIST=$(echo "$DOMAINS" | tr ',' ' ')

    cat > "${ROUTE_SCRIPT}" << SCRIPT
#!/bin/sh
# split-tunnel.sh — маршрутизация только указанных доменов через AWG

ACTION="\$1"
IFACE="\$2"
DOMAINS="${DOMAINS_LIST}"
STATE_FILE="/var/run/awg-routes-\${IFACE}.txt"
CONF_PATH="${CONF_PATH}"

get_default_gw() {
    netstat -rn -f inet | awk '/^default/{print \$2; exit}'
}

get_server_ip() {
    grep -i "^Endpoint" "\${CONF_PATH}" | head -1 | sed 's/.*= *//' | cut -d: -f1
}

resolve_ips() {
    host -t A "\$1" 2>/dev/null | awk '/has address/{print \$4}' | sort -u
}

do_up() {
    DEFAULT_GW=\$(get_default_gw)
    SERVER_IP=\$(get_server_ip)
    rm -f "\${STATE_FILE}"

    # Маршрут к VPN-серверу через физический шлюз (защита от петли)
    if [ -n "\${SERVER_IP}" ] && [ -n "\${DEFAULT_GW}" ]; then
        route add -host "\${SERVER_IP}" "\${DEFAULT_GW}" 2>/dev/null || true
        echo "\${SERVER_IP}" >> "\${STATE_FILE}"
        logger -t awg-split "VPN server \${SERVER_IP} -> \${DEFAULT_GW}"
    fi

    # Маршруты для доменов через туннель
    for domain in \${DOMAINS}; do
        ips=\$(resolve_ips "\${domain}")
        if [ -z "\${ips}" ]; then
            logger -t awg-split "WARN: не удалось разрезолвить \${domain}"
            continue
        fi
        for ip in \${ips}; do
            route add -host "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            echo "\${ip}" >> "\${STATE_FILE}"
            logger -t awg-split "\${domain} (\${ip}) -> \${IFACE}"
        done
    done
}

do_down() {
    SERVER_IP=\$(get_server_ip)
    [ -n "\${SERVER_IP}" ] && route delete -host "\${SERVER_IP}" 2>/dev/null || true

    if [ -f "\${STATE_FILE}" ]; then
        while IFS= read -r ip; do
            route delete -host "\${ip}" 2>/dev/null || true
        done < "\${STATE_FILE}"
        rm -f "\${STATE_FILE}"
    fi
}

case "\${ACTION}" in
    up)   do_up   ;;
    down) do_down ;;
    *) echo "Usage: \$0 up|down <iface>" >&2; exit 1 ;;
esac
SCRIPT

    chmod +x "${ROUTE_SCRIPT}"
    ok "Скрипт split tunneling: ${ROUTE_SCRIPT}"
}

# =============================================================================
patch_allowed_ips() {
    header "Настройка AllowedIPs"

    SERVER_IP=$(grep -i "^Endpoint" "${CONF_PATH}" | head -1 | sed 's/.*= *//' | cut -d: -f1)
    ALLOWED=""

    [ -n "${SERVER_IP}" ] && ALLOWED="${SERVER_IP}/32" && info "VPN сервер: ${SERVER_IP}/32"

    for domain in $(echo "$DOMAINS" | tr ',' ' '); do
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4}' | sort -u)
        if [ -z "$ips" ]; then
            warn "Не удалось разрезолвить $domain"
            continue
        fi
        for ip in $ips; do
            ok "$domain -> $ip"
            ALLOWED="${ALLOWED:+${ALLOWED}, }${ip}/32"
        done
    done

    if [ -n "$ALLOWED" ]; then
        sed -i '' "s|^AllowedIPs = .*|AllowedIPs = ${ALLOWED}|" "${CONF_PATH}"
        ok "AllowedIPs = ${ALLOWED}"
    else
        warn "Домены не резолвятся — AllowedIPs не изменён"
    fi
}

# =============================================================================
create_rc_script() {
    header "Автозапуск"

    cat > "${RC_SCRIPT}" << RCEOF
#!/bin/sh
# PROVIDE: amneziawg
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="amneziawg"
rcvar="amneziawg_enable"
desc="AmneziaWG VPN"

start_cmd="amneziawg_start"
stop_cmd="amneziawg_stop"
status_cmd="amneziawg_status"

: \${amneziawg_enable:="NO"}
: \${amneziawg_conf:="${CONF_PATH}"}

amneziawg_start() {
    kldstat | grep -qE "if_amn|if_wg" || kldload if_amn
    awg-quick up "\${amneziawg_conf}"
}
amneziawg_stop()   { awg-quick down "\${amneziawg_conf}" 2>/dev/null || true; }
amneziawg_status() {
    ifconfig "${IFACE}" > /dev/null 2>&1 \
        && awg show "${IFACE}" \
        || { echo "Остановлен"; return 1; }
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF

    chmod +x "${RC_SCRIPT}"
    grep -q "amneziawg_enable" /etc/rc.conf 2>/dev/null \
        || echo 'amneziawg_enable="YES"' >> /etc/rc.conf
    ok "Автозапуск настроен"
}

# =============================================================================
start_tunnel() {
    header "Запуск туннеля"

    # Если интерфейс уже существует — опускаем его перед подъёмом
    if ifconfig "${IFACE}" > /dev/null 2>&1; then
        info "Интерфейс ${IFACE} уже существует — перезапускаем..."
        awg-quick down "${CONF_PATH}" 2>/dev/null || ifconfig "${IFACE}" destroy 2>/dev/null || true
        sleep 1
    fi

    # Запускаем awg-quick в отдельной группе процессов чтобы
    # фоновый monitor-daemon не блокировал завершение скрипта
    awg-quick up "${CONF_PATH}" &
    AWG_PID=$!

    # Ждём пока интерфейс поднимется (до 15 секунд)
    i=0
    while [ $i -lt 15 ]; do
        ifconfig "${IFACE}" > /dev/null 2>&1 && break
        sleep 1
        i=$((i + 1))
    done

    ifconfig "${IFACE}" > /dev/null 2>&1 || die "Интерфейс ${IFACE} не появился"
    ok "Туннель ${IFACE} активен"
    awg show "${IFACE}"
}

# =============================================================================
verify() {
    header "Проверка маршрутизации"
    for domain in $(echo "$DOMAINS" | tr ',' ' '); do
        TARGET=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4; exit}')
        if [ -n "$TARGET" ]; then
            ROUTE_IFACE=$(route get "$TARGET" 2>/dev/null | awk '/interface:/{print $2}')
            if [ "$ROUTE_IFACE" = "${IFACE}" ]; then
                ok "${domain} (${TARGET}) -> ${IFACE} ✓"
            else
                warn "${domain} (${TARGET}) идёт через ${ROUTE_IFACE}, не через ${IFACE}"
            fi
        fi
    done
    if [ -n "${DOMAINS}" ]; then
        info "Внешний IP (должен быть IP провайдера, не VPN):"
    else
        info "Внешний IP (должен быть IP VPN сервера):"
    fi
    fetch -qo - https://api.ipify.org 2>/dev/null && echo "" || true
}

# =============================================================================
print_summary() {
    printf "\n${BOLD}${GREEN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║           AmneziaWG успешно настроен!                    ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    printf "${BOLD}Туннель:${RESET}     %s\n"  "${IFACE}"
    [ -n "${DOMAINS}" ] && printf "${BOLD}Домены:${RESET}      %s\n" "${DOMAINS}" || printf "${BOLD}Режим:${RESET}       Весь трафик через VPN\n"
    printf "${BOLD}Конфиг:${RESET}      %s\n"  "${CONF_PATH}"
    printf "${BOLD}Лог:${RESET}         %s\n\n" "${LOG_FILE}"
    printf "${BOLD}Управление:${RESET}\n"
    printf "  Статус:   ${CYAN}service amneziawg status${RESET}\n"
    printf "  Стоп:     ${CYAN}service amneziawg stop${RESET}\n"
    printf "  Старт:    ${CYAN}service amneziawg start${RESET}\n"
    printf "  Маршруты: ${CYAN}netstat -rn | grep %s${RESET}\n" "${IFACE}"
    printf "  Удалить:  ${CYAN}sudo $0 -u${RESET}\n\n"
}

# =============================================================================
main() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║    AmneziaWG Setup + Split Tunneling для FreeBSD         ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"

    check_root "$@"
    [ "${UNINSTALL}" -eq 1 ] && do_uninstall

    check_os
    check_conf
    install_packages
    load_kmod
    prepare_config
    if [ -n "${DOMAINS}" ]; then
        create_route_script
    fi
    create_rc_script
    start_tunnel
    # AllowedIPs патчим ПОСЛЕ поднятия туннеля — DNS уже работает через VPN
    if [ -n "${DOMAINS}" ]; then
        patch_allowed_ips
        # Перезапускаем туннель чтобы применить новые AllowedIPs
        info "Применяем обновлённые AllowedIPs..."
        awg-quick down "${CONF_PATH}" 2>/dev/null || true
        sleep 1
        awg-quick up "${CONF_PATH}" &
        sleep 3
    else
        info "Домены не указаны — весь трафик идёт через VPN (AllowedIPs из конфига)"
    fi
    verify
    print_summary
}

# Запуск с логированием
main "$@" 2>&1 | tee -a "${LOG_FILE}"
exit ${PIPESTATUS[0]}
