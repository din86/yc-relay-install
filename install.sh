#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Цвета
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_INSTALL_PATH="/usr/local/bin/gokaskad"
BACKUP_DIR="/root/gokaskad-backups"

# =========================
# Вспомогательные функции
# =========================
type_text() {
    local text="${1:-}"
    local delay="${2:-0.015}"
    local i
    for ((i=0; i<${#text}; i++)); do
        echo -n "${text:$i:1}"
        sleep "$delay"
    done
    echo
}

pause() {
    read -rp "Нажмите Enter для продолжения..."
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        echo -e "${YELLOW}Пример:${NC} sudo ./install.sh"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
}

backup_rules() {
    ensure_backup_dir
    local backup_file="$BACKUP_DIR/iptables-$(date +%F-%H%M%S).rules"
    iptables-save > "$backup_file"
    echo -e "${CYAN}[*] Резервная копия iptables: ${WHITE}$backup_file${NC}"
}

get_main_iface() {
    local iface
    iface="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')"
    if [[ -z "${iface}" ]]; then
        echo -e "${RED}[ERROR] Не удалось определить сетевой интерфейс.${NC}"
        exit 1
    fi
    echo "$iface"
}

validate_ip() {
    local ip="$1"
    local stat=1
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        read -r -a iparr <<< "$ip"
        IFS=$OIFS
        if [[ ${iparr[0]} -le 255 && ${iparr[1]} -le 255 && ${iparr[2]} -le 255 && ${iparr[3]} -le 255 ]]; then
            stat=0
        fi
    fi
    return $stat
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

normalize_proto() {
    local proto="$1"
    case "$proto" in
        tcp|udp) echo "$proto" ;;
        *)
            echo -e "${RED}[ERROR] Протокол должен быть tcp или udp.${NC}"
            return 1
            ;;
    esac
}

# =========================
# Подготовка системы
# =========================
prepare_system() {
    echo -e "${CYAN}[*] Подготовка системы...${NC}"

    # Установка глобальной команды gokaskad
    if [[ "${0}" != "${SCRIPT_INSTALL_PATH}" ]]; then
        cp -f "$0" "$SCRIPT_INSTALL_PATH"
        chmod +x "$SCRIPT_INSTALL_PATH"
    fi

    # Включение IP Forwarding
    if grep -qE '^\s*#?\s*net\.ipv4\.ip_forward=' /etc/sysctl.conf; then
        sed -i 's/^\s*#\?\s*net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # BBR
    if grep -qE '^\s*#?\s*net\.core\.default_qdisc=' /etc/sysctl.conf; then
        sed -i 's/^\s*#\?\s*net\.core\.default_qdisc=.*/net.core.default_qdisc=fq/' /etc/sysctl.conf
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi

    if grep -qE '^\s*#?\s*net\.ipv4\.tcp_congestion_control=' /etc/sysctl.conf; then
        sed -i 's/^\s*#\?\s*net\.ipv4\.tcp_congestion_control=.*/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
    else
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null

    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        apt-get install -y iptables-persistent netfilter-persistent qrencode >/dev/null
    else
        apt-get install -y netfilter-persistent qrencode >/dev/null
    fi

    ensure_backup_dir

    echo -e "${GREEN}[OK] Система подготовлена.${NC}"
}

# =========================
# Информационный экран
# =========================
show_info() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                  GOKASKAD - RELAY/NAT TOOL                  ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}Возможности:${NC}"
    echo -e " - Проброс ${YELLOW}TCP${NC} и ${YELLOW}UDP${NC}"
    echo -e " - Одинаковые или разные входящие/исходящие порты"
    echo -e " - Сохранение правил после перезагрузки"
    echo -e " - Просмотр, удаление и полный сброс правил"
    echo
    echo -e "${CYAN}Глобальная команда:${NC} ${WHITE}gokaskad${NC}"
    echo
    if command_exists qrencode; then
        echo -e "${CYAN}QR на IP этого сервера:${NC}"
        local myip
        myip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        if [[ -n "${myip}" ]]; then
            qrencode -t ANSIUTF8 "Server IP: ${myip}" || true
        fi
    fi
    echo
    pause
}

# =========================
# Инструкция
# =========================
show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                    ИНСТРУКЦИЯ ПО НАСТРОЙКЕ                  ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}Шаг 1. Подготовь данные конечного сервера:${NC}"
    echo -e " - IP адрес назначения"
    echo -e " - Порт конечного сервиса"
    echo -e " - Протокол: tcp или udp"
    echo
    echo -e "${CYAN}Шаг 2. Выбери тип правила:${NC}"
    echo -e " - ${GREEN}1-3${NC}: если входящий и исходящий порт одинаковые"
    echo -e " - ${GREEN}4${NC}: если входящий и исходящий порт разные"
    echo
    echo -e "${CYAN}Шаг 3. Что происходит после настройки:${NC}"
    echo -e " Клиент -> ЭТОТ сервер -> Конечный сервер"
    echo
    echo -e "${CYAN}Шаг 4. Проверка:${NC}"
    echo -e " - Посмотреть активные правила в меню"
    echo -e " - Проверить tcpdump на этом сервере"
    echo -e " - Проверить tcpdump на конечном сервере"
    echo
    echo -e "${CYAN}Типовые проблемы:${NC}"
    echo -e " - Не открыт порт в Security Group / firewall"
    echo -e " - Неверный IP назначения"
    echo -e " - Неверный протокол tcp/udp"
    echo -e " - На сервере не включён ip_forward"
    echo
    pause
}

# =========================
# Проверка/применение правил
# =========================
save_rules() {
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null
    elif command_exists service; then
        service netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

allow_ufw_if_needed() {
    local proto="$1"
    local in_port="$2"

    if command_exists ufw; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "${in_port}/${proto}" >/dev/null || true
            if [[ -f /etc/default/ufw ]]; then
                sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
            fi
            ufw reload >/dev/null || true
        fi
    fi
}

apply_iptables_rules() {
    local proto="$1"
    local in_port="$2"
    local out_port="$3"
    local target_ip="$4"
    local name="$5"
    local iface

    proto="$(normalize_proto "$proto")"
    validate_port "$in_port" || { echo -e "${RED}[ERROR] Неверный входящий порт.${NC}"; return 1; }
    validate_port "$out_port" || { echo -e "${RED}[ERROR] Неверный исходящий порт.${NC}"; return 1; }
    validate_ip "$target_ip" || { echo -e "${RED}[ERROR] Неверный IP адрес назначения.${NC}"; return 1; }

    iface="$(get_main_iface)"
    backup_rules

    echo -e "${YELLOW}[*] Применение правил...${NC}"
    echo -e "${CYAN}[*] Интерфейс: ${WHITE}${iface}${NC}"

    # Удаление старого дубля, если есть
    iptables -t nat -D PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$target_ip:$out_port" 2>/dev/null || true
    iptables -D INPUT -p "$proto" --dport "$in_port" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # Новые правила
    iptables -C INPUT -p "$proto" --dport "$in_port" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$proto" --dport "$in_port" -j ACCEPT

    iptables -t nat -C PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$target_ip:$out_port" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$target_ip:$out_port"

    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

    iptables -C FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

    iptables -C FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    allow_ufw_if_needed "$proto" "$in_port"
    save_rules

    echo -e "${GREEN}[SUCCESS] ${name} настроен!${NC}"
    echo -e "${WHITE}${proto}: вход ${in_port} -> выход ${target_ip}:${out_port}${NC}"
    pause
}

# =========================
# Стандартные и кастомные правила
# =========================
configure_rule() {
    local proto="$1"
    local name="$2"
    local target_ip port

    echo -e "\n${CYAN}--- Настройка ${name} (${proto}) ---${NC}"

    while true; do
        read -rp "Введите IP адрес назначения: " target_ip
        if validate_ip "$target_ip"; then
            break
        fi
        echo -e "${RED}Ошибка: неверный IP.${NC}"
    done

    while true; do
        read -rp "Введите порт (одинаковый для входа и выхода): " port
        if validate_port "$port"; then
            break
        fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535.${NC}"
    done

    apply_iptables_rules "$proto" "$port" "$port" "$target_ip" "$name"
}

configure_custom_rule() {
    local proto target_ip in_port out_port

    echo -e "\n${CYAN}--- Универсальное кастомное правило ---${NC}"
    echo -e "${WHITE}Подходит для SSH, RDP, VLESS, MTProto, нестандартных сервисов и любых TCP/UDP пробросов.${NC}\n"

    while true; do
        read -rp "Выберите протокол (tcp/udp): " proto
        if [[ "$proto" == "tcp" || "$proto" == "udp" ]]; then
            break
        fi
        echo -e "${RED}Ошибка: введите tcp или udp.${NC}"
    done

    while true; do
        read -rp "Введите IP адрес назначения: " target_ip
        if validate_ip "$target_ip"; then
            break
        fi
        echo -e "${RED}Ошибка: неверный IP.${NC}"
    done

    while true; do
        read -rp "Введите ВХОДЯЩИЙ порт на этом сервере: " in_port
        if validate_port "$in_port"; then
            break
        fi
        echo -e "${RED}Ошибка: неверный порт.${NC}"
    done

    while true; do
        read -rp "Введите ИСХОДЯЩИЙ порт на конечном сервере: " out_port
        if validate_port "$out_port"; then
            break
        fi
        echo -e "${RED}Ошибка: неверный порт.${NC}"
    done

    apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" "Custom Rule"
}

# =========================
# Список правил
# =========================
list_active_rules() {
    clear
    echo -e "${CYAN}--- Активные переадресации ---${NC}"
    echo -e "${MAGENTA}ПОРТ(ВХОД)\tПРОТОКОЛ\tЦЕЛЬ(IP:ВЫХОД)${NC}"

    local found=0
    while IFS= read -r line; do
        local l_port l_proto l_dest
        l_port="$(echo "$line" | grep -oP '(?<=--dport )\d+' || true)"
        l_proto="$(echo "$line" | grep -oP '(?<=-p )\w+' || true)"
        l_dest="$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+' || true)"
        if [[ -n "$l_port" && -n "$l_proto" && -n "$l_dest" ]]; then
            printf "%-12s\t%-8s\t%s\n" "$l_port" "$l_proto" "$l_dest"
            found=1
        fi
    done < <(iptables -t nat -S PREROUTING | grep "DNAT" || true)

    if [[ "$found" -eq 0 ]]; then
        echo -e "${YELLOW}Нет активных DNAT правил.${NC}"
    fi

    echo
    echo -e "${CYAN}Проверка ip_forward:${NC}"
    sysctl net.ipv4.ip_forward | sed 's/^/  /'

    echo
    echo -e "${CYAN}Подсказка для проверки трафика:${NC}"
    echo -e "  tcpdump -ni any tcp port <PORT>"
    echo -e "  tcpdump -ni any udp port <PORT>"
    echo
    pause
}

# =========================
# Удаление одного правила
# =========================
delete_single_rule() {
    clear
    echo -e "${CYAN}--- Удаление правила ---${NC}"

    declare -a RULES_LIST=()
    local i=1

    while IFS= read -r line; do
        local l_port l_proto l_dest
        l_port="$(echo "$line" | grep -oP '(?<=--dport )\d+' || true)"
        l_proto="$(echo "$line" | grep -oP '(?<=-p )\w+' || true)"
        l_dest="$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+' || true)"
        if [[ -n "$l_port" && -n "$l_proto" && -n "$l_dest" ]]; then
            RULES_LIST[$i]="${l_port}:${l_proto}:${l_dest}"
            echo -e "${YELLOW}[$i]${NC} Вход: ${WHITE}${l_port}${NC} (${l_proto}) -> Выход: ${WHITE}${l_dest}${NC}"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING | grep "DNAT" || true)

    if [[ ${#RULES_LIST[@]} -eq 0 ]]; then
        echo -e "${RED}Нет активных правил.${NC}"
        pause
        return
    fi

    echo
    read -rp "Введите номер правила для удаления (0 - отмена): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]:-}" ]]; then
        return
    fi

    backup_rules

    local raw d_port d_proto d_dest target_ip target_port
    raw="${RULES_LIST[$rule_num]}"
    d_port="${raw%%:*}"
    local rest="${raw#*:}"
    d_proto="${rest%%:*}"
    d_dest="${rest#*:}"
    target_ip="${d_dest%:*}"
    target_port="${d_dest##*:}"

    iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_dest" 2>/dev/null || true
    iptables -D INPUT -p "$d_proto" --dport "$d_port" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p "$d_proto" -d "$target_ip" --dport "$target_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p "$d_proto" -s "$target_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    save_rules
    echo -e "${GREEN}[OK] Правило удалено.${NC}"
    pause
}

# =========================
# Полная очистка
# =========================
flush_rules() {
    clear
    echo -e "${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo -e "${YELLOW}Будут очищены все правила iptables:${NC}"
    echo -e " - filter"
    echo -e " - nat"
    echo -e " - mangle"
    echo
    echo -e "${RED}Это может затронуть Docker, VPN и другие сервисы.${NC}"
    read -rp "Вы уверены? (yes/no): " confirm

    if [[ "$confirm" == "yes" ]]; then
        backup_rules
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        save_rules
        echo -e "${GREEN}[OK] Все правила очищены.${NC}"
    else
        echo -e "${YELLOW}Отменено.${NC}"
    fi

    pause
}

# =========================
# Полезные проверки
# =========================
show_checks() {
    clear
    echo -e "${CYAN}--- Полезные команды для проверки ---${NC}"
    echo
    echo -e "${WHITE}1. Проверить NAT правила:${NC}"
    echo "iptables -t nat -S"
    echo
    echo -e "${WHITE}2. Проверить FORWARD:${NC}"
    echo "iptables -S FORWARD"
    echo
    echo -e "${WHITE}3. Проверить ip_forward:${NC}"
    echo "sysctl net.ipv4.ip_forward"
    echo
    echo -e "${WHITE}4. Проверить трафик на порту:${NC}"
    echo "tcpdump -ni any udp port 42673"
    echo "tcpdump -ni any tcp port 443"
    echo
    echo -e "${WHITE}5. Проверить с внешней машины:${NC}"
    echo "echo test | nc -u -w1 <SERVER_IP> <PORT>"
    echo "nc -vzu <SERVER_IP> <PORT>"
    echo
    pause
}

# =========================
# Меню
# =========================
show_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}"
        echo "******************************************************"
        echo "                   GOKASKAD INSTALLER                "
        echo "******************************************************"
        echo -e "${NC}"
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Настроить ${CYAN}MTProto / TProxy${NC} (TCP)"
        echo -e "4) ${YELLOW}Создать кастомное правило${NC} (разные порты)"
        echo -e "5) Посмотреть активные правила"
        echo -e "6) ${RED}Удалить одно правило${NC}"
        echo -e "7) ${RED}Сбросить все iptables правила${NC}"
        echo -e "8) Показать информацию о скрипте"
        echo -e "9) Показать инструкцию"
        echo -e "10) Полезные команды проверки"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"

        read -rp "Ваш выбор: " choice

        case "$choice" in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS/XRay" ;;
            3) configure_rule "tcp" "MTProto/TProxy" ;;
            4) configure_custom_rule ;;
            5) list_active_rules ;;
            6) delete_single_rule ;;
            7) flush_rules ;;
            8) show_info ;;
            9) show_instructions ;;
            10) show_checks ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный пункт меню.${NC}"; sleep 1 ;;
        esac
    done
}

# =========================
# Запуск
# =========================
main() {
    check_root
    prepare_system
    show_menu
}

main "$@"