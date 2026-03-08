#!/bin/sh
# =============================================================================
#  awg-setup.sh — Установщик AmneziaWG + split tunneling для FreeBSD 15
#
#  Использование:
#    chmod +x awg-setup.sh
#    sudo ./awg-setup.sh -c /path/to/vpn.conf [-d "domain1,domain2"] [-i awg0]
#
#  Опции:
#    -c FILE   Путь к .conf файлу AmneziaWG (обязательно)
#    -d DOMAIN Домены через запятую (default: rutracker.org)
#    -i IFACE  Имя интерфейса (default: awg0)
#    -u        Удалить всё (uninstall)
#    -h        Справка
# =============================================================================

set -e

# --------------------------------------------------------------------------- #
#  Цвета
# --------------------------------------------------------------------------- #
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()     { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
die()    { printf "${RED}[ERR]${RESET}   %s\n" "$*" >&2; exit 1; }
header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$*"; }

# --------------------------------------------------------------------------- #
#  Defaults
# --------------------------------------------------------------------------- #
IFACE="awg0"
DOMAINS="rutracker.org"
CONF_FILE=""
UNINSTALL=0
AWG_DIR="/usr/local/etc/amneziawg"
CONF_PATH=""
ROUTE_SCRIPT=""
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg"
LOG_FILE="/var/log/awg-setup.log"
BUILD_DIR="/tmp/awg-build"

# Отключаем git credential prompt глобально для этого процесса
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=echo

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
        d) DOMAINS="$OPTARG" ;;
        i) IFACE="$OPTARG" ;;
        u) UNINSTALL=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

CONF_PATH="${AWG_DIR}/${IFACE}.conf"
ROUTE_SCRIPT="${AWG_DIR}/split-tunnel.sh"

# --------------------------------------------------------------------------- #
#  Проверка root
# --------------------------------------------------------------------------- #
check_root() {
    [ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo $0 $*"
}

# --------------------------------------------------------------------------- #
#  UNINSTALL
# --------------------------------------------------------------------------- #
do_uninstall() {
    header "Удаление AmneziaWG"

    # Останавливаем туннель
    awg-quick down "${CONF_PATH}" 2>/dev/null || true
    # На случай если интерфейс завис
    ifconfig "${IFACE}" destroy 2>/dev/null || true

    # Выгружаем модуль ядра
    kldunload if_wg 2>/dev/null || true

    # Удаляем бинарники (собранные через make install, не через pkg)
    rm -f /usr/local/bin/awg           /usr/local/bin/awg-quick           /usr/local/share/man/man8/awg.8           /usr/local/share/man/man8/awg-quick.8           /usr/local/share/bash-completion/completions/awg           /usr/local/share/bash-completion/completions/awg-quick

    # Удаляем AWG kmod из /boot/modules
    # (стандартный /boot/kernel/if_wg.ko НЕ трогаем — он системный)
    rm -f /boot/modules/if_wg.ko
    kldxref /boot/modules 2>/dev/null || true

    # Удаляем конфиги и скрипты
    rm -f "${RC_SCRIPT}" "${LOG_FILE}"
    rm -rf "${AWG_DIR}"

    # Удаляем временные директории сборки
    rm -rf "${BUILD_DIR}"
    rm -rf /tmp/wireguard-amnezia-kmod
    rm -rf /tmp/amneziawg-kmod
    rm -rf /tmp/awg-build

    # Чистим rc.conf
    sed -i '' '/amneziawg/d' /etc/rc.conf 2>/dev/null || true

    # Чистим loader.conf
    sed -i '' '/amneziawg/d'    /boot/loader.conf 2>/dev/null || true
    sed -i '' '/if_wg_load/d'   /boot/loader.conf 2>/dev/null || true
    sed -i '' '/module_path/d'  /boot/loader.conf 2>/dev/null || true

    # Удаляем маршруты если остались
    route delete -host 64.188.81.146 2>/dev/null || true

    ok "Удаление завершено. Система чиста."
    ok "Стандартный /boot/kernel/if_wg.ko НЕ тронут."
    exit 0
}

# --------------------------------------------------------------------------- #
#  Шаг 1: Проверка ОС
# --------------------------------------------------------------------------- #
check_os() {
    header "Проверка окружения"
    [ "$(uname -s)" = "FreeBSD" ] || die "Только FreeBSD"
    VER=$(uname -r | cut -d. -f1)
    [ "$VER" -ge 14 ] || die "Требуется FreeBSD 14+"
    ok "ОС: FreeBSD $(uname -r)"

    [ -d /usr/src/sys ] || die "/usr/src/sys не найден. Установите исходники ядра: freebsd-update fetch install"
    ok "Исходники ядра: /usr/src/sys"
}

# --------------------------------------------------------------------------- #
#  Шаг 2: Проверка конфига
# --------------------------------------------------------------------------- #
check_conf() {
    header "Конфигурационный файл"
    [ -n "${CONF_FILE}" ] || die "Укажите конфиг: $0 -c /path/to/vpn.conf"
    [ -f "${CONF_FILE}" ] || die "Файл не найден: ${CONF_FILE}"

    # Проверяем что это AWG конфиг (есть параметры обфускации)
    if grep -q "^Jc" "${CONF_FILE}"; then
        ok "Обнаружены параметры AWG-обфускации (Jc/Jmin/Jmax)"
    else
        warn "Параметры Jc/Jmin/Jmax не найдены — возможно обычный WireGuard конфиг"
    fi
    ok "Конфиг: ${CONF_FILE}"
}

# --------------------------------------------------------------------------- #
#  Шаг 3: Установка git и gmake если нет
# --------------------------------------------------------------------------- #
install_deps() {
    header "Зависимости сборки"

    NEED_PKGS=""
    command -v git   > /dev/null 2>&1 || NEED_PKGS="${NEED_PKGS} git"
    command -v gmake > /dev/null 2>&1 || NEED_PKGS="${NEED_PKGS} gmake"

    if [ -n "${NEED_PKGS}" ]; then
        info "Устанавливаем:${NEED_PKGS}..."
        pkg install -y ${NEED_PKGS} || die "Не удалось установить зависимости"
        ok "Установлено:${NEED_PKGS}"
    else
        ok "git и gmake уже установлены"
    fi
}

# --------------------------------------------------------------------------- #
#  Шаг 4: Сборка и установка amneziawg-tools (FreeBSD-native форк)
# --------------------------------------------------------------------------- #
install_awg_tools() {
    header "Установка amneziawg-tools"

    # Уже установлен нужный вариант? Проверяем что это FreeBSD-native версия
    # (она не требует amneziawg-go и работает с kernel module напрямую)
    if [ -x /usr/local/bin/awg ] && [ -x /usr/local/bin/awg-quick ]; then
        # Проверяем что awg-quick не пытается вызвать amneziawg-go
        if grep -q "amneziawg-go" /usr/local/bin/awg-quick 2>/dev/null; then
            warn "Установлен Linux-вариант awg-quick (требует amneziawg-go). Переустанавливаем FreeBSD-native версию..."
            rm -f /usr/local/bin/awg /usr/local/bin/awg-quick
        else
            ok "awg и awg-quick (FreeBSD-native) уже установлены"
            return
        fi
    fi

    rm -rf "${BUILD_DIR}/amneziawg-tools"
    mkdir -p "${BUILD_DIR}"

    # Используем FreeBSD-native форк vgrebenschikov — он работает с kmod напрямую,
    # без amneziawg-go, и поддерживает все параметры AWG-обфускации
    info "Клонируем amneziawg-tools (FreeBSD-native fork)..."
    git -c credential.helper="" clone --depth=1 \
        https://github.com/vgrebenschikov/amneziawg-tools \
        "${BUILD_DIR}/amneziawg-tools" \
        || die "Не удалось клонировать amneziawg-tools"

    # vgrebenschikov/amneziawg-tools Makefile требует /usr/ports — обходим:
    # 1. awg (C бинарник) — берём из amnezia-vpn/amneziawg-tools (собирается через src/)
    # 2. awg-quick (bash скрипт) — берём из vgrebenschikov (FreeBSD-native, без amneziawg-go)

    # --- Собираем awg бинарник из amnezia-vpn ---
    info "Клонируем amnezia-vpn/amneziawg-tools для сборки awg..."
    rm -rf "${BUILD_DIR}/awg-upstream"
    git -c credential.helper="" clone --depth=1         https://github.com/amnezia-vpn/amneziawg-tools         "${BUILD_DIR}/awg-upstream"         || die "Не удалось клонировать amnezia-vpn/amneziawg-tools"

    info "Собираем awg бинарник..."
    cd "${BUILD_DIR}/awg-upstream/src"
    # Собираем только awg, без awg-quick (чтобы не установился Linux-вариант)
    gmake WITH_WGQUICK=no RUNSTATEDIR=/var/run PREFIX=/usr/local         || die "Ошибка сборки awg"
    gmake install WITH_WGQUICK=no RUNSTATEDIR=/var/run PREFIX=/usr/local         || die "Ошибка установки awg"
    cd - > /dev/null
    [ -x /usr/local/bin/awg ] || die "awg не установился"
    ok "awg бинарник установлен"

    # --- awg-quick: оригинальный скрипт + FreeBSD-патч от vgrebenschikov ---
    # vgrebenschikov/amneziawg-tools это порт-оверлей с патч-файлами.
    # Берём wg-quick/freebsd.bash из amnezia-vpn и применяем patch-wg-quick_freebsd.bash
    PATCH_FILE="${BUILD_DIR}/amneziawg-tools/files/patch-wg-quick_freebsd.bash"
    ORIG_SCRIPT="${BUILD_DIR}/awg-upstream/src/wg-quick/freebsd.bash"

    if [ ! -f "${ORIG_SCRIPT}" ]; then
        die "Оригинальный скрипт не найден: ${ORIG_SCRIPT}"
    fi

    cp "${ORIG_SCRIPT}" "${BUILD_DIR}/awg-quick-patched.bash"

    # Применяем патч — часть hunks может не применяться из-за версии файла.
    # Критичные изменения применяем вручную через sed если патч не справился.
    if [ -f "${PATCH_FILE}" ]; then
        info "Применяем FreeBSD-патч к awg-quick..."
        patch "${BUILD_DIR}/awg-quick-patched.bash" < "${PATCH_FILE}" 2>/dev/null             && ok "Патч применён полностью"              || warn "Часть hunks не применилась — применяем критичные правки вручную"
    fi

    # Заменяем всю функцию add_if на чистую FreeBSD-native версию.
    # Используем awk (входит в base system FreeBSD) — без Python, без sed-трюков.
    info "Патчим add_if через awk: убираем amneziawg-go, используем ifconfig awg..."
    awk '
/^add_if\(\)/ {
    skip=1
    print "add_if() {"
    print "\tlocal ret rc"
    print "\tlocal cmd=\"ifconfig wg create name $INTERFACE\""
    print "\tif ret=\"$(cmd $cmd 2>&1 >/dev/null)\"; then"
    print "\t\treturn 0"
    print "\tfi"
    print "\trc=$?"
    print "\tif [[ $ret == *\"ifconfig: ioctl SIOCSIFNAME (set name): File exists\"* ]]; then"
    print "\t\techo \"$ret\" >&3"
    print "\t\treturn $rc"
    print "\tfi"
    print "\techo \"[!] Missing WireGuard kernel support ($ret).\" >&3"
    print "}"
    next
}
skip && /^\}/ { skip=0; next }
skip            { next }
                { print }
' "${BUILD_DIR}/awg-quick-patched.bash" > "${BUILD_DIR}/awg-quick-final.bash" \
        || die "awk не смог обработать awg-quick"

    install -m 755 "${BUILD_DIR}/awg-quick-final.bash" /usr/local/bin/awg-quick
    [ -x /usr/local/bin/awg-quick ] || die "awg-quick не установился"
    bash -n /usr/local/bin/awg-quick || die "awg-quick содержит синтаксическую ошибку после патча"

    # Заглушаем ложное "division by 0" в функции мониторинга эндпоинтов.
    # Баг: публичный ключ содержит '/' который bash интерпретирует как деление в (( )).
    # Фикс: добавляем 2>/dev/null к проблемному вызову.
    awk '
/\(\(.*endpoint_updates.*\)\)/ { print $0 " 2>/dev/null"; next }
{ print }
' /usr/local/bin/awg-quick > /tmp/awg-quick-nodiv &&     install -m 755 /tmp/awg-quick-nodiv /usr/local/bin/awg-quick &&     rm -f /tmp/awg-quick-nodiv || true
    ok "amneziawg-tools установлен: awg + awg-quick (FreeBSD-native)"
}

# --------------------------------------------------------------------------- #
#  Шаг 5: Сборка и загрузка AWG kernel module
# --------------------------------------------------------------------------- #
install_kmod() {
    header "Модуль ядра (amneziawg / if_wg)"

    # Уже загружен нужный модуль?
    if kldstat 2>/dev/null | grep -qE "if_wg"; then
        ok "Модуль WireGuard уже загружен"
        return
    fi

    rm -rf "${BUILD_DIR}/amneziawg-kmod"
    mkdir -p "${BUILD_DIR}"

    info "Клонируем wireguard-amnezia-kmod..."
    git -c credential.helper="" clone --depth=1 \
        https://github.com/vgrebenschikov/wireguard-amnezia-kmod \
        "${BUILD_DIR}/amneziawg-kmod" \
        || die "Не удалось клонировать kmod репозиторий"

    info "Собираем модуль ядра (нужны исходники /usr/src/sys)..."
    cd "${BUILD_DIR}/amneziawg-kmod"
    # FreeBSD kmod требует bmake (системный make), не gmake
    make 2>&1 || die "Ошибка сборки kmod. Убедитесь что исходники ядра совпадают с версией системы."

    info "Устанавливаем модуль if_amn..."
    make install 2>&1 || die "Ошибка установки kmod"
    cd - > /dev/null

    # Выгружаем стандартный if_wg если загружен
    kldunload if_wg 2>/dev/null || true

    info "Загружаем AWG-модуль..."
    kldload /boot/modules/if_wg.ko \
        || die "Не удалось загрузить /boot/modules/if_wg.ko"

    ok "AWG модуль загружен: $(kldstat | grep if_wg)"

    # Автозагрузка — /boot/modules приоритетнее /boot/kernel
    if ! grep -q "if_wg_load" /boot/loader.conf 2>/dev/null; then
        echo 'if_wg_load="YES"'             >> /boot/loader.conf
        echo 'module_path="/boot/modules;/boot/kernel"' >> /boot/loader.conf
        ok "Автозагрузка прописана в /boot/loader.conf"
    fi
}

# --------------------------------------------------------------------------- #
#  Шаг 6: Директория и конфиг
# --------------------------------------------------------------------------- #
prepare_config() {
    header "Конфигурация"

    mkdir -p "${AWG_DIR}"
    chmod 700 "${AWG_DIR}"

    cp "${CONF_FILE}" "${CONF_PATH}"
    chmod 600 "${CONF_PATH}"

    # Добавляем хуки split tunneling если их нет
    if ! grep -q "split-tunnel" "${CONF_PATH}"; then
        # Вставляем PostUp/PostDown после секции [Interface]
        sed -i '' "/^\[Interface\]/a\\
PostUp = ${ROUTE_SCRIPT} up %i\\
PostDown = ${ROUTE_SCRIPT} down %i
" "${CONF_PATH}"
    fi

    ok "Конфиг скопирован: ${CONF_PATH}"
}

# --------------------------------------------------------------------------- #
#  Шаг 7: Скрипт split tunneling
# --------------------------------------------------------------------------- #
create_route_script() {
    header "Split tunneling"

    DOMAINS_LIST=$(echo "$DOMAINS" | tr ',' ' ')

    cat > "${ROUTE_SCRIPT}" << SCRIPT
#!/bin/sh
# split-tunnel.sh — маршрутизация только указанных доменов через AWG
# Сгенерировано awg-setup.sh

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

    # Маршрут к VPN-серверу всегда через физический шлюз (защита от петли)
    if [ -n "\${SERVER_IP}" ] && [ -n "\${DEFAULT_GW}" ]; then
        route add -host "\${SERVER_IP}" "\${DEFAULT_GW}" 2>/dev/null || true
        echo "host:\${SERVER_IP}" >> "\${STATE_FILE}"
        logger -t awg-split "VPN server \${SERVER_IP} -> \${DEFAULT_GW} (физический шлюз)"
    fi

    # Маршруты для каждого домена -> через туннель
    for domain in \${DOMAINS}; do
        ips=\$(resolve_ips "\${domain}")
        if [ -z "\${ips}" ]; then
            logger -t awg-split "WARN: не удалось разрезолвить \${domain}"
            continue
        fi
        for ip in \${ips}; do
            route add -host "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            echo "host:\${ip}" >> "\${STATE_FILE}"
            logger -t awg-split "\${domain} (\${ip}) -> \${IFACE}"
        done
    done
    logger -t awg-split "Split tunneling UP: \${DOMAINS}"
}

do_down() {
    SERVER_IP=\$(get_server_ip)
    [ -n "\${SERVER_IP}" ] && route delete -host "\${SERVER_IP}" 2>/dev/null || true

    if [ -f "\${STATE_FILE}" ]; then
        while IFS= read -r entry; do
            ip=\$(echo "\${entry}" | cut -d: -f2)
            route delete -host "\${ip}" 2>/dev/null || true
        done < "\${STATE_FILE}"
        rm -f "\${STATE_FILE}"
    fi
    logger -t awg-split "Split tunneling DOWN"
}

case "\${ACTION}" in
    up)   do_up   ;;
    down) do_down ;;
    *) echo "Usage: \$0 up|down <iface>" >&2; exit 1 ;;
esac
SCRIPT

    chmod +x "${ROUTE_SCRIPT}"
    ok "Скрипт split tunneling: ${ROUTE_SCRIPT}"
    info "Домены в туннеле: ${DOMAINS}"
}

# --------------------------------------------------------------------------- #
#  Шаг 8: Настройка AllowedIPs (только нужные домены)
# --------------------------------------------------------------------------- #
patch_allowed_ips() {
    header "Настройка AllowedIPs"

    SERVER_ENDPOINT=$(grep -i "^Endpoint" "${CONF_PATH}" | head -1 | sed 's/.*= *//' | cut -d: -f1)
    ALLOWED=""

    # IP сервера — обязательно
    if [ -n "${SERVER_ENDPOINT}" ]; then
        ALLOWED="${SERVER_ENDPOINT}/32"
        info "VPN сервер: ${SERVER_ENDPOINT}/32"
    fi

    # IP доменов
    for domain in $(echo "$DOMAINS" | tr ',' ' '); do
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4}' | sort -u)
        if [ -z "$ips" ]; then
            warn "Не удалось разрезолвить $domain (будет добавлен при старте через PostUp)"
            continue
        fi
        for ip in $ips; do
            ok "$domain -> $ip"
            if [ -z "$ALLOWED" ]; then
                ALLOWED="${ip}/32"
            else
                ALLOWED="${ALLOWED}, ${ip}/32"
            fi
        done
    done

    if [ -n "$ALLOWED" ]; then
        sed -i '' "s|^AllowedIPs = .*|AllowedIPs = ${ALLOWED}|" "${CONF_PATH}"
        ok "AllowedIPs = ${ALLOWED}"
    else
        warn "Не удалось разрезолвить домены — AllowedIPs не изменён"
    fi
}

# --------------------------------------------------------------------------- #
#  Шаг 9: RC автозапуск
# --------------------------------------------------------------------------- #
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
    kldstat | grep -q if_amn || kldload /boot/modules/if_wg.ko
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
    ok "RC скрипт: ${RC_SCRIPT}"
    ok "Автозапуск включён"
}

# --------------------------------------------------------------------------- #
#  Шаг 10: Запуск туннеля
# --------------------------------------------------------------------------- #
start_tunnel() {
    header "Запуск туннеля"

    info "awg-quick up ${CONF_PATH}"
    awg-quick up "${CONF_PATH}" || die "Не удалось поднять туннель"

    sleep 2
    ifconfig "${IFACE}" > /dev/null 2>&1 || die "Интерфейс ${IFACE} не появился"
    ok "Туннель ${IFACE} активен"
    awg show "${IFACE}"
}

# --------------------------------------------------------------------------- #
#  Шаг 11: Проверка
# --------------------------------------------------------------------------- #
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

    info "Внешний IP (должен быть IP провайдера, не VPN):"
    fetch -qo - https://api.ipify.org 2>/dev/null && echo "" || warn "Не удалось проверить внешний IP"
}

# --------------------------------------------------------------------------- #
#  Итоговая сводка
# --------------------------------------------------------------------------- #
print_summary() {
    printf "\n${BOLD}${GREEN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║           AmneziaWG успешно настроен!                    ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    printf "${BOLD}Туннель:${RESET}     %s\n"  "${IFACE}"
    printf "${BOLD}Домены:${RESET}      %s\n"  "${DOMAINS}"
    printf "${BOLD}Конфиг:${RESET}      %s\n"  "${CONF_PATH}"
    printf "${BOLD}Лог:${RESET}         %s\n\n" "${LOG_FILE}"
    printf "${BOLD}Управление:${RESET}\n"
    printf "  Статус:     ${CYAN}service amneziawg status${RESET}\n"
    printf "  Стоп:       ${CYAN}service amneziawg stop${RESET}\n"
    printf "  Старт:      ${CYAN}service amneziawg start${RESET}\n"
    printf "  Маршруты:   ${CYAN}netstat -rn | grep %s${RESET}\n"  "${IFACE}"
    printf "  Лог AWG:    ${CYAN}grep awg-split /var/log/messages${RESET}\n"
    printf "  Удалить:    ${CYAN}sudo $0 -u${RESET}\n\n"
}

# --------------------------------------------------------------------------- #
#  MAIN
# --------------------------------------------------------------------------- #
main() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║    AmneziaWG Setup + Split Tunneling для FreeBSD 15      ║\n"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    info "Домены для туннелирования: ${DOMAINS}"
    info "Интерфейс: ${IFACE}"

    check_root "$@"

    [ "${UNINSTALL}" -eq 1 ] && do_uninstall

    check_os
    check_conf
    install_deps
    install_awg_tools
    install_kmod
    prepare_config
    create_route_script
    patch_allowed_ips
    create_rc_script
    start_tunnel
    verify
    print_summary
}

_RC=0
if [ -z "${_AWG_LOGGED}" ]; then
    export _AWG_LOGGED=1
    { main "$@"; echo $? > /tmp/awg-exit.$$; } 2>&1 | tee -a "${LOG_FILE}"
    _RC=$(cat /tmp/awg-exit.$$ 2>/dev/null || echo 1)
    rm -f /tmp/awg-exit.$$
    exit "${_RC}"
else
    main "$@"
fi
