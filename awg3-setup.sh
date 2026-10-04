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

# --- Defaults & Language ---
IFACE="awg0"
DOMAINS=""
CONF_FILE=""
UNINSTALL=0
AWG_DIR="/usr/local/etc/amnezia3"
LOG_FILE="/var/log/awg3-setup.log"

APP_LANG="en"
if [ -n "$LANG" ] && echo "$LANG" | grep -qi "^ru"; then
    APP_LANG="ru"
fi
CLI_LANG=""
RUN_TUI=0
BACKTITLE="FreeBSD AmneziaWG 3.1 Installer"

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
  -c FILE   Готовый .conf файл AmneziaWG 3.1
  -d DOMAIN Домены или IP/CIDR через запятую для раздельного туннелирования
            (по умолчанию: не задано — весь трафик идёт через VPN)
  -i IFACE  Имя интерфейса (по умолчанию: awg0)
  -l LANG   Язык интерфейса: en или ru
  -u        Удалить всё (AmneziaWG 3.1)
  -h        Эта справка

Примеры:
  sudo $0
  sudo $0 -c /home/user/awg3.conf
  sudo $0 -c /home/user/awg3.conf -d "rutracker.org,nnmclub.to,198.51.100.0/24"
EOF
    else
        cat <<EOF
Usage: $0 [options]

Execution modes:
  sudo $0                  Interactive FreeBSD TUI Wizard (recommended)
  sudo $0 -c <file.conf>   Direct CLI setup with specified configuration

Options:
  -c FILE   AmneziaWG 3.1 .conf file
  -d DOMAIN Comma-separated domains or IP/CIDR subnets for split tunneling
            (default: all internet traffic routed through VPN)
  -i IFACE  Network interface name (default: awg0)
  -l LANG   Interface language: en or ru
  -u        Completely uninstall AmneziaWG 3.1
  -h        Display this help message

Examples:
  sudo $0
  sudo $0 -c /home/user/awg3.conf
  sudo $0 -c /home/user/awg3.conf -d "rutracker.org,nnmclub.to,198.51.100.0/24"
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
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg3"

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
            DEF_INPUT="/home/${SUDO_USER:-alsina}/freebsdtestawg31.conf"
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

    SUM_TEXT="$(t "Ready to install AmneziaWG 3.1 with settings:" "Готово к установке AmneziaWG 3.1 со следующими параметрами:")\n\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Config file:" "Конфигурация:")   ${CONF_FILE}\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Interface:" "Интерфейс:")     ${IFACE}\n"
    SUM_TEXT="${SUM_TEXT}  * $(t "Routing Mode:" "Маршрутизация:") ${SUMMARY_MODE}\n\n"
    SUM_TEXT="${SUM_TEXT}$(t "Proceed with automated build and installation?" "Запустить автоматическую сборку и настройку?")"

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
    if [ -z "${VERIF_AGO}" ]; then
        HANDSHAKE_TS=$(awg show "${IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [ -n "${HANDSHAKE_TS}" ] && [ "${HANDSHAKE_TS}" -gt 0 ] 2>/dev/null; then
            VERIF_AGO=$(( $(date +%s) - HANDSHAKE_TS ))
        fi
    fi

    FINAL_MSG="   $(t "AmneziaWG 3.1 successfully configured!" "AmneziaWG 3.1 успешно настроен!")\n"
    FINAL_MSG="${FINAL_MSG}------------------------------------------------------------\n\n"
    FINAL_MSG="${FINAL_MSG}$(t "Protocol:" "Протокол:")   AmneziaWG 3.1 (ChaCha20 Header Protection)\n"
    FINAL_MSG="${FINAL_MSG}$(t "Interface:" "Туннель:")    ${IFACE}\n"
    if [ -n "${DOMAINS}" ]; then
        FINAL_MSG="${FINAL_MSG}$(t "Mode:" "Режим:")        $(t "Split Tunneling" "Раздельное туннелирование")\n"
        FINAL_MSG="${FINAL_MSG}$(t "Targets:" "Цели:")     ${DOMAINS}\n"
    else
        FINAL_MSG="${FINAL_MSG}$(t "Mode:" "Режим:")        $(t "Full Tunnel (All Internet)" "Полный туннель (Весь интернет)")\n"
    fi
    if [ -n "${VERIF_EXT_IP}" ]; then
        FINAL_MSG="${FINAL_MSG}$(t "External IP:" "Внешний IP:") ${VERIF_EXT_IP}\n"
    fi
    if [ -n "${VERIF_AGO}" ]; then
        FINAL_MSG="${FINAL_MSG}$(t "Handshake:" "Хэндшейк:")   $(t "Active" "Активен") (${VERIF_AGO} $(t "sec ago" "сек назад"))\n\n"
    else
        FINAL_MSG="${FINAL_MSG}\n"
    fi
    FINAL_MSG="${FINAL_MSG}$(t "Service Management:" "Управление сервисом:")\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg3 status\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg3 stop\n"
    FINAL_MSG="${FINAL_MSG}  service amneziawg3 start\n"

    "${DIALOG}" --backtitle "${BACKTITLE}" \
        --title " $(t "Setup Complete" "Установка завершена") " \
        --msgbox "${FINAL_MSG}" 18 68 </dev/tty >/dev/tty 2>&1 || true
}

# =============================================================================
do_uninstall() {
    header "$(t "Uninstalling AmneziaWG 3.1" "Удаление AmneziaWG 3.1")"

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
    pkill -f "route.*monitor" 2>/dev/null || true

    if [ -f "/boot/kernel/if_wg.ko.stock" ]; then
        cp -fp /boot/kernel/if_wg.ko.stock /boot/kernel/if_wg.ko
        rm -f /boot/kernel/if_wg.ko.stock
        kldxref /boot/kernel 2>/dev/null || true
    fi
    sysrc -x amneziawg3_enable 2>/dev/null || true
    sed -i '' '/amneziawg3/d'  /etc/rc.conf     2>/dev/null || true
    sed -i '' '/if_wg_load/d'  /boot/loader.conf 2>/dev/null || true
    sed -i '' '/if_amn_load/d' /boot/loader.conf 2>/dev/null || true

    ok "$(t "AmneziaWG 3.1 uninstalled successfully" "Удаление AmneziaWG 3.1 завершено")"
    exit 0
}

# =============================================================================
check_os() {
    header "$(t "Environment Check" "Проверка окружения")"
    [ "$(uname -s)" = "FreeBSD" ] || die "$(t "FreeBSD only" "Только FreeBSD")"
    VER=$(uname -r | cut -d. -f1)
    [ "$VER" -ge 13 ] || die "$(t "FreeBSD 13+ required" "Требуется FreeBSD 13+")"
    ok "$(t "OS: FreeBSD $(uname -r)" "ОС: FreeBSD $(uname -r)")"

    if [ ! -d "/usr/src/sys" ]; then
        warn "$(t "Kernel sources /usr/src/sys not found." "Исходные тексты ядра /usr/src/sys не обнаружены.")"
        info "$(t "Installing system sources for kernel module compilation..." "Устанавливаем исходники системы для сборки модуля ядра...")"
        pkg install -y git || true
        git clone --depth 1 -b "releng/$(uname -r | cut -d- -f1,2)" https://git.freebsd.org/src.git /usr/src || \
            die "$(t "Failed to fetch kernel sources into /usr/src" "Не удалось получить исходники ядра в /usr/src")"
        ok "$(t "Kernel sources /usr/src ready" "Исходники ядра /usr/src готовы")"
    else
        ok "$(t "Kernel sources /usr/src/sys found" "Исходники ядра /usr/src/sys найдены")"
    fi
}

# =============================================================================
check_conf() {
    header "$(t "Analyzing AWG 3.1 Configuration File" "Анализ конфигурационного файла AWG 3.1")"
    [ -n "${CONF_FILE}" ] || die "$(t "Specify config: $0 -c /path/to/awg3.conf" "Укажите конфиг: $0 -c /path/to/awg3.conf")"
    [ -f "${CONF_FILE}" ] || die "$(t "File not found: ${CONF_FILE}" "Файл не найден: ${CONF_FILE}")"

    HAS_AWG3=0
    HAS_AWG2=0

    # Проверка параметров AWG 3.1
    if grep -qiE "^ *(HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime)" "${CONF_FILE}"; then
        HAS_AWG3=1
        ok "$(t "Detected extended AWG 3.1 protocol parameters:" "Обнаружены расширенные параметры протокола AWG 3.1:")"
        grep -iE "^ *(HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime)" "${CONF_FILE}" | while read -r line; do
            key=$(echo "$line" | cut -d= -f1 | tr -d ' ')
            printf "     * %s\n" "$key"
        done
    fi

    # Проверка базовых параметров обфускации
    if grep -qiE "^ *(Jc|Jmin|Jmax|H1|H2|H3|H4|S1|S2|S3|S4)" "${CONF_FILE}"; then
        HAS_AWG2=1
        ok "$(t "Detected obfuscation parameters (Jc/Jmin/H1-H4/S1-S4)" "Обнаружены параметры обфускации (Jc/Jmin/H1-H4/S1-S4)")"
    fi

    if [ "$HAS_AWG3" -eq 1 ]; then
        printf "${GREEN}${BOLD}>> %s${RESET}\n" "$(t "Protocol: AmneziaWG 3.1 (active ChaCha20 header protection + Transport Padding)" "Протокол: AmneziaWG 3.1 (активная защита заголовков ChaCha20 + Transport Padding)")"
    elif [ "$HAS_AWG2" -eq 1 ]; then
        info "$(t "Config contains AWG 2.x parameters" "Конфиг содержит параметры AWG 2.x")"
    else
        warn "$(t "Config looks like standard WireGuard" "Конфиг выглядит как стандартный WireGuard")"
    fi

    ok "$(t "Config:" "Конфиг:") ${CONF_FILE}"
}

# =============================================================================
cleanup_old_awg() {
    header "$(t "Cleaning Previous AmneziaWG Components" "Очистка компонентов предыдущей версии AmneziaWG")"

    # Остановка сервисов amneziawg (v2) и amneziawg3, если они запущены
    if service amneziawg status >/dev/null 2>&1 || service amneziawg3 status >/dev/null 2>&1 || ifconfig "${IFACE}" >/dev/null 2>&1; then
        info "$(t "Stopping running tunnels/services of previous versions..." "Останавливаем запущенный туннель/сервис предыдущей версии...")"
        service amneziawg stop 2>/dev/null || true
        service amneziawg3 stop 2>/dev/null || true
        awg-quick down "${CONF_PATH}" 2>/dev/null || true
        awg-quick down /usr/local/etc/amnezia/awg0.conf 2>/dev/null || true
        ifconfig "${IFACE}" destroy 2>/dev/null || true
        pkill -f "route.*monitor" 2>/dev/null || true
    fi

    # Отключение автозапуска старого сервиса
    sysrc amneziawg_enable="NO" 2>/dev/null || true
    sed -i '' '/amneziawg_enable/d' /etc/rc.conf 2>/dev/null || true

    # Выгрузка старых модулей ядра
    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    # Удаление несовместимых пакетов AWG 1/2 из pkg (они не знают HeaderProtectionKey)
    if pkg info amnezia-tools >/dev/null 2>&1 || pkg info amnezia-kmod >/dev/null 2>&1; then
        info "$(t "Removing deprecated amnezia-tools/amnezia-kmod packages from pkg..." "Удаляем устаревшие пакеты amnezia-tools/amnezia-kmod из pkg...")"
        pkg delete -y amnezia-tools amnezia-kmod 2>/dev/null || true
        pkg autoremove -y 2>/dev/null || true
    fi

    ok "$(t "System cleaned of conflicting AWG 2.x components" "Система очищена от конфликтующих компонентов AWG 2.x")"
}

# =============================================================================
build_and_install_awg3() {
    header "$(t "Building and Installing AmneziaWG 3.1" "Сборка и установка компонентов AmneziaWG 3.1")"

    # Установка инструментов сборки
    info "$(t "Installing build tools (git, gmake, bash)..." "Установка сборочных утилит (git, gmake, bash)...")"
    pkg -N 2>/dev/null || pkg bootstrap -y || die "$(t "Failed to bootstrap pkg" "Не удалось инициализировать pkg")"
    pkg install -y git gmake bash || die "$(t "Failed to install git and gmake" "Не удалось установить git и gmake")"

    # 1. Сборка драйвера ядра wireguard-amnezia-kmod (v3.1.0)
    info "$(t "Building wireguard-amnezia-kmod v3.1.0 kernel module..." "Сборка модуля ядра wireguard-amnezia-kmod v3.1.0...")"
    KMOD_BUILD_DIR="/tmp/awg3-kmod-build"
    rm -rf "${KMOD_BUILD_DIR}"
    git clone --depth 1 -b v3.1.0 https://github.com/vgrebenschikov/wireguard-amnezia-kmod.git "${KMOD_BUILD_DIR}" || \
        die "$(t "Failed to clone wireguard-amnezia-kmod" "Не удалось клонировать wireguard-amnezia-kmod")"

    make -C "${KMOD_BUILD_DIR}" clean
    make -C "${KMOD_BUILD_DIR}" || die "$(t "Failed to compile wireguard-amnezia-kmod" "Ошибка компиляции модуля ядра wireguard-amnezia-kmod")"
    make -C "${KMOD_BUILD_DIR}" install || die "$(t "Failed to install wireguard-amnezia-kmod" "Ошибка установки модуля ядра wireguard-amnezia-kmod")"
    rm -rf "${KMOD_BUILD_DIR}"
    ok "$(t "AmneziaWG 3.1 kernel driver built and installed to /boot/modules/if_wg.ko" "Драйвер ядра AmneziaWG 3.1 собран и установлен в /boot/modules/if_wg.ko")"

    # 2. Сборка утилит amneziawg-tools с поддержкой AWG 3.1 и FreeBSD IPC (PR #77)
    info "$(t "Building awg and awg-quick tools (AWG 3.1)..." "Сборка утилит awg и awg-quick (AWG 3.1)...")"
    TOOLS_BUILD_DIR="/tmp/awg3-tools-build"
    rm -rf "${TOOLS_BUILD_DIR}"
    git clone https://github.com/amnezia-vpn/amneziawg-tools.git "${TOOLS_BUILD_DIR}" || \
        die "$(t "Failed to clone amneziawg-tools" "Не удалось клонировать amneziawg-tools")"

    # Подтягиваем патчи FreeBSD IPC для AWG 3.1 (PR #77 от vgrebenschikov)
    git -C "${TOOLS_BUILD_DIR}" fetch origin pull/77/head:awg31 || die "$(t "Failed to fetch PR #77" "Не удалось загрузить патч PR #77")"
    git -C "${TOOLS_BUILD_DIR}" checkout awg31

    # Патчим awg-quick для FreeBSD:
    # 1. Заставляем awg-quick вызывать скомпилированный awg 3.1, а не системный /usr/bin/wg
    # 2. Заставляем создавать нативный ядерный интерфейс if_wg.ko, а не amneziawg-go
    # 3. Отключаем background route monitor, блокирующий завершение скриптов и удерживающий дескрипторы
    info "$(t "Patching awg-quick for native if_wg.ko kernel driver and awg 3.1..." "Патчим awg-quick для работы с нативным модулем ядра if_wg.ko и утилитой awg 3.1...")"
    sed -i '' 's/cmd="amneziawg-go "\$INTERFACE"";/:;/' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"
    sed -i '' 's/\${WG_QUICK_USERSPACE_IMPLEMENTATION:-amneziawg-go}/ifconfig wg create name/g' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"
    sed -i '' 's/cmd wg setconf/cmd awg setconf/g' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"
    sed -i '' 's/cmd wg showconf/cmd awg showconf/g' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"
    sed -i '' 's/wg show/awg show/g' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"
    sed -i '' 's/.*Backgrounding route monitor.*/return 0/' "${TOOLS_BUILD_DIR}/src/wg-quick/freebsd.bash"

    gmake -C "${TOOLS_BUILD_DIR}/src" clean
    gmake -C "${TOOLS_BUILD_DIR}/src" PREFIX=/usr/local || die "$(t "Failed to compile amneziawg-tools" "Ошибка компиляции amneziawg-tools")"
    gmake -C "${TOOLS_BUILD_DIR}/src" PREFIX=/usr/local install || die "$(t "Failed to install amneziawg-tools" "Ошибка установки amneziawg-tools")"
    rm -rf "${TOOLS_BUILD_DIR}"

    # Гарантируем отсутствие случайного префикса aawg и отключение route monitor в awg-quick
    sed -i '' 's/aawg/awg/g' /usr/local/bin/awg-quick 2>/dev/null || true
    sed -i '' 's/.*Backgrounding route monitor.*/return 0/' /usr/local/bin/awg-quick 2>/dev/null || true

    # Создаём симлинк /usr/local/bin/wg -> /usr/local/bin/awg
    ln -sf /usr/local/bin/awg /usr/local/bin/wg

    # Проверка, что awg теперь знает HeaderProtectionKey
    if strings /usr/local/bin/awg 2>/dev/null | grep -qi "header-protection-key"; then
        ok "$(t "awg 3.1 utility successfully installed (HeaderProtectionKey confirmed)" "Утилита awg 3.1 успешно установлена (поддержка HeaderProtectionKey подтверждена)")"
    else
        warn "$(t "awg installed, but HeaderProtectionKey signature not found" "Утилита awg установлена, но сигнатура HeaderProtectionKey не найдена")"
    fi
}

# =============================================================================
load_kmod() {
    header "$(t "Loading AWG 3.1 Kernel Module" "Загрузка модуля ядра AWG 3.1")"

    # Выгружаем любые остаточные модули
    kldunload if_amn 2>/dev/null || true
    kldunload if_wg  2>/dev/null || true

    # Если в базовой системе есть стандартный WireGuard /boot/kernel/if_wg.ko,
    # сохраняем резервную копию и заменяем его на собранный модуль AmneziaWG 3.1.
    # Это гарантирует, что при перезагрузке FreeBSD не загрузит несовместимый базовый модуль.
    if [ -f "/boot/kernel/if_wg.ko" ]; then
        if [ ! -f "/boot/kernel/if_wg.ko.stock" ]; then
            cp -p /boot/kernel/if_wg.ko /boot/kernel/if_wg.ko.stock
            info "$(t "Created backup of stock WireGuard module: /boot/kernel/if_wg.ko.stock" "Создана резервная копия стандартного модуля WireGuard: /boot/kernel/if_wg.ko.stock")"
        fi
        cp -fp /boot/modules/if_wg.ko /boot/kernel/if_wg.ko
        kldxref /boot/kernel 2>/dev/null || true
        ok "$(t "Synchronized /boot/kernel/if_wg.ko for automated boot" "Синхронизирован модуль ядра /boot/kernel/if_wg.ko для автозагрузки")"
    fi

    info "$(t "Loading if_wg module (v3.1.0)..." "Загружаем модуль if_wg (v3.1.0)...")"
    kldload /boot/modules/if_wg.ko 2>/dev/null || kldload if_wg || die "$(t "Failed to load if_wg.ko kernel module" "Не удалось загрузить модуль /boot/modules/if_wg.ko")"
    LOADED_MOD=$(kldstat | grep -E 'if_wg|if_amn' | awk '{print $5}' | head -1)
    ok "$(t "Kernel module loaded:" "Модуль ядра загружен:") ${LOADED_MOD}"

    # Настройка автозагрузки в /boot/loader.conf
    sed -i '' '/if_amn_load/d' /boot/loader.conf 2>/dev/null || true
    if ! grep -q "if_wg_load" /boot/loader.conf 2>/dev/null; then
        echo 'if_wg_load="YES"' >> /boot/loader.conf
        ok "$(t "Auto-load if_wg added to /boot/loader.conf" "Автозагрузка if_wg прописана в /boot/loader.conf")"
    fi
}

# =============================================================================
prepare_config() {
    header "$(t "AWG 3.1 Configuration" "Конфигурация AWG 3.1")"

    mkdir -p "${AWG_DIR}"
    chmod 700 "${AWG_DIR}"

    cp "${CONF_FILE}" "${CONF_PATH}"
    chmod 600 "${CONF_PATH}"

    # Безопасный MTU для AWG 3.1 (защита от фрагментации из-за паддинга и заголовков ChaCha20)
    if ! grep -qi "^MTU" "${CONF_PATH}"; then
        sed -i '' "/^\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/a\\
MTU = 1280
" "${CONF_PATH}"
        info "$(t "Automatically set safe MTU = 1280 for AWG 3.1 protocol" "Автоматически установлен безопасный MTU = 1280 для протокола AWG 3.1")"
    fi

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
        ok "$(t "Mode: Split Tunneling AWG 3.1 (Table = off + selective routing)" "Режим: Раздельное туннелирование AWG 3.1 (Table = off + селективная маршрутизация)")"
    else
        ok "$(t "Mode: Full Tunnel AWG 3.1 (all traffic via VPN)" "Режим: Полный туннель AWG 3.1 (весь трафик через VPN)")"
    fi

    ok "$(t "Config saved:" "Конфиг сохранён:") ${CONF_PATH}"
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

    # Ожидаем завершения handshake туннеля (до 5 секунд) для готовности DNS
    for _i in 1 2 3 4 5; do
        _HS=\$(awg show "\${IFACE}" latest-handshakes 2>/dev/null | awk '{print \$2}')
        [ -n "\${_HS}" ] && [ "\${_HS}" -gt 0 ] 2>/dev/null && break
        sleep 1
    done

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
# REQUIRE: DAEMON NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

export PATH="/usr/local/bin:/usr/local/sbin:\$PATH"

name="amneziawg3"
rcvar="amneziawg3_enable"
desc="AmneziaWG 3.1 VPN Service"

start_cmd="amneziawg3_start"
stop_cmd="amneziawg3_stop"
status_cmd="amneziawg3_status"

: \${amneziawg3_enable:="NO"}
: \${amneziawg3_conf:="${CONF_PATH}"}

amneziawg3_start() {
    kldstat | grep -qE "if_wg|if_amn" || kldload /boot/modules/if_wg.ko 2>/dev/null || kldload if_wg
    /usr/local/bin/awg-quick up "\${amneziawg3_conf}"
}
amneziawg3_stop()   { /usr/local/bin/awg-quick down "\${amneziawg3_conf}" 2>/dev/null || true; }
amneziawg3_status() {
    ifconfig "${IFACE}" > /dev/null 2>&1 \
        && /usr/local/bin/awg show "${IFACE}" \
        || { echo "Остановлен"; return 1; }
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF

    chmod +x "${RC_SCRIPT}"
    sysrc amneziawg3_enable="YES"
    ok "$(t "amneziawg3 service configured in /etc/rc.conf" "Автозапуск сервиса amneziawg3 настроен в /etc/rc.conf")"
}

# =============================================================================
start_tunnel() {
    header "$(t "Starting AWG 3.1 Tunnel" "Запуск туннеля AWG 3.1")"

    # Если интерфейс уже существует — опускаем
    if ifconfig "${IFACE}" > /dev/null 2>&1; then
        info "$(t "Interface ${IFACE} already active — restarting..." "Интерфейс ${IFACE} уже активен — перезапуск...")"
        awg-quick down "${CONF_PATH}" 2>/dev/null || ifconfig "${IFACE}" destroy 2>/dev/null || true
        sleep 1
    fi

    info "$(t "Bringing up AWG 3.1 tunnel via awg-quick..." "Поднимаем туннель AWG 3.1 через awg-quick...")"
    awg-quick up "${CONF_PATH}" || die "$(t "Failed to start AmneziaWG 3.1" "Не удалось запустить AmneziaWG 3.1")"

    ifconfig "${IFACE}" > /dev/null 2>&1 || die "$(t "Interface ${IFACE} did not appear" "Интерфейс ${IFACE} не появился")"
    ok "$(t "Tunnel ${IFACE} (AmneziaWG 3.1) active" "Туннель ${IFACE} (AmneziaWG 3.1) активен")"
    awg show "${IFACE}"
}

# =============================================================================
verify() {
    header "$(t "Verification" "Проверка работы")"
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
        info "$(t "External IP (should be your regular ISP IP):" "Внешний IP (должен быть IP вашего провайдера):")"
    else
        info "$(t "External IP (should be AmneziaWG 3.1 VPN server IP):" "Внешний IP (должен быть IP VPN-сервера AWG 3.1):")"
    fi

    # Запрашиваем внешний IP с таймаутом 5 сек (защита от зависания)
    EXT_IP=$(fetch -T 5 -qo - https://api.ipify.org 2>/dev/null || fetch -T 5 -qo - https://icanhazip.com 2>/dev/null || true)
    VERIF_EXT_IP="${EXT_IP}"
    if [ -n "${TMP_STATUS}" ] && [ -n "${VERIF_EXT_IP}" ]; then
        echo "VERIF_EXT_IP='${VERIF_EXT_IP}'" >> "${TMP_STATUS}"
    fi
    if [ -n "${EXT_IP}" ]; then
        ok "$(t "External IP:" "Внешний IP:") ${EXT_IP}"
    else
        warn "$(t "Could not determine external IP (timeout or connection failed)" "Не удалось определить внешний IP (таймаут ответа или соединение не установилось)")"
    fi

    # Проверка handshake с сервером
    sleep 1
    HANDSHAKE_TS=$(awg show "${IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -n "${HANDSHAKE_TS}" ] && [ "${HANDSHAKE_TS}" -gt 0 ] 2>/dev/null; then
        NOW=$(date +%s)
        AGO=$((NOW - HANDSHAKE_TS))
        VERIF_AGO="${AGO}"
        if [ -n "${TMP_STATUS}" ]; then
            echo "VERIF_AGO='${VERIF_AGO}'" >> "${TMP_STATUS}"
        fi
        ok "$(t "Handshake with AmneziaWG 3.1 server successful" "Handshake с сервером AmneziaWG 3.1 успешно выполнен") (${AGO} $(t "sec ago" "сек назад"))"
    fi
}

# =============================================================================
print_summary() {
    printf "\n${BOLD}${MAGENTA}"
    printf "╔══════════════════════════════════════════════════════════╗\n"
    printf "║   %s   ║\n" "$(t "     AmneziaWG 3.1 (AWG3) successfully set up!    " "      AmneziaWG 3.1 (AWG3) успешно настроен!      ")"
    printf "╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"
    printf "${BOLD}%s:${RESET}    AmneziaWG 3.1 (Header Protection + Transport Padding)\n" "$(t "Protocol" "Протокол")"
    printf "${BOLD}%s:${RESET}     %s\n"  "$(t "Interface" "Туннель")" "${IFACE}"
    [ -n "${DOMAINS}" ] && printf "${BOLD}%s:${RESET}   %s\n" "$(t "Domains/IP" "Домены/IP")" "${DOMAINS}" || printf "${BOLD}%s:${RESET}       %s\n" "$(t "Mode" "Режим")" "$(t "All traffic via VPN" "Весь трафик через VPN")"
    printf "${BOLD}%s:${RESET}      %s\n"  "$(t "Config" "Конфиг")" "${CONF_PATH}"
    printf "${BOLD}%s:${RESET}         %s\n\n" "$(t "Log" "Лог")" "${LOG_FILE}"
    printf "${BOLD}%s:${RESET}\n" "$(t "Service Management" "Управление сервисом")"
    printf "  %s:   ${CYAN}service amneziawg3 status${RESET}\n" "$(t "Status" "Статус")"
    printf "  %s:     ${CYAN}service amneziawg3 stop${RESET}\n" "$(t "Stop" "Стоп")"
    printf "  %s:    ${CYAN}service amneziawg3 start${RESET}\n" "$(t "Start" "Старт")"
    printf "  %s: ${CYAN}netstat -rn | grep %s${RESET}\n" "$(t "Routes" "Маршруты")" "${IFACE}"
    printf "  %s:     ${CYAN}grep awg3-split /var/log/messages${RESET}\n" "$(t "Logs" "Логи")"
    printf "  %s:   ${CYAN}sudo $0 -u${RESET}\n\n" "$(t "Uninstall" "Удалить")"
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
# Точка входа: интерактивный мастер (если запущен без -c) и логирование
# =============================================================================
if [ "${UNINSTALL}" -eq 0 ] && [ -z "${CONF_FILE}" ] && [ -t 0 ]; then
    RUN_TUI=1
    run_wizard
fi

CONF_PATH="${AWG_DIR}/${IFACE}.conf"
ROUTE_SCRIPT="${AWG_DIR}/split-tunnel.sh"
RC_SCRIPT="/usr/local/etc/rc.d/amneziawg3"

if [ -z "${_AWG3_LOGGED}" ]; then
    export _AWG3_LOGGED=1
    TMP_EXIT="/tmp/awg3-exit.$$"
    export TMP_STATUS="/tmp/awg3-status.$$"
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
