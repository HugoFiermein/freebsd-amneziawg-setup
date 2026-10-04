#!/bin/sh
# =============================================================================
#  awg3-setup.sh — Автоматический установщик AmneziaWG 3.1 (AWG3) для FreeBSD
#
#  Поддерживает протокол AmneziaWG 3.1:
#    - HeaderProtectionKey (ChaCha20 шифрование заголовков пакетов)
#    - ContentPaddingAddition (динамический транспортный паддинг)
#    - RandomTrailers (рандомизация трейлеров до MTU)
#    - DisableCookies (отключение cookie-ответов против сканирования)
#    - RekeyAfterTime, RekeyTimeout, MaxHandshakeAttempts и др.
#
#  Полная автоматизация:
#    1. Автоматически зачищает старую версию AWG 2.x (пакеты, сервисы, модуль).
#    2. Собирает драйвер ядра wireguard-amnezia-kmod v3.1.0 с поддержкой HeaderProtectionKey.
#    3. Собирает утилиты awg/awg-quick v3.1 с поддержкой FreeBSD IPC.
#    4. Настраивает автозапуск сервиса amneziawg3 и раздельное туннелирование.
#
#  Использование:
#    sudo ./awg3-setup.sh -c /path/to/vpn.conf [-d "domain1,domain2"] [-i awg0]
#    sudo ./awg3-setup.sh -u   # удалить всё
# =============================================================================

set -e

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; RESET='\033[0m'

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
AWG_DIR="/usr/local/etc/amnezia3"
LOG_FILE="/var/log/awg3-setup.log"

usage() {
    cat <<EOF
Использование: $0 -c <conf_file> [опции]

  -c FILE   Готовый .conf файл AmneziaWG 3.1 (обязательно)
  -d DOMAIN Домены или IP/CIDR через запятую для раздельного туннелирования
            (по умолчанию: не задано — весь трафик идёт через VPN)
  -i IFACE  Имя интерфейса (default: awg0)
  -u        Удалить всё (AmneziaWG 3.1)
  -h        Эта справка

Примеры:
  # Полный туннель AWG 3.1 (весь интернет через VPN):
  sudo $0 -c /home/user/awg3.conf

  # Раздельное туннелирование AWG 3.1 (трафик только для выбранных доменов и подсетей):
  sudo $0 -c /home/user/awg3.conf -d "rutracker.org,nnmclub.to,198.51.100.0/24"
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
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg3"

# =============================================================================
check_root() {
    [ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0 $*"
}

# =============================================================================
do_uninstall() {
    header "Удаление AmneziaWG 3.1"

    if [ -x "${RC_SCRIPT}" ]; then
        service amneziawg3 stop 2>/dev/null || true
    fi
    awg-quick down "${CONF_PATH}" 2>/dev/null || true
    ifconfig "${IFACE}" destroy   2>/dev/null || true

    kldunload if_wg  2>/dev/null || true
    kldunload if_amn 2>/dev/null || true

    rm -f "${RC_SCRIPT}" "${LOG_FILE}"
    rm -rf "${AWG_DIR}"
    rm -f /boot/modules/if_wg.ko /boot/modules/if_amn.ko
    rm -f /usr/local/bin/awg /usr/local/bin/awg-quick

    sed -i '' '/amneziawg3/d'  /etc/rc.conf     2>/dev/null || true
    sed -i '' '/if_wg_load/d'  /boot/loader.conf 2>/dev/null || true
    sed -i '' '/if_amn_load/d' /boot/loader.conf 2>/dev/null || true

    ok "Удаление AmneziaWG 3.1 завершено"
    exit 0
}

# =============================================================================
check_os() {
    header "Проверка окружения"
    [ "$(uname -s)" = "FreeBSD" ] || die "Только FreeBSD"
    VER=$(uname -r | cut -d. -f1)
    [ "$VER" -ge 13 ] || die "Требуется FreeBSD 13+"
    ok "ОС: FreeBSD $(uname -r)"

    if [ ! -d "/usr/src/sys" ]; then
        warn "Исходные тексты ядра /usr/src/sys не обнаружены."
        info "Устанавливаем исходники системы для сборки модуля ядра..."
        pkg install -y git || true
        git clone --depth 1 -b "releng/$(uname -r | cut -d- -f1,2)" https://git.freebsd.org/src.git /usr/src || \
            die "Не удалось получить исходники ядра в /usr/src"
        ok "Исходники ядра /usr/src готовы"
    else
        ok "Исходники ядра /usr/src/sys найдены"
    fi
}

# =============================================================================
check_conf() {
    header "Анализ конфигурационного файла AWG 3.1"
    [ -n "${CONF_FILE}" ] || die "Укажите конфиг: $0 -c /path/to/awg3.conf"
    [ -f "${CONF_FILE}" ] || die "Файл не найден: ${CONF_FILE}"

    HAS_AWG3=0
    HAS_AWG2=0

    # Проверка параметров AWG 3.1
    if grep -qiE "^ *(HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime)" "${CONF_FILE}"; then
        HAS_AWG3=1
        ok "Обнаружены расширенные параметры протокола AWG 3.1:"
        grep -iE "^ *(HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime)" "${CONF_FILE}" | while read -r line; do
            key=$(echo "$line" | cut -d= -f1 | tr -d ' ')
            printf "     * %s\n" "$key"
        done
    fi

    # Проверка базовых параметров обфускации
    if grep -qiE "^ *(Jc|Jmin|Jmax|H1|H2|H3|H4|S1|S2|S3|S4)" "${CONF_FILE}"; then
        HAS_AWG2=1
        ok "Обнаружены параметры обфускации (Jc/Jmin/H1-H4/S1-S4)"
    fi

    if [ "$HAS_AWG3" -eq 1 ]; then
        printf "${GREEN}${BOLD}>> Протокол: AmneziaWG 3.1 (активная защита заголовков ChaCha20 + Transport Padding)${RESET}\n"
    elif [ "$HAS_AWG2" -eq 1 ]; then
        info "Конфиг содержит параметры AWG 2.x"
    else
        warn "Конфиг выглядит как стандартный WireGuard"
    fi

    ok "Конфиг: ${CONF_FILE}"
}

# =============================================================================
cleanup_old_awg() {
    header "Очистка компонентов предыдущей версии AmneziaWG"

    # Остановка старого сервиса amneziawg (v2), если он запущен
    if service amneziawg status >/dev/null 2>&1 || ifconfig awg0 >/dev/null 2>&1; then
        info "Останавливаем запущенный туннель/сервис предыдущей версии..."
        service amneziawg stop 2>/dev/null || true
        awg-quick down /usr/local/etc/amnezia/awg0.conf 2>/dev/null || true
        ifconfig awg0 destroy 2>/dev/null || true
    fi

    # Отключение автозапуска старого сервиса
    sysrc amneziawg_enable="NO" 2>/dev/null || true
    sed -i '' '/amneziawg_enable/d' /etc/rc.conf 2>/dev/null || true

    # Выгрузка старых модулей ядра
    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    # Удаление несовместимых пакетов AWG 1/2 из pkg (они не знают HeaderProtectionKey)
    if pkg info amnezia-tools >/dev/null 2>&1 || pkg info amnezia-kmod >/dev/null 2>&1; then
        info "Удаляем устаревшие пакеты amnezia-tools/amnezia-kmod из pkg..."
        pkg delete -y amnezia-tools amnezia-kmod 2>/dev/null || true
        pkg autoremove -y 2>/dev/null || true
    fi

    ok "Система очищена от конфликтующих компонентов AWG 2.x"
}

# =============================================================================
build_and_install_awg3() {
    header "Сборка и установка компонентов AmneziaWG 3.1"

    # Установка инструментов сборки
    info "Установка сборочных утилит (git, gmake)..."
    pkg -N 2>/dev/null || pkg bootstrap -y || die "Не удалось инициализировать pkg"
    pkg install -y git gmake bash || die "Не удалось установить git и gmake"

    # 1. Сборка драйвера ядра wireguard-amnezia-kmod (v3.1.0)
    info "Сборка модуля ядра wireguard-amnezia-kmod v3.1.0..."
    KMOD_BUILD_DIR="/tmp/awg3-kmod-build"
    rm -rf "${KMOD_BUILD_DIR}"
    git clone --depth 1 -b v3.1.0 https://github.com/vgrebenschikov/wireguard-amnezia-kmod.git "${KMOD_BUILD_DIR}" || \
        die "Не удалось клонировать wireguard-amnezia-kmod"

    make -C "${KMOD_BUILD_DIR}" clean
    make -C "${KMOD_BUILD_DIR}" || die "Ошибка компиляции модуля ядра wireguard-amnezia-kmod"
    make -C "${KMOD_BUILD_DIR}" install || die "Ошибка установки модуля ядра wireguard-amnezia-kmod"
    rm -rf "${KMOD_BUILD_DIR}"
    ok "Драйвер ядра AmneziaWG 3.1 собран и установлен в /boot/modules/if_wg.ko"

    # 2. Сборка утилит amneziawg-tools с поддержкой AWG 3.1 и FreeBSD IPC (PR #77)
    info "Сборка утилит awg и awg-quick (AWG 3.1)..."
    TOOLS_BUILD_DIR="/tmp/awg3-tools-build"
    rm -rf "${TOOLS_BUILD_DIR}"
    git clone https://github.com/amnezia-vpn/amneziawg-tools.git "${TOOLS_BUILD_DIR}" || \
        die "Не удалось клонировать amneziawg-tools"

    # Подтягиваем патчи FreeBSD IPC для AWG 3.1 (PR #77 от vgrebenschikov)
    git -C "${TOOLS_BUILD_DIR}" fetch origin pull/77/head:awg31 || die "Не удалось загрузить патч PR #77"
    git -C "${TOOLS_BUILD_DIR}" checkout awg31

    gmake -C "${TOOLS_BUILD_DIR}/src" clean
    gmake -C "${TOOLS_BUILD_DIR}/src" PREFIX=/usr/local || die "Ошибка компиляции amneziawg-tools"
    gmake -C "${TOOLS_BUILD_DIR}/src" PREFIX=/usr/local install || die "Ошибка установки amneziawg-tools"
    rm -rf "${TOOLS_BUILD_DIR}"

    # Проверка, что awg теперь знает HeaderProtectionKey
    if strings /usr/local/bin/awg 2>/dev/null | grep -qi "header-protection-key"; then
        ok "Утилита awg 3.1 успешно установлена (поддержка HeaderProtectionKey подтверждена)"
    else
        warn "Утилита awg установлена, но сигнатура HeaderProtectionKey не найдена"
    fi
}

# =============================================================================
load_kmod() {
    header "Загрузка модуля ядра AWG 3.1"

    # Выгружаем любые остаточные модули
    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    info "Загружаем модуль if_wg (v3.1.0)..."
    kldload /boot/modules/if_wg.ko || die "Не удалось загрузить модуль /boot/modules/if_wg.ko"
    LOADED_MOD=$(kldstat | grep -E 'if_wg|if_amn' | awk '{print $5}' | head -1)
    ok "Модуль ядра загружен: ${LOADED_MOD}"

    # Настройка автозагрузки в /boot/loader.conf
    sed -i '' '/if_amn_load/d' /boot/loader.conf 2>/dev/null || true
    if ! grep -q "if_wg_load" /boot/loader.conf 2>/dev/null; then
        echo 'if_wg_load="YES"' >> /boot/loader.conf
        ok "Автозагрузка if_wg прописана в /boot/loader.conf"
    fi
}

# =============================================================================
prepare_config() {
    header "Конфигурация AWG 3.1"

    mkdir -p "${AWG_DIR}"
    chmod 700 "${AWG_DIR}"

    cp "${CONF_FILE}" "${CONF_PATH}"
    chmod 600 "${CONF_PATH}"

    # Настройка раздельного туннелирования при указании доменов/сетей (-d)
    if [ -n "${DOMAINS}" ]; then
        if ! grep -qi "^Table" "${CONF_PATH}"; then
            sed -i '' "/^\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/a\\
Table = off
" "${CONF_PATH}"
        fi
        if ! grep -q "split-tunnel" "${CONF_PATH}"; then
            sed -i '' "/^\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/a\\
PostUp = ${ROUTE_SCRIPT} up %i\\
PostDown = ${ROUTE_SCRIPT} down %i
" "${CONF_PATH}"
        fi
        ok "Режим: Раздельное туннелирование AWG 3.1 (Table = off + селективная маршрутизация)"
    else
        ok "Режим: Полный туннель AWG 3.1 (весь трафик через VPN)"
    fi

    ok "Конфиг сохранён: ${CONF_PATH}"
}

# =============================================================================
create_route_script() {
    header "Split tunneling AWG 3.1"

    DOMAINS_LIST=$(echo "$DOMAINS" | tr ',' ' ')

    cat > "${ROUTE_SCRIPT}" << SCRIPT
#!/bin/sh
# split-tunnel.sh — селективная маршрутизация доменов и подсетей через AmneziaWG 3.1

ACTION="\$1"
IFACE="\$2"
DOMAINS="${DOMAINS_LIST}"
STATE_FILE="/var/run/awg3-routes-\${IFACE}.txt"
CONF_PATH="${CONF_PATH}"

get_default_gw() {
    netstat -rn -f inet | awk '/^default/{print \$2; exit}'
}

get_server_endpoint() {
    grep -i "^Endpoint" "\${CONF_PATH}" 2>/dev/null | head -1 | sed 's/.*= *//' | tr -d ' ' | cut -d: -f1
}

get_server_ip() {
    ENDPOINT=\$(get_server_endpoint)
    [ -z "\${ENDPOINT}" ] && return
    if echo "\${ENDPOINT}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "\${ENDPOINT}"
    else
        host -t A "\${ENDPOINT}" 2>/dev/null | awk '/has address/{print \$4; exit}'
    fi
}

get_dns_ip() {
    grep -i "^DNS" "\${CONF_PATH}" 2>/dev/null | head -1 | sed 's/.*= *//' | tr -d ' ' | cut -d, -f1
}

resolve_ips() {
    TARGET="\$1"
    if echo "\${TARGET}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
        echo "\${TARGET}"
    else
        host -t A "\${TARGET}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u
    fi
}

do_up() {
    DEFAULT_GW=\$(get_default_gw)
    SERVER_IP=\$(get_server_ip)
    DNS_IP=\$(get_dns_ip)
    rm -f "\${STATE_FILE}"

    # Маршрут к VPN-серверу через физический шлюз (защита от петли)
    if [ -n "\${SERVER_IP}" ] && [ -n "\${DEFAULT_GW}" ]; then
        route add -host "\${SERVER_IP}" "\${DEFAULT_GW}" 2>/dev/null || true
        echo "server:\${SERVER_IP}" >> "\${STATE_FILE}"
        logger -t awg3-split "VPN server \${SERVER_IP} -> \${DEFAULT_GW}"
    fi

    # Маршрут к DNS-серверу туннеля через интерфейс AWG 3.1
    if [ -n "\${DNS_IP}" ] && echo "\${DNS_IP}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        route add -host "\${DNS_IP}" -interface "\${IFACE}" 2>/dev/null || true
        echo "route:\${DNS_IP}" >> "\${STATE_FILE}"
        logger -t awg3-split "VPN DNS \${DNS_IP} -> \${IFACE}"
    fi

    # Маршруты для доменов и подсетей
    for domain in \${DOMAINS}; do
        ips=\$(resolve_ips "\${domain}")
        if [ -z "\${ips}" ]; then
            logger -t awg3-split "WARN: не удалось разрезолвить \${domain}"
            continue
        fi
        for ip in \${ips}; do
            if echo "\${ip}" | grep -q '/'; then
                route add -net "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            else
                route add -host "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            fi
            echo "route:\${ip}" >> "\${STATE_FILE}"
            logger -t awg3-split "\${domain} (\${ip}) -> \${IFACE}"
        done
    done
}

do_down() {
    if [ -f "\${STATE_FILE}" ]; then
        while IFS= read -r line; do
            TYPE=\$(echo "\${line}" | cut -d: -f1)
            TARGET=\$(echo "\${line}" | cut -d: -f2)
            [ -z "\${TARGET}" ] && continue
            if [ "\${TYPE}" = "server" ]; then
                route delete -host "\${TARGET}" 2>/dev/null || true
            elif [ "\${TYPE}" = "route" ]; then
                if echo "\${TARGET}" | grep -q '/'; then
                    route delete -net "\${TARGET}" 2>/dev/null || true
                else
                    route delete -host "\${TARGET}" 2>/dev/null || true
                fi
            fi
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
create_rc_script() {
    header "Автозапуск сервиса amneziawg3"

    cat > "${RC_SCRIPT}" << RCEOF
#!/bin/sh
# PROVIDE: amneziawg3
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="amneziawg3"
rcvar="amneziawg3_enable"
desc="AmneziaWG 3.1 VPN Service"

start_cmd="amneziawg3_start"
stop_cmd="amneziawg3_stop"
status_cmd="amneziawg3_status"

: \${amneziawg3_enable:="NO"}
: \${amneziawg3_conf:="${CONF_PATH}"}

amneziawg3_start() {
    kldstat | grep -qE "if_wg|if_amn" || kldload /boot/modules/if_wg.ko
    awg-quick up "\${amneziawg3_conf}"
}
amneziawg3_stop()   { awg-quick down "\${amneziawg3_conf}" 2>/dev/null || true; }
amneziawg3_status() {
    ifconfig "${IFACE}" > /dev/null 2>&1 \
        && awg show "${IFACE}" \
        || { echo "Остановлен"; return 1; }
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF

    chmod +x "${RC_SCRIPT}"
    grep -q "amneziawg3_enable" /etc/rc.conf 2>/dev/null \
        || echo 'amneziawg3_enable="YES"' >> /etc/rc.conf
    ok "Автозапуск сервиса amneziawg3 настроен в /etc/rc.conf"
}

# =============================================================================
start_tunnel() {
    header "Запуск туннеля AWG 3.1"

    # Если интерфейс уже существует — опускаем
    if ifconfig "${IFACE}" > /dev/null 2>&1; then
        info "Интерфейс ${IFACE} уже активен — перезапуск..."
        awg-quick down "${CONF_PATH}" 2>/dev/null || ifconfig "${IFACE}" destroy 2>/dev/null || true
        sleep 1
    fi

    info "Поднимаем туннель AWG 3.1 через awg-quick..."
    awg-quick up "${CONF_PATH}" || die "Не удалось запустить AmneziaWG 3.1"

    ifconfig "${IFACE}" > /dev/null 2>&1 || die "Интерфейс ${IFACE} не появился"
    ok "Туннель ${IFACE} (AmneziaWG 3.1) активен"
    awg show "${IFACE}"
}

# =============================================================================
verify() {
    header "Проверка работы"
    if [ -n "${DOMAINS}" ]; then
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
        info "Внешний IP (должен быть IP вашего провайдера):"
    else
        info "Внешний IP (должен быть IP VPN-сервера AWG 3.1):"
    fi
    fetch -qo - https://api.ipify.org 2>/dev/null && echo "" || true
}

# =============================================================================
print_summary() {
    printf "\n${BOLD}${MAGENTA}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║        AmneziaWG 3.1 (AWG3) успешно настроен!            ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    printf "${BOLD}Протокол:${RESET}    AmneziaWG 3.1 (Header Protection + Transport Padding)\n"
    printf "${BOLD}Туннель:${RESET}     %s\n"  "${IFACE}"
    [ -n "${DOMAINS}" ] && printf "${BOLD}Домены/IP:${RESET}   %s\n" "${DOMAINS}" || printf "${BOLD}Режим:${RESET}       Весь трафик через VPN\n"
    printf "${BOLD}Конфиг:${RESET}      %s\n"  "${CONF_PATH}"
    printf "${BOLD}Лог:${RESET}         %s\n\n" "${LOG_FILE}"
    printf "${BOLD}Управление сервисом:${RESET}\n"
    printf "  Статус:   ${CYAN}service amneziawg3 status${RESET}\n"
    printf "  Стоп:     ${CYAN}service amneziawg3 stop${RESET}\n"
    printf "  Старт:    ${CYAN}service amneziawg3 start${RESET}\n"
    printf "  Маршруты: ${CYAN}netstat -rn | grep %s${RESET}\n" "${IFACE}"
    printf "  Логи:     ${CYAN}grep awg3-split /var/log/messages${RESET}\n"
    printf "  Удалить:  ${CYAN}sudo $0 -u${RESET}\n\n"
}

# =============================================================================
main() {
    printf "${BOLD}${MAGENTA}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║  AmneziaWG 3.1 (AWG3) Setup + Split Tunneling (FreeBSD)  ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"

    check_root "$@"
    [ "${UNINSTALL}" -eq 1 ] && do_uninstall

    check_os
    check_conf
    cleanup_old_awg
    build_and_install_awg3
    load_kmod
    prepare_config
    if [ -n "${DOMAINS}" ]; then
        create_route_script
    fi
    create_rc_script
    start_tunnel
    verify
    print_summary
}

# =============================================================================
# Запуск с логированием (POSIX /bin/sh совместимый захват кода возврата)
# =============================================================================
if [ -z "${_AWG3_LOGGED}" ]; then
    export _AWG3_LOGGED=1
    TMP_EXIT="/tmp/awg3-exit.$$"
    (
        trap 'echo $? > "${TMP_EXIT}"' EXIT
        main "$@"
    ) 2>&1 | tee -a "${LOG_FILE}"
    EXIT_STATUS=1
    if [ -f "${TMP_EXIT}" ]; then
        EXIT_STATUS=$(cat "${TMP_EXIT}")
        rm -f "${TMP_EXIT}"
    fi
    exit "${EXIT_STATUS}"
else
    main "$@"
fi
