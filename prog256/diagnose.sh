#!/bin/bash

# Скрипт диагностики сервисов Gonka
# Использование: ./diagnose.sh [--verbose] [--logs]

set -e

VERBOSE=false
SHOW_LOGS=false
API_PORT=8000
ADMIN_PORT=9200
MLNODE_PORT=8080
CHAIN_RPC_PORT=26657

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --logs|-l)
            SHOW_LOGS=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "Использование: $0 [--verbose] [--logs]"
            exit 1
            ;;
    esac
done

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода заголовка
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Функция для вывода статуса
print_status() {
    if [ "$1" = "OK" ]; then
        echo -e "${GREEN}✓${NC} $2"
    elif [ "$1" = "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

# Загрузка переменных окружения
if [ -f config.env ]; then
    source config.env
    print_status "OK" "Загружен config.env"
else
    print_status "WARN" "config.env не найден, используются значения по умолчанию"
fi

# Определение портов из config.env или значений по умолчанию
API_PORT=${API_PORT:-8000}
ADMIN_PORT=${DAPI_API__ADMIN_SERVER_PORT:-9200}
MLNODE_PORT=${PORT:-8080}
CHAIN_RPC_PORT=26657

# Проверка зависимостей
print_header "Проверка зависимостей"

if ! command -v docker &> /dev/null; then
    print_status "FAIL" "docker не найден"
    exit 1
fi
print_status "OK" "docker найден"

if ! command -v curl &> /dev/null; then
    print_status "FAIL" "curl не найден"
    exit 1
fi
print_status "OK" "curl найден"

if ! command -v jq &> /dev/null; then
    print_status "WARN" "jq не найден (некоторые функции будут ограничены)"
    HAS_JQ=false
else
    print_status "OK" "jq найден"
    HAS_JQ=true
fi

print_header "Диагностика сервисов Gonka"
echo "Время: $(date)"
echo "Рабочая директория: $(pwd)"

# 1. Проверка Docker контейнеров
print_header "1. Статус Docker контейнеров"

EXPECTED_CONTAINERS=("tmkms" "node" "api" "proxy" "mlnode-308" "inference")
COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.mlnode.yml"

if [ -n "$($COMPOSE_CMD ps -q 2>/dev/null)" ]; then
    print_status "OK" "Docker Compose работает"
    
    echo -e "\nСписок контейнеров:"
    $COMPOSE_CMD ps
    
    echo -e "\nСтатус контейнеров:"
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        # Ищем контейнер по точному имени или по части имени (для docker compose с префиксом проекта)
        found_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^${container}$|${container}" | head -1)
        
        if [ -n "$found_container" ]; then
            status=$(docker inspect --format='{{.State.Status}}' "$found_container" 2>/dev/null || echo "not found")
            health=$(docker inspect --format='{{.State.Health.Status}}' "$found_container" 2>/dev/null || echo "no healthcheck")
            if [ "$status" = "running" ]; then
                if [ "$health" = "healthy" ] || [ "$health" = "no healthcheck" ]; then
                    if [ "$found_container" = "$container" ]; then
                        print_status "OK" "Контейнер $container: $status"
                    else
                        print_status "OK" "Контейнер $container (найден как $found_container): $status"
                    fi
                else
                    print_status "WARN" "Контейнер $container ($found_container): $status (health: $health)"
                fi
            else
                print_status "FAIL" "Контейнер $container ($found_container): $status"
            fi
        else
            # Проверка через docker compose ps (по части имени)
            if $COMPOSE_CMD ps --format json 2>/dev/null | grep -q "${container}"; then
                print_status "WARN" "Контейнер $container найден в compose, но не запущен"
            else
                print_status "WARN" "Контейнер $container не найден"
            fi
        fi
    done
else
    print_status "FAIL" "Docker Compose не запущен или контейнеры не найдены"
    echo "Попробуйте запустить:"
    echo "  source config.env && docker compose -f docker-compose.yml -f docker-compose.mlnode.yml up -d"
fi

# 2. Проверка логов на ошибки
print_header "2. Проверка логов на ошибки"

if [ "$SHOW_LOGS" = true ]; then
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "\nПоследние ошибки в контейнере $container:"
            docker logs "$container" --tail 50 2>&1 | grep -i "error\|fatal\|panic\|failed" | tail -5 || echo "  Ошибок не найдено"
        fi
    done
else
    echo "Используйте --logs для просмотра ошибок в логах"
fi

# 3. Проверка доступности API endpoints
print_header "3. Проверка доступности API endpoints"

# 3.1 Chain RPC
echo -n "Проверка Chain RPC (localhost:${CHAIN_RPC_PORT}/status)... "
if curl -s -f "http://localhost:${CHAIN_RPC_PORT}/status" > /dev/null 2>&1; then
    print_status "OK" "Chain RPC доступен"
    if [ "$VERBOSE" = true ]; then
        if [ "$HAS_JQ" = true ]; then
            chain_status=$(curl -s "http://localhost:${CHAIN_RPC_PORT}/status" | jq -r '.result.sync_info.latest_block_height // "unknown"' 2>/dev/null || echo "unknown")
            echo "  Высота блока: $chain_status"
        else
            echo "  (jq не установлен, детальная информация недоступна)"
        fi
    fi
else
    print_status "FAIL" "Chain RPC недоступен"
fi

# 3.2 API Health
echo -n "Проверка API Health (localhost:${API_PORT}/health)... "
if curl -s -f "http://localhost:${API_PORT}/health" > /dev/null 2>&1; then
    print_status "OK" "API Health endpoint доступен"
else
    print_status "FAIL" "API Health endpoint недоступен"
fi

# 3.3 Admin API
echo -n "Проверка Admin API (localhost:${ADMIN_PORT}/admin/v1/nodes)... "
admin_response=$(curl -s -w "\n%{http_code}" "http://localhost:${ADMIN_PORT}/admin/v1/nodes" 2>/dev/null || echo -e "\n000")
http_code=$(echo "$admin_response" | tail -1)
if [ "$http_code" = "200" ]; then
    print_status "OK" "Admin API доступен"
    if [ "$VERBOSE" = true ] && [ "$HAS_JQ" = true ]; then
        nodes=$(echo "$admin_response" | head -n -1 | jq -r 'length // 0' 2>/dev/null || echo "0")
        echo "  Зарегистрированных нод: $nodes"
    fi
else
    print_status "FAIL" "Admin API недоступен (HTTP $http_code)"
fi

# 3.4 MLNode API
echo -n "Проверка MLNode API (localhost:${MLNODE_PORT})... "
MLNODE_API_OK=false
for endpoint in "/docs" "/health" "/api/v1/health" "/api/v1/inference/up/status" ""; do
    if curl -s -f --max-time 3 "http://localhost:${MLNODE_PORT}${endpoint}" > /dev/null 2>&1; then
        MLNODE_API_OK=true
        break
    fi
done

if [ "$MLNODE_API_OK" = true ]; then
    print_status "OK" "MLNode API доступен"
else
    print_status "FAIL" "MLNode API недоступен"
fi

# 4. Проверка статуса vLLM через MLNode API
print_header "4. Проверка статуса vLLM"

if curl -s -f "http://localhost:${MLNODE_PORT}/api/v1/inference/up/status" > /dev/null 2>&1; then
    vllm_status=$(curl -s "http://localhost:${MLNODE_PORT}/api/v1/inference/up/status" 2>/dev/null || echo "{}")
    if [ "$HAS_JQ" = true ] && echo "$vllm_status" | jq -e '.status' > /dev/null 2>&1; then
        status=$(echo "$vllm_status" | jq -r '.status // "unknown"')
        if [ "$status" = "running" ] || [ "$status" = "ready" ]; then
            print_status "OK" "vLLM статус: $status"
        else
            print_status "WARN" "vLLM статус: $status"
        fi
        if [ "$VERBOSE" = true ]; then
            echo "$vllm_status" | jq '.'
        fi
    elif [ "$HAS_JQ" = false ]; then
        # Без jq просто показываем сырой ответ
        if echo "$vllm_status" | grep -q "running\|ready"; then
            print_status "OK" "vLLM работает (детали недоступны без jq)"
        else
            print_status "WARN" "vLLM статус неопределен (установите jq для детальной информации)"
        fi
        if [ "$VERBOSE" = true ]; then
            echo "$vllm_status"
        fi
    else
        print_status "WARN" "Не удалось получить статус vLLM"
    fi
else
    print_status "FAIL" "Не удалось подключиться к MLNode API для проверки vLLM"
fi

# 5. Проверка статуса нод через Admin API
print_header "5. Проверка статуса нод"

if [ "$http_code" = "200" ]; then
    nodes_json=$(echo "$admin_response" | head -n -1)
    if [ "$HAS_JQ" = true ]; then
        if echo "$nodes_json" | jq -e '.nodes' > /dev/null 2>&1; then
            nodes_json=$(echo "$nodes_json" | jq '.nodes')
        fi
        
        node_count=$(echo "$nodes_json" | jq -r 'length // 0' 2>/dev/null || echo "0")
        if [ "$node_count" -gt 0 ]; then
            print_status "OK" "Найдено нод: $node_count"
            echo ""
            echo "$nodes_json" | jq -r '.[] | "  ID: \(.id // .Id // "unknown"), Enabled: \(.state.admin_state.enabled // .State.AdminState.Enabled // "unknown"), Status: \(.state.status // .State.Status // "unknown")"' 2>/dev/null || \
            echo "$nodes_json" | jq -r '.[] | "  ID: \(.id), Enabled: \(.state.admin_state.enabled), Status: \(.state.status)"' 2>/dev/null || \
            echo "  Не удалось распарсить информацию о нодах"
            
            if [ "$VERBOSE" = true ]; then
                echo ""
                echo "Полная информация о нодах:"
                echo "$nodes_json" | jq '.'
            fi
        else
            print_status "WARN" "Ноды не найдены или не зарегистрированы"
        fi
    else
        print_status "OK" "Admin API отвечает (установите jq для детальной информации)"
        if [ "$VERBOSE" = true ]; then
            echo "$nodes_json"
        fi
    fi
else
    print_status "FAIL" "Не удалось получить список нод"
fi

# 6. Проверка подключения к сети
print_header "6. Проверка подключения к сети"

if [ -n "$SEED_NODE_RPC_URL" ]; then
    seed_host=$(echo "$SEED_NODE_RPC_URL" | sed 's|http://||' | cut -d: -f1)
    echo -n "Проверка подключения к seed node ($seed_host)... "
    if curl -s -f --max-time 5 "$SEED_NODE_RPC_URL/status" > /dev/null 2>&1; then
        print_status "OK" "Подключение к seed node работает"
    else
        print_status "WARN" "Не удалось подключиться к seed node"
    fi
fi

# 7. Проверка GPU (если доступно)
print_header "7. Проверка GPU"

if command -v nvidia-smi &> /dev/null; then
    gpu_count=$(nvidia-smi --list-gpus | wc -l)
    if [ "$gpu_count" -gt 0 ]; then
        print_status "OK" "Найдено GPU: $gpu_count"
        if [ "$VERBOSE" = true ]; then
            echo ""
            nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits | \
            while IFS=',' read -r index name mem_total mem_used util; do
                echo "  GPU $index: $name, Память: ${mem_used}MB/${mem_total}MB, Утилизация: ${util}%"
            done
        fi
    else
        print_status "WARN" "GPU не найдены"
    fi
else
    print_status "WARN" "nvidia-smi не найден (GPU проверка пропущена)"
fi

# 8. Проверка дискового пространства
print_header "8. Проверка дискового пространства"

if [ -n "$HF_HOME" ]; then
    hf_path="$HF_HOME"
else
    hf_path="${HOME}/.cache/huggingface"
fi

if [ -d "$hf_path" ]; then
    hf_size=$(du -sh "$hf_path" 2>/dev/null | cut -f1 || echo "unknown")
    print_status "OK" "HF cache: $hf_size ($hf_path)"
else
    print_status "WARN" "HF cache не найден: $hf_path"
fi

# Итоговая сводка
print_header "Итоговая сводка"

echo "Для более детальной информации используйте:"
echo "  $0 --verbose    # Подробный вывод"
echo "  $0 --logs       # Показать ошибки из логов"
echo "  $0 --verbose --logs  # Полная диагностика"
echo ""
echo "Полезные команды:"
echo "  docker compose -f docker-compose.yml -f docker-compose.mlnode.yml logs -f <container>  # Просмотр логов контейнера"
echo "  docker logs \$(docker ps | grep <container> | awk '{print \$1}') -f  # Альтернативный способ"
echo "  curl http://localhost:${ADMIN_PORT}/admin/v1/nodes  # Список нод"
echo "  curl http://localhost:${MLNODE_PORT}/api/v1/inference/up/status  # Статус vLLM"
echo "  curl http://localhost:${CHAIN_RPC_PORT}/status  # Статус chain node"

