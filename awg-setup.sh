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

APP_LANG="en"
if [ -n "$LANG" ] && echo "$LANG" | grep -qi "^ru"; then
    APP_LANG="ru"
fi
CLI_LANG=""
RUN_TUI=0
BACKTITLE="FreeBSD AmneziaWG Installer"

t() {
    if [ "${APP_LANG}" = "ru" ]; then
        printf "%s" "$2"
    else
        printf "%s" "$1"
    fi
}

usage() {
    if [ "${APP_LANG}" = "ru" ]; then
        cat <<EOF
Использование: $0 [опции]

Режимы запуска:
  sudo $0                  Интерактивный TUI-мастер FreeBSD (рекомендуется)
  sudo $0 -c <файл.conf>   Консольная установка с указанным конфигом

Опции:
  -c FILE   Готовый .conf файл AmneziaWG
  -d DOMAIN Домены или IP/CIDR через запятую для раздельного туннелирования
            (по умолчанию: не задано — весь трафик идёт через VPN)
  -i IFACE  Имя интерфейса (по умолчанию: awg0)
  -l LANG   Язык интерфейса: en или ru
  -u        Удалить всё
  -h        Эта справка

Примеры:
  sudo $0
  sudo $0 -c /home/user/vpn.conf
  sudo $0 -c /home/user/vpn.conf -d "rutracker.org,nnmclub.to"
EOF
    else
        cat <<EOF
Usage: $0 [options]

Execution modes:
  sudo $0                  Interactive FreeBSD TUI Wizard (recommended)
  sudo $0 -c <file.conf>   Direct CLI setup with specified configuration

Options:
  -c FILE   AmneziaWG .conf file
  -d DOMAIN Comma-separated domains or IP/CIDR subnets for split tunneling
            (default: all internet traffic routed through VPN)
  -i IFACE  Network interface name (default: awg0)
  -l LANG   Interface language: en or ru
  -u        Completely uninstall AmneziaWG
  -h        Display this help message

Examples:
  sudo $0
  sudo $0 -c /home/user/vpn.conf
  sudo $0 -c /home/user/vpn.conf -d "rutracker.org,nnmclub.to"
EOF
    fi
    exit 0
}

while getopts "c:d:i:l:uh" opt; do
    case "$opt" in
        c) CONF_FILE="$OPTARG" ;;
        d) DOMAINS="$OPTARG"   ;;
        i) IFACE="$OPTARG"     ;;
        l) APP_LANG="$OPTARG"; CLI_LANG="$OPTARG" ;;
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
    [ "$(id -u)" -eq 0 ] || die "$(t "Run as root: sudo $0 $*" "Запустите от root: sudo $0 $*")"
}

# =============================================================================
# TUI Wizard (FreeBSD Native bsddialog / dialog)
# =============================================================================
init_dialog() {
    if command -v bsddialog >/dev/null 2>&1; then
        DIALOG="bsddialog"
    elif command -v dialog >/dev/null 2>&1; then
        DIALOG="dialog"
    else
        DIALOG=""
    fi
}

run_wizard() {
    init_dialog
    if [ -z "${DIALOG}" ]; then
        warn "bsddialog / dialog not found in system. Please run in CLI mode with -c <conf_file>."
        exit 1
    fi

    TMP_DIALOG=$(mktemp -t awg_dialog.XXXXXX 2>/dev/null || mktemp /tmp/awg_dialog.XXXXXX)
    trap 'rm -f "${TMP_DIALOG}"' EXIT INT TERM

    # --- Step 1: Language Selection ---
    if [ -z "${CLI_LANG}" ]; then
        "${DIALOG}" --backtitle "${BACKTITLE}" \
            --title " Language / Язык " \
            --menu "Select interface language / Выберите язык интерфейса:" \
            12 60 2 \
            "1" "English (Default)" \
            "2" "Русский" 2>"${TMP_DIALOG}" || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

        LANG_RES=$(cat "${TMP_DIALOG}")
        if [ "${LANG_RES}" = "2" ]; then
            APP_LANG="ru"
        else
            APP_LANG="en"
        fi
    fi

    # --- Step 2: Configuration File Discovery ---
    SEARCH_DIRS="."
    if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
        U_HOME=$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6)
        [ -n "${U_HOME}" ] && [ -d "${U_HOME}" ] && SEARCH_DIRS="${SEARCH_DIRS} ${U_HOME}"
    fi
    [ -d "/home" ] && SEARCH_DIRS="${SEARCH_DIRS} /home"

    FOUND_CONFS=$(find ${SEARCH_DIRS} -maxdepth 3 -type f -name "*.conf" 2>/dev/null | \
        grep -vE '/(etc|usr|var|amnezia|amnezia3)/' | while read -r f; do
            [ -n "${f}" ] && (realpath "${f}" 2>/dev/null || echo "${f}")
        done | sort -u | head -10)

    CHOSEN_CONF=""
    while [ -z "${CHOSEN_CONF}" ]; do
        if [ -n "${FOUND_CONFS}" ]; then
            set -- --backtitle "${BACKTITLE}" \
                   --title " $(t "Configuration File (.conf)" "Файл конфигурации (.conf)") " \
                   --menu "$(t "Found configuration files in system:\nSelect a file or specify custom path:" "Найдены файлы конфигурации в системе:\nВыберите файл или укажите путь вручную:")" \
                   16 75 6
            INDEX=1
            for f in ${FOUND_CONFS}; do
                set -- "$@" "${INDEX}" "${f}"
                INDEX=$((INDEX + 1))
            done
            set -- "$@" "C" "$(t "Enter path manually..." "Ввести путь вручную...")"

            "${DIALOG}" "$@" 2>"${TMP_DIALOG}" || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

            SEL=$(cat "${TMP_DIALOG}")
            if [ "${SEL}" != "C" ]; then
                CUR_IDX=1
                for f in ${FOUND_CONFS}; do
                    if [ "${CUR_IDX}" -eq "${SEL}" ] 2>/dev/null; then
                        CHOSEN_CONF="${f}"
                        break
                    fi
                    CUR_IDX=$((CUR_IDX + 1))
                done
            fi
        fi

        if [ -z "${CHOSEN_CONF}" ]; then
            DEF_INPUT="/home/${SUDO_USER:-alsina}/vpn.conf"
            [ -f "${DEF_INPUT}" ] || DEF_INPUT=""

            "${DIALOG}" --backtitle "${BACKTITLE}" \
                --title " $(t "Configuration File (.conf)" "Файл конфигурации (.conf)") " \
                --inputbox "$(t "Enter full path to AmneziaWG .conf file:" "Введите полный путь к .conf файлу AmneziaWG:")" \
                11 70 "${DEF_INPUT}" 2>"${TMP_DIALOG}" || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

            ENTERED_PATH=$(cat "${TMP_DIALOG}" | tr -d '\r' | tr -d '\n')
            if [ -f "${ENTERED_PATH}" ]; then
                CHOSEN_CONF="${ENTERED_PATH}"
            else
                "${DIALOG}" --backtitle "${BACKTITLE}" \
                    --title " $(t "Error" "Ошибка") " \
                    --msgbox "$(t "File not found: " "Файл не найден: ")${ENTERED_PATH}\n$(t "Please check path and try again." "Пожалуйста, проверьте путь и повторите ввод.")" \
                    9 65
            fi
        fi
    done

    CONF_FILE="${CHOSEN_CONF}"

    # --- Step 3: Tunnel Routing Mode ---
    "${DIALOG}" --backtitle "${BACKTITLE}" \
        --title " $(t "Routing Mode" "Режим маршрутизации") " \
        --menu "$(t "Choose VPN traffic routing mode:" "Выберите режим маршрутизации трафика:")" \
        13 70 2 \
        "1" "$(t "Full Tunnel - Route ALL internet traffic via VPN" "Полный туннель - Весь интернет через VPN")" \
        "2" "$(t "Split Tunneling - Route only selected domains / IPs" "Раздельный туннель - Только выбранные домены / IP")" \
        2>"${TMP_DIALOG}" || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

    MODE_CHOICE=$(cat "${TMP_DIALOG}")

    # --- Step 4: Domain Manager (if Split Tunneling) ---
    DOMAINS=""
    if [ "${MODE_CHOICE}" = "2" ]; then
        DOMAIN_LIST=""
        while true; do
            if [ -z "${DOMAIN_LIST}" ]; then
                DOM_DISPLAY="$(t "(No domains added yet)" "(Список пуст)")"
            else
                DOM_DISPLAY=$(echo "${DOMAIN_LIST}" | tr ',' '\n' | sed 's/^/  * /')
            fi

            MENU_MSG="$(t "Current split tunneling targets:" "Текущие цели раздельного туннелирования:")\n\n${DOM_DISPLAY}\n"

            "${DIALOG}" --backtitle "${BACKTITLE}" \
                --title " $(t "Split Tunneling Manager" "Управление раздельным туннелированием") " \
                --menu "${MENU_MSG}" \
                18 72 4 \
                "ADD"   "$(t "[+] Add domain or IP/CIDR" "[+] Добавить домен или IP/CIDR")" \
                "DEL"   "$(t "[-] Remove last added item" "[-] Удалить последний добавленный элемент")" \
                "CLEAR" "$(t "[X] Clear all items" "[X] Очистить весь список")" \
                "DONE"  "$(t "[OK] Proceed with this list" "[OK] Завершить и продолжить установку")" \
                2>"${TMP_DIALOG}" || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

            ACT=$(cat "${TMP_DIALOG}")
            case "${ACT}" in
                ADD)
                    "${DIALOG}" --backtitle "${BACKTITLE}" \
                        --title " $(t "Add Domain / Subnet" "Добавить домен / подсеть") " \
                        --inputbox "$(t "Enter domain name or IP/CIDR:\n(e.g.: rutracker.org, nnmclub.to, 198.51.100.0/24)" "Введите домен или IP/CIDR:\n(например: rutracker.org, nnmclub.to, 198.51.100.0/24)")" \
                        12 68 2>"${TMP_DIALOG}" || continue

                    RAW_ENTRY=$(cat "${TMP_DIALOG}" | tr -d ' ' | tr -d '\t' | tr -d '\r' | tr -d '\n')
                    if [ -n "${RAW_ENTRY}" ]; then
                        if [ -z "${DOMAIN_LIST}" ]; then
                            DOMAIN_LIST="${RAW_ENTRY}"
                        else
                            DOMAIN_LIST="${DOMAIN_LIST},${RAW_ENTRY}"
                        fi
                    fi
                    ;;
                DEL)
                    if [ -n "${DOMAIN_LIST}" ]; then
                        DOMAIN_LIST=$(echo "${DOMAIN_LIST}" | sed 's/,[^,]*$//; s/^[^,]*$//')
                    fi
                    ;;
                CLEAR)
                    DOMAIN_LIST=""
                    ;;
                DONE)
                    if [ -z "${DOMAIN_LIST}" ]; then
                        "${DIALOG}" --backtitle "${BACKTITLE}" \
                            --title " $(t "Empty Target List" "Список целей пуст") " \
                            --yesno "$(t "Domain list is empty. Switch to Full Tunnel mode?" "Список доменов пуст. Переключиться в режим полного туннеля?")" \
                            8 65
                        if [ $? -eq 0 ]; then
                            DOMAINS=""
                            break
                        else
                            continue
                        fi
                    else
                        DOMAINS="${DOMAIN_LIST}"
                        break
                    fi
                    ;;
            esac
        done
    fi

    # --- Step 5: Summary and Confirmation ---
    if [ -n "${DOMAINS}" ]; then
        SUMMARY_MODE="$(t "Split Tunneling" "Раздельное туннелирование")\n    $(t "Targets:" "Цели:") ${DOMAINS}"
    else
        SUMMARY_MODE="$(t "Full Tunnel (All internet traffic routed via VPN)" "Полный туннель (Весь интернет через VPN)")"
    fi

    SUM_TEXT="$(t "Ready to install AmneziaWG with settings:" "Готово к установке AmneziaWG со следующими параметрами:")\n\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Config file:" "Конфигурация:")   ${CONF_FILE}\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Interface:" "Интерфейс:")     ${IFACE}\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Routing Mode:" "Маршрутизация:") ${SUMMARY_MODE}\n\n"
    SUM_TEXT="${SUM_TEXT}$(t "Proceed with automated installation?" "Запустить автоматическую настройку?")"

    "${DIALOG}" --backtitle "${BACKTITLE}" \
        --title " $(t "Installation Summary" "Сводка параметров установки") " \
        --yesno "${SUM_TEXT}" 16 75 || { rm -f "${TMP_DIALOG}"; echo "Cancelled by user / Отменено пользователем."; exit 0; }

    rm -f "${TMP_DIALOG}"
}

show_final_dialog() {
    [ -z "${DIALOG}" ] && return 0
    if [ -n "${TMP_STATUS}" ] && [ -f "${TMP_STATUS}" ]; then
        . "${TMP_STATUS}"
        rm -f "${TMP_STATUS}"
    fi

    if [ -z "${VERIF_EXT_IP}" ]; then
        VERIF_EXT_IP=$(fetch -T 3 -qo - https://api.ipify.org 2>/dev/null || true)
    fi

    FINAL_MSG="   $(t "AmneziaWG successfully configured!" "AmneziaWG успешно настроен!")\n"
    FINAL_MSG="${FINAL_MSG}------------------------------------------------------------\n\n"
    FINAL_MSG="${FINAL_MSG}$(t "Protocol:" "Протокол:")   AmneziaWG 2.x\n"
    FINAL_MSG="${FINAL_MSG}$(t "Interface:" "Туннель:")    ${IFACE}\n"
    if [ -n "${DOMAINS}" ]; then
        FINAL_MSG="${FINAL_MSG}$(t "Mode:" "Режим:")        $(t "Split Tunneling" "Раздельное туннелирование")\n"
        FINAL_MSG="${FINAL_MSG}$(t "Targets:" "Цели:")     ${DOMAINS}\n"
    else
        FINAL_MSG="${FINAL_MSG}$(t "Mode:" "Режим:")        $(t "Full Tunnel (All Internet)" "Полный туннель (Весь интернет)")\n"
    fi
    if [ -n "${VERIF_EXT_IP}" ]; then
        FINAL_MSG="${FINAL_MSG}$(t "External IP:" "Внешний IP:") ${VERIF_EXT_IP}\n\n"
    else
        FINAL_MSG="${FINAL_MSG}\n"
    fi
    FINAL_MSG="${FINAL_MSG}$(t "Service Management:" "Управление сервисом:")\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg status\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg stop\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg start\n"

    "${DIALOG}" --backtitle "${BACKTITLE}" \
        --title " $(t "Setup Complete" "Установка завершена") " \
        --msgbox "${FINAL_MSG}" 18 68 </dev/tty >/dev/tty 2>&1 || true
}

# =============================================================================
do_uninstall() {
    header "Удаление AmneziaWG"

    if [ -x "${RC_SCRIPT}" ]; then
        service amneziawg stop 2>/dev/null || true
    fi
    awg-quick down "${CONF_PATH}" 2>/dev/null || true
    ifconfig "${IFACE}" destroy   2>/dev/null || true

    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    pkg delete -y amnezia-tools amnezia-kmod 2>/dev/null || true
    pkg autoremove -y 2>/dev/null || true

    pkill -f "monitor-daemon" 2>/dev/null || true
    pkill -f "route.*monitor" 2>/dev/null || true

    rm -f "${RC_SCRIPT}" "${LOG_FILE}"
    rm -rf "${AWG_DIR}"

    sed -i '' '/amneziawg/d'   /etc/rc.conf     2>/dev/null || true
    sed -i '' '/if_amn_load/d' /boot/loader.conf 2>/dev/null || true
    sed -i '' '/if_wg_load/d'  /boot/loader.conf 2>/dev/null || true

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
    if grep -qiE "^ *(Jc|Jmin|Jmax|H1|H2|H3|H4|S1|S2|S3|S4|HeaderProtectionKey|ContentPaddingAddition)" "${CONF_FILE}"; then
        ok "Обнаружены параметры AWG-обфускации"
    else
        warn "Параметры AWG-обфускации не найдены — возможно обычный WireGuard конфиг"
    fi
    ok "Конфиг: ${CONF_FILE}"
}

# =============================================================================
install_packages() {
    header "Установка пакетов"

    # Инициализация pkg при необходимости
    pkg -N 2>/dev/null || pkg bootstrap -y || die "Не удалось инициализировать pkg"

    # amnezia-tools (awg + awg-quick)
    if pkg info amnezia-tools > /dev/null 2>&1; then
        ok "amnezia-tools уже установлен"
    else
        info "Устанавливаем amnezia-tools..."
        pkg install -y amnezia-tools || die "Не удалось установить amnezia-tools"
        ok "amnezia-tools установлен"
    fi
    # Отключаем background route monitor в awg-quick, блокирующий завершение пайпов tee
    sed -i '' 's/.*Backgrounding route monitor.*/return 0/' /usr/local/bin/awg-quick 2>/dev/null || true

    # amnezia-kmod (kernel module if_amn.ko)
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

    if kldstat 2>/dev/null | grep -q "if_amn"; then
        LOADED_MOD=$(kldstat | grep if_amn | awk '{print $5}' | head -1)
        ok "Модуль уже загружен: ${LOADED_MOD}"
        return
    fi

    info "Загружаем модуль if_amn..."
    kldload if_amn || die "Не удалось загрузить модуль if_amn"
    LOADED_MOD=$(kldstat | grep if_amn | awk '{print $5}' | head -1)
    ok "Модуль загружен: ${LOADED_MOD}"

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

    # Настройка раздельного туннелирования при указании доменов/подсетей (-d)
    if [ -n "${DOMAINS}" ]; then
        # Отключаем перезапись дефолтного шлюза в awg-quick
        if ! grep -qi "^Table" "${CONF_PATH}"; then
            sed -i '' "/^\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/a\\
Table = off
" "${CONF_PATH}"
        fi
        # Подключаем PostUp/PostDown хуки маршрутизации
        if ! grep -q "split-tunnel" "${CONF_PATH}"; then
            sed -i '' "/^\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/a\\
PostUp = ${ROUTE_SCRIPT} up %i\\
PostDown = ${ROUTE_SCRIPT} down %i
" "${CONF_PATH}"
        fi
        ok "Режим: Раздельное туннелирование (Table = off + маршрутизация)"
    else
        ok "Режим: Полный туннель (весь трафик через VPN)"
    fi

    ok "Конфиг сохранён: ${CONF_PATH}"
}

# =============================================================================
create_route_script() {
    header "Split tunneling"

    DOMAINS_LIST=$(echo "$DOMAINS" | tr ',' ' ')

    cat > "${ROUTE_SCRIPT}" << SCRIPT
#!/bin/sh
# split-tunnel.sh — маршрутизация только указанных доменов и подсетей через AWG

ACTION="\$1"
IFACE="\$2"
DOMAINS="${DOMAINS_LIST}"
STATE_FILE="/var/run/awg-routes-\${IFACE}.txt"
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
        return
    fi
    IPS=\$(host -t A "\${TARGET}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
    if [ -z "\${IPS}" ] && [ -n "\${DNS_IP}" ]; then
        IPS=\$(host -t A "\${TARGET}" "\${DNS_IP}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
    fi
    if [ -z "\${IPS}" ]; then
        sleep 1
        IPS=\$(host -t A "\${TARGET}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
        if [ -z "\${IPS}" ] && [ -n "\${DNS_IP}" ]; then
            IPS=\$(host -t A "\${TARGET}" "\${DNS_IP}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
        fi
    fi
    if ! echo "\${TARGET}" | grep -qi '^www\.'; then
        WWW_IPS=\$(host -t A "www.\${TARGET}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
        if [ -z "\${WWW_IPS}" ] && [ -n "\${DNS_IP}" ]; then
            WWW_IPS=\$(host -t A "www.\${TARGET}" "\${DNS_IP}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
        fi
        [ -n "\${WWW_IPS}" ] && IPS="\${IPS} \${WWW_IPS}"
    fi
    # Дополнительный опрос для пулов Anycast (Google, CDN)
    POOL_IPS=\$(host -t A "\${TARGET}" 2>/dev/null | awk '/has address/{print \$4}' | sort -u)
    [ -n "\${POOL_IPS}" ] && IPS="\${IPS} \${POOL_IPS}"
    echo "\${IPS}" | tr ' ' '\n' | sort -u
}

do_up() {
    DEFAULT_GW=\$(get_default_gw)
    SERVER_IP=\$(get_server_ip)
    DNS_IP=\$(get_dns_ip)
    rm -f "\${STATE_FILE}"

    # Маршрут к VPN-серверу через физический шлюз (защита от зацикливания)
    if [ -n "\${SERVER_IP}" ] && [ -n "\${DEFAULT_GW}" ]; then
        route add -host "\${SERVER_IP}" "\${DEFAULT_GW}" 2>/dev/null || true
        echo "server:\${SERVER_IP}" >> "\${STATE_FILE}"
        logger -t awg-split "VPN server \${SERVER_IP} -> \${DEFAULT_GW}"
    fi

    # Маршрут к DNS-серверу туннеля через интерфейс AWG (если DNS указан)
    if [ -n "\${DNS_IP}" ] && echo "\${DNS_IP}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        route add -host "\${DNS_IP}" -interface "\${IFACE}" 2>/dev/null || true
        echo "route:\${DNS_IP}" >> "\${STATE_FILE}"
        logger -t awg-split "VPN DNS \${DNS_IP} -> \${IFACE}"
    fi

    # Ожидаем завершения handshake туннеля (до 5 секунд) для готовности DNS
    for _i in 1 2 3 4 5; do
        _HS=\$(awg show "\${IFACE}" latest-handshakes 2>/dev/null | awk '{print \$2}')
        [ -n "\${_HS}" ] && [ "\${_HS}" -gt 0 ] 2>/dev/null && break
        sleep 1
    done

    # Маршруты для доменов и подсетей через туннель
    for domain in \${DOMAINS}; do
        ips=\$(resolve_ips "\${domain}")
        if [ -z "\${ips}" ]; then
            logger -t awg-split "WARN: не удалось разрезолвить \${domain}"
            continue
        fi
        for ip in \${ips}; do
            if echo "\${ip}" | grep -q '/'; then
                route add -net "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            else
                route add -host "\${ip}" -interface "\${IFACE}" 2>/dev/null || true
            fi
            echo "route:\${ip}" >> "\${STATE_FILE}"
            logger -t awg-split "\${domain} (\${ip}) -> \${IFACE}"
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
    header "Автозапуск"

    cat > "${RC_SCRIPT}" << RCEOF
#!/bin/sh
# PROVIDE: amneziawg
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

export PATH="/usr/local/bin:/usr/local/sbin:\$PATH"

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
    /usr/local/bin/awg-quick up "\${amneziawg_conf}"
}
amneziawg_stop()   { /usr/local/bin/awg-quick down "\${amneziawg_conf}" 2>/dev/null || true; }
amneziawg_status() {
    ifconfig "${IFACE}" > /dev/null 2>&1 \
        && /usr/local/bin/awg show "${IFACE}" \
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

    info "Поднимаем туннель через awg-quick..."
    awg-quick up "${CONF_PATH}" || die "Не удалось поднять туннель"

    ifconfig "${IFACE}" > /dev/null 2>&1 || die "Интерфейс ${IFACE} не появился"
    ok "Туннель ${IFACE} активен"
    awg show "${IFACE}"
}

# =============================================================================
verify() {
    header "$(t "Verification" "Проверка маршрутизации")"
    if [ -n "${DOMAINS}" ]; then
        for domain in $(echo "$DOMAINS" | tr ',' ' '); do
            TARGET=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4; exit}')
            ROUTE_IFACE=""
            if [ -n "$TARGET" ]; then
                ROUTE_IFACE=$(route get "$TARGET" 2>/dev/null | awk '/interface:/{print $2}')
            fi
            if [ "$ROUTE_IFACE" != "${IFACE}" ] && [ -f "/var/run/awg-routes-${IFACE}.txt" ]; then
                SAVED_IP=$(grep "^route:" "/var/run/awg-routes-${IFACE}.txt" 2>/dev/null | head -1 | cut -d: -f2)
                if [ -n "$SAVED_IP" ]; then
                    ST_IFACE=$(route get "$SAVED_IP" 2>/dev/null | awk '/interface:/{print $2}')
                    if [ "$ST_IFACE" = "${IFACE}" ]; then
                        ROUTE_IFACE="${IFACE}"
                        TARGET="${SAVED_IP}"
                    fi
                fi
            fi
            if [ "$ROUTE_IFACE" = "${IFACE}" ]; then
                ok "${domain} (${TARGET}) -> ${IFACE} ✓"
            elif [ -n "$TARGET" ]; then
                warn "${domain} (${TARGET}) $(t "goes via" "идёт через") ${ROUTE_IFACE:-vtnet0}, $(t "not via" "не через") ${IFACE}"
            fi
        done
        info "$(t "External IP (should be your regular ISP IP):" "Внешний IP (должен быть IP вашего провайдера, не VPN):")"
    else
        info "$(t "External IP (should be AmneziaWG VPN server IP):" "Внешний IP (должен быть IP VPN сервера):")"
    fi
    EXT_IP=$(fetch -T 5 -qo - https://api.ipify.org 2>/dev/null || fetch -T 5 -qo - https://icanhazip.com 2>/dev/null || true)
    VERIF_EXT_IP="${EXT_IP}"
    if [ -n "${TMP_STATUS}" ] && [ -n "${VERIF_EXT_IP}" ]; then
        echo "VERIF_EXT_IP='${VERIF_EXT_IP}'" >> "${TMP_STATUS}"
    fi
    if [ -n "${EXT_IP}" ]; then
        ok "$(t "External IP:" "Внешний IP:") ${EXT_IP}"
    fi

    # Проверка handshake с сервером
    sleep 1
    HANDSHAKE_TS=$(awg show "${IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -n "${HANDSHAKE_TS}" ] && [ "${HANDSHAKE_TS}" -gt 0 ] 2>/dev/null; then
        NOW=$(date +%s)
        AGO=$((NOW - HANDSHAKE_TS))
        if [ -n "${TMP_STATUS}" ]; then
            echo "VERIF_AGO='${AGO}'" >> "${TMP_STATUS}"
        fi
        ok "$(t "Handshake with AmneziaWG server successful" "Handshake с сервером AmneziaWG успешно выполнен") (${AGO} $(t "sec ago" "сек назад"))"
    fi
}

# =============================================================================
print_summary() {
    printf "\n${BOLD}${GREEN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║   %s   ║\n" "$(t "       AmneziaWG successfully configured!         " "           AmneziaWG успешно настроен!            ")"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    printf "${BOLD}%s:${RESET}     %s\n" "$(t "Interface" "Туннель")" "${IFACE}"
    [ -n "${DOMAINS}" ] && printf "${BOLD}%s:${RESET}   %s\n" "$(t "Domains/IP" "Домены/IP")" "${DOMAINS}" || printf "${BOLD}%s:${RESET}       %s\n" "$(t "Mode" "Режим")" "$(t "All traffic via VPN" "Весь трафик через VPN")"
    printf "${BOLD}%s:${RESET}      %s\n" "$(t "Config" "Конфиг")" "${CONF_PATH}"
    printf "${BOLD}%s:${RESET}         %s\n\n" "$(t "Log" "Лог")" "${LOG_FILE}"
    printf "${BOLD}%s:${RESET}\n" "$(t "Service Management" "Управление")"
    printf "  %s:   ${CYAN}service amneziawg status${RESET}\n" "$(t "Status" "Статус")"
    printf "  %s:     ${CYAN}service amneziawg stop${RESET}\n" "$(t "Stop" "Стоп")"
    printf "  %s:    ${CYAN}service amneziawg start${RESET}\n" "$(t "Start" "Старт")"
    printf "  %s: ${CYAN}netstat -rn | grep %s${RESET}\n" "$(t "Routes" "Маршруты")" "${IFACE}"
    printf "  %s:  ${CYAN}sudo $0 -u${RESET}\n\n" "$(t "Uninstall" "Удалить")"
}

# =============================================================================
main() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║    AmneziaWG Setup + Split Tunneling (FreeBSD)           ║\n"
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
    verify
    print_summary
}

# =============================================================================
# Точка входа: интерактивный мастер (если запущен без -c) и логирование
# =============================================================================
if [ "${UNINSTALL}" -eq 0 ] && [ -z "${CONF_FILE}" ] && [ -t 0 ]; then
    RUN_TUI=1
    run_wizard
fi

CONF_PATH="${AWG_DIR}/${IFACE}.conf"
ROUTE_SCRIPT="${AWG_DIR}/split-tunnel.sh"
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg"

if [ -z "${_AWG_LOGGED}" ]; then
    export _AWG_LOGGED=1
    TMP_EXIT="/tmp/awg-exit.$$"
    export TMP_STATUS="/tmp/awg-status.$$"
    rm -f "${TMP_STATUS}"
    (
        trap 'echo $? > "${TMP_EXIT}"' EXIT
        main "$@"
    ) 2>&1 | tee -a "${LOG_FILE}"
    EXIT_STATUS=1
    if [ -f "${TMP_EXIT}" ]; then
        EXIT_STATUS=$(cat "${TMP_EXIT}")
        rm -f "${TMP_EXIT}"
    fi
    if [ "${RUN_TUI}" -eq 1 ] && [ "${EXIT_STATUS}" -eq 0 ]; then
        show_final_dialog
    fi
    rm -f "${TMP_STATUS}"
    exit "${EXIT_STATUS}"
else
    main "$@"
fi
