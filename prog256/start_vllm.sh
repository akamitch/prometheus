#!/bin/bash

# Скрипт для запуска vLLM через MLNode API
# Использование: ./start_vllm.sh [node_id] [model_name]

set -e

# Загрузка переменных окружения
if [ -f config.env ]; then
    source config.env
else
    echo "Ошибка: config.env не найден"
    exit 1
fi

MLNODE_PORT=${PORT:-8080}
NODE_CONFIG=${NODE_CONFIG:-./node-config.json}

# Проверка наличия node-config.json
if [ ! -f "$NODE_CONFIG" ]; then
    echo "Ошибка: $NODE_CONFIG не найден"
    exit 1
fi

# Парсинг node-config.json для получения информации о нодах
echo "Чтение конфигурации из $NODE_CONFIG..."

# Получение первой ноды из конфига (можно расширить для выбора конкретной ноды)
NODE_ID=$(jq -r '.[0].id // empty' "$NODE_CONFIG" 2>/dev/null || echo "")
MODEL_NAME=$(jq -r '.[0].models | keys[0] // empty' "$NODE_CONFIG" 2>/dev/null || echo "")

# Переопределение через аргументы
if [ -n "$1" ]; then
    NODE_ID="$1"
fi

if [ -n "$2" ]; then
    MODEL_NAME="$2"
fi

if [ -z "$NODE_ID" ] || [ -z "$MODEL_NAME" ]; then
    echo "Ошибка: Не удалось определить NODE_ID или MODEL_NAME"
    echo "Использование: $0 [node_id] [model_name]"
    echo ""
    echo "Или укажите в node-config.json"
    exit 1
fi

echo "NODE_ID: $NODE_ID"
echo "MODEL_NAME: $MODEL_NAME"
echo "MLNode API: http://localhost:${MLNODE_PORT}"

# Проверка доступности MLNode API
echo -n "Проверка доступности MLNode API... "
MLNODE_AVAILABLE=false

# Пробуем разные endpoints
for endpoint in "/docs" "/health" "/api/v1/health" "/inference/up/status" ""; do
    if curl -s -f --max-time 3 "http://localhost:${MLNODE_PORT}${endpoint}" > /dev/null 2>&1; then
        MLNODE_AVAILABLE=true
        break
    fi
done

if [ "$MLNODE_AVAILABLE" = false ]; then
    echo "ОШИБКА"
    echo "MLNode API недоступен на порту ${MLNODE_PORT}"
    echo ""
    echo "Проверьте:"
    echo "  1. Контейнер mlnode-308 запущен:"
    echo "     docker compose -f docker-compose.yml -f docker-compose.mlnode.yml ps | grep mlnode"
    echo ""
    echo "  2. Порт ${MLNODE_PORT} открыт:"
    echo "     netstat -tuln | grep ${MLNODE_PORT} || ss -tuln | grep ${MLNODE_PORT}"
    echo ""
    echo "  3. Логи контейнера:"
    echo "     docker compose -f docker-compose.yml -f docker-compose.mlnode.yml logs mlnode-308 | tail -20"
    echo "     или найти контейнер:"
    echo "     docker ps | grep mlnode"
    echo "     docker logs \$(docker ps | grep mlnode | awk '{print \$1}') | tail -20"
    exit 1
fi
echo "OK"

# Проверка наличия jq
if ! command -v jq &> /dev/null; then
    echo "Ошибка: jq не найден. Установите jq для работы скрипта."
    exit 1
fi

# Получение аргументов для модели из конфига
MODEL_ARGS=$(jq -r --arg model "$MODEL_NAME" '.[0].models[$model].args // [] | join(" ")' "$NODE_CONFIG" 2>/dev/null || echo "")

# Проверка наличия параметров для решения проблемы с памятью GPU
# Если модель большая и не хватает памяти для KV cache, добавляем параметры
if echo "$MODEL_ARGS" | grep -qv "max-model-len\|gpu-memory-utilization"; then
    echo ""
    echo "⚠️  ВНИМАНИЕ: Модель может требовать настройки памяти GPU."
    echo "   Если возникнет ошибка 'max seq len is larger than KV cache',"
    echo "   добавьте в node-config.json в args модели:"
    echo ""
    echo "   Для ограниченной памяти (~18K токенов KV cache):"
    echo "   --max-model-len 16384 --gpu-memory-utilization 0.95"
    echo ""
    echo "   Для очень ограниченной памяти:"
    echo "   --max-model-len 8192 --gpu-memory-utilization 0.95"
    echo ""
    echo "   См. DIAGNOSTICS.md раздел 'Ошибка: max seq len is larger than KV cache'"
fi

# Формирование JSON запроса
if [ -n "$MODEL_ARGS" ]; then
    # Есть аргументы - разбиваем на массив
    REQUEST_JSON=$(jq -n \
        --arg model "$MODEL_NAME" \
        --arg args "$MODEL_ARGS" \
        '{
            "model": $model,
            "dtype": "auto",
            "additional_args": ($args | split(" ") | map(select(. != "")))
        }')
else
    # Нет аргументов
    REQUEST_JSON=$(jq -n \
        --arg model "$MODEL_NAME" \
        '{
            "model": $model,
            "dtype": "auto",
            "additional_args": []
        }')
fi

echo ""
echo "Запрос на запуск vLLM:"
echo "$REQUEST_JSON" | jq '.'

# Запуск vLLM (асинхронно)
echo ""
echo "Отправка запроса на запуск vLLM..."
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$REQUEST_JSON" \
    "http://localhost:${MLNODE_PORT}/api/v1/inference/up/async" 2>/dev/null || echo -e "\n000")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ vLLM запускается в фоновом режиме"
    echo ""
    echo "Ответ сервера:"
    if command -v jq &> /dev/null; then
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
    else
        echo "$BODY"
    fi
    echo ""
    echo "Для проверки статуса используйте:"
    echo "  curl http://localhost:${MLNODE_PORT}/api/v1/inference/up/status"
    echo ""
    echo "Или запустите диагностику:"
    echo "  ./diagnose.sh --verbose"
    echo ""
    echo "Примечание: Запуск vLLM может занять несколько минут в зависимости от размера модели."
elif [ "$HTTP_CODE" = "409" ]; then
    echo "⚠ vLLM уже запущен или запускается"
    echo ""
    echo "Ответ сервера:"
    if command -v jq &> /dev/null; then
        echo "$BODY" | jq -r '.detail // .message // .' 2>/dev/null || echo "$BODY"
    else
        echo "$BODY"
    fi
    echo ""
    echo "Проверьте статус:"
    echo "  curl http://localhost:${MLNODE_PORT}/api/v1/inference/up/status"
    echo ""
    echo "Если нужно перезапустить, сначала остановите:"
    echo "  curl -X POST http://localhost:${MLNODE_PORT}/api/v1/inference/down"
else
    echo "✗ Ошибка при запуске vLLM (HTTP $HTTP_CODE)"
    echo ""
    echo "Ответ сервера:"
    if command -v jq &> /dev/null; then
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
    else
        echo "$BODY"
    fi
    echo ""
    echo "Проверьте логи MLNode:"
    echo "  docker compose -f docker-compose.yml -f docker-compose.mlnode.yml logs mlnode-308 | tail -50"
    echo "  или:"
    echo "  docker logs \$(docker ps | grep mlnode | awk '{print \$1}') | tail -50"
    exit 1
fi

