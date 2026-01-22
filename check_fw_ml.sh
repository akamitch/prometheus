#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ВСЕ эти порты должны быть ЗАКРЫТЫ (недоступны снаружи)
ALL_PORTS=(9100 9200 5050 8080 5000 26657 8000)

# Таймаут для проверки (секунды)
TIMEOUT=3

# Проверка доступности nmap
USE_NMAP=false
if command -v nmap &> /dev/null; then
    USE_NMAP=true
fi

# Функция проверки порта через bash
check_port_bash() {
    local ip=$1
    local port=$2
    
    timeout $TIMEOUT bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null
    return $?
}

# Функция проверки порта через nmap
check_port_nmap() {
    local ip=$1
    local port=$2
    
    local result=$(nmap -Pn -p "$port" --open -T4 "$ip" 2>/dev/null | grep -c "^$port/tcp.*open")
    
    if [ "$result" -eq 1 ]; then
        return 0  # Порт открыт
    else
        return 1  # Порт закрыт
    fi
}

# Функция проверки порта (выбирает метод)
check_port() {
    local ip=$1
    local port=$2
    
    if [ "$USE_NMAP" = true ]; then
        check_port_nmap "$ip" "$port"
    else
        check_port_bash "$ip" "$port"
    fi
    
    return $?
}

# Функция проверки одного сервера
check_server() {
    local ip=$1
    local failed=0
    local details=""
    
    echo -ne "${BLUE}Проверка $ip...${NC}\r"
    
    # Проверяем все порты - все должны быть ЗАКРЫТЫ
    for port in "${ALL_PORTS[@]}"; do
        if check_port "$ip" "$port"; then
            failed=1
            details+="  ${RED}✗${NC} Порт $port ${RED}ОТКРЫТ${NC} (должен быть закрыт)\n"
        else
            details+="  ${GREEN}✓${NC} Порт $port закрыт\n"
        fi
    done
    
    # Вывод результата
    if [ $failed -eq 0 ]; then
        echo -e "${ip} ${GREEN}✓ PASSED${NC}"
    else
        echo -e "${ip} ${RED}✗ FAILED${NC}"
        echo -e "$details"
    fi
    
    return $failed
}

# Главная функция
main() {
    local ip_file="$1"
    
    # Проверка наличия файла со списком IP
    if [ -z "$ip_file" ]; then
        echo "Использование: $0 <файл_с_IP>"
        echo ""
        echo "Создайте файл servers.txt со списком IP адресов (один на строку)"
        echo "Пример:"
        echo "  192.168.1.10"
        echo "  192.168.1.11"
        echo "  ml-server.example.com"
        exit 1
    fi
    
    if [ ! -f "$ip_file" ]; then
        echo -e "${RED}Ошибка: файл '$ip_file' не найден${NC}"
        exit 1
    fi
    
    echo "========================================="
    echo "   Проверка файерволов (ML серверы)"
    echo "========================================="
    echo "ВСЕ порты должны быть ЗАКРЫТЫ: ${ALL_PORTS[*]}"
    
    if [ "$USE_NMAP" = true ]; then
        echo "Метод проверки: nmap"
    else
        echo "Метод проверки: bash TCP (для более точной проверки установите nmap)"
    fi
    
    echo "========================================="
    echo ""
    
    local total=0
    local passed=0
    local failed_count=0
    
    # Читаем файл и проверяем каждый IP
    while IFS= read -r ip || [ -n "$ip" ]; do
        # Пропускаем пустые строки и комментарии
        if [ -z "$ip" ] || [[ "$ip" =~ ^# ]]; then
            continue
        fi
        
        ((total++))
        
        if check_server "$ip"; then
            ((passed++))
        else
            ((failed_count++))
        fi
        
        echo ""
    done < "$ip_file"
    
    # Итоговая статистика
    echo "========================================="
    echo "           Итоговая статистика"
    echo "========================================="
    echo -e "Всего проверено: $total"
    echo -e "${GREEN}Passed: $passed${NC}"
    echo -e "${RED}Failed: $failed_count${NC}"
    
    if [ $failed_count -eq 0 ]; then
        echo -e "\n${GREEN}✓ Все серверы настроены правильно!${NC}"
    else
        echo -e "\n${RED}✗ Обнаружены проблемы с файерволами!${NC}"
        echo -e "${YELLOW}Необходимо закрыть открытые порты на серверах с ошибками.${NC}"
    fi
    
    echo "========================================="
    
    # Возвращаем код ошибки если были failed
    return $failed_count
}

# Запуск
main "$@"
exit $?
