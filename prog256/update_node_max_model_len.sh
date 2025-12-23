#!/bin/bash

# Скрипт для обновления max-model-len через Admin API
# Использование: ./update_node_max_model_len.sh <node_id> <model_name> <max_model_len> [gpu_memory_utilization]

set -e

# Загрузка переменных окружения
if [ -f config.env ]; then
    source config.env
else
    echo "Ошибка: config.env не найден"
    exit 1
fi

ADMIN_PORT=${DAPI_API__ADMIN_SERVER_PORT:-9200}
ADMIN_URL="http://localhost:${ADMIN_PORT}"

# Проверка аргументов
if [ $# -lt 3 ]; then
    echo "Использование: $0 <node_id> <model_name> <max_model_len> [gpu_memory_utilization]"
    echo ""
    echo "Примеры:"
    echo "  $0 node14 Qwen/Qwen3-32B-FP8 16384"
    echo "  $0 node14 Qwen/Qwen3-32B-FP8 16384 0.95"
    echo ""
    echo "Параметры:"
    echo "  node_id              - ID ноды (например, node14)"
    echo "  model_name           - Имя модели (например, Qwen/Qwen3-32B-FP8)"
    echo "  max_model_len        - Максимальная длина последовательности (например, 16384, 8192)"
    echo "  gpu_memory_utilization - Опционально: использование памяти GPU (например, 0.95)"
    exit 1
fi

NODE_ID="$1"
MODEL_NAME="$2"
MAX_MODEL_LEN="$3"
GPU_MEM_UTIL="${4:-}"

# Проверка наличия jq
if ! command -v jq &> /dev/null; then
    echo "Ошибка: jq не найден. Установите jq для работы скрипта."
    exit 1
fi

echo "Обновление конфигурации ноды через Admin API"
echo "=============================================="
echo "Node ID: $NODE_ID"
echo "Model: $MODEL_NAME"
echo "Max Model Len: $MAX_MODEL_LEN"
if [ -n "$GPU_MEM_UTIL" ]; then
    echo "GPU Memory Utilization: $GPU_MEM_UTIL"
fi
echo "Admin API: $ADMIN_URL"
echo ""

# Проверка доступности Admin API
echo -n "Проверка доступности Admin API... "
if ! curl -s -f "${ADMIN_URL}/admin/v1/nodes" > /dev/null 2>&1; then
    echo "ОШИБКА"
    echo "Admin API недоступен на ${ADMIN_URL}"
    echo "Убедитесь, что контейнер api запущен:"
    echo "  docker compose -f docker-compose.yml -f docker-compose.mlnode.yml ps | grep api"
    exit 1
fi
echo "OK"
echo ""

# Получение текущей конфигурации нод
echo "Получение текущей конфигурации нод..."
NODES_JSON=$(curl -s "${ADMIN_URL}/admin/v1/nodes" 2>/dev/null || echo "[]")

# Проверка, что ответ валидный JSON
if ! echo "$NODES_JSON" | jq empty 2>/dev/null; then
    echo "Ошибка: Не удалось получить валидный JSON от Admin API"
    echo "Ответ:"
    echo "$NODES_JSON"
    exit 1
fi

# Проверка типа ответа
RESPONSE_TYPE=$(echo "$NODES_JSON" | jq -r 'type' 2>/dev/null)
if [ "$RESPONSE_TYPE" != "array" ]; then
    echo "Ошибка: Ожидался массив, получен тип: $RESPONSE_TYPE"
    echo "Ответ:"
    echo "$NODES_JSON" | jq '.'
    exit 1
fi

# Проверка, что массив не пустой
ARRAY_LENGTH=$(echo "$NODES_JSON" | jq 'length' 2>/dev/null)
if [ "$ARRAY_LENGTH" = "0" ]; then
    echo "Ошибка: Массив нод пуст"
    exit 1
fi

# Определяем формат ответа (с node/state или прямой)
FIRST_ITEM=$(echo "$NODES_JSON" | jq '.[0]' 2>/dev/null)
HAS_NODE_FIELD=$(echo "$FIRST_ITEM" | jq -r 'if type == "object" then has("node") | tostring else "false" end' 2>/dev/null)

# Поиск ноды
if [ "$HAS_NODE_FIELD" = "true" ]; then
    # Формат: [{"node": {...}, "state": {...}}]
    NODE_JSON=$(echo "$NODES_JSON" | jq --arg node_id "$NODE_ID" '.[] | select(.node.id == $node_id)' 2>/dev/null)
else
    # Формат: [{...}] - прямой массив нод
    NODE_JSON=$(echo "$NODES_JSON" | jq --arg node_id "$NODE_ID" '.[] | select(.id == $node_id)' 2>/dev/null)
fi

# Проверка, что нода найдена
if [ -z "$NODE_JSON" ] || [ "$NODE_JSON" = "null" ] || [ "$NODE_JSON" = "" ]; then
    echo "Ошибка: Нода '$NODE_ID' не найдена"
    echo ""
    echo "Доступные ноды:"
    if [ "$HAS_NODE_FIELD" = "true" ]; then
        echo "$NODES_JSON" | jq -r '.[].node.id // empty' 2>/dev/null | while read id; do
            [ -n "$id" ] && echo "  - $id"
        done
    else
        echo "$NODES_JSON" | jq -r '.[].id // empty' 2>/dev/null | while read id; do
            [ -n "$id" ] && echo "  - $id"
        done
    fi
    exit 1
fi

echo "✓ Нода найдена"
echo ""

# Извлечение текущей конфигурации
if [ "$HAS_NODE_FIELD" = "true" ]; then
    CURRENT_NODE=$(echo "$NODE_JSON" | jq '.node' 2>/dev/null)
else
    CURRENT_NODE=$(echo "$NODE_JSON" | jq '.' 2>/dev/null)
fi

# Проверка, что CURRENT_NODE - это объект
if ! echo "$CURRENT_NODE" | jq -e 'type == "object"' > /dev/null 2>&1; then
    echo "Ошибка: Не удалось извлечь конфигурацию ноды"
    echo "NODE_JSON:"
    echo "$NODE_JSON" | jq '.'
    exit 1
fi

# Проверка наличия поля models
if ! echo "$CURRENT_NODE" | jq -e 'has("models")' > /dev/null 2>&1; then
    echo "Ошибка: В конфигурации ноды нет поля 'models'"
    echo "CURRENT_NODE:"
    echo "$CURRENT_NODE" | jq '.'
    exit 1
fi

# Проверка наличия модели
MODEL_EXISTS=$(echo "$CURRENT_NODE" | jq -r --arg model "$MODEL_NAME" '
    if .models | type == "object" then
        .models | has($model) | tostring
    else
        "false"
    end
')

if [ "$MODEL_EXISTS" != "true" ]; then
    echo "Ошибка: Модель '$MODEL_NAME' не найдена в ноде '$NODE_ID'"
    echo ""
    echo "Доступные модели:"
    if echo "$CURRENT_NODE" | jq -e '.models | type == "object"' > /dev/null 2>&1; then
        echo "$CURRENT_NODE" | jq -r '.models | keys[]' 2>/dev/null | while read model; do
            [ -n "$model" ] && echo "  - $model"
        done
    else
        echo "  (models не является объектом)"
    fi
    exit 1
fi

echo "✓ Модель найдена"
echo ""

# Получение текущих args модели
CURRENT_ARGS=$(echo "$CURRENT_NODE" | jq -r --arg model "$MODEL_NAME" '
    if .models[$model] | type == "object" and has("args") then
        .models[$model].args // []
    else
        []
    end
')

echo "Текущие args модели:"
if [ -n "$CURRENT_ARGS" ] && [ "$CURRENT_ARGS" != "null" ]; then
    echo "$CURRENT_ARGS" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null | while read arg; do
        [ -n "$arg" ] && echo "  $arg"
    done
    if [ -z "$(echo "$CURRENT_ARGS" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null | head -1)" ]; then
        echo "  (пусто)"
    fi
else
    echo "  (пусто)"
fi
echo ""

# Обновление args: удаляем старые max-model-len и gpu-memory-utilization, добавляем новые
# Убеждаемся, что CURRENT_ARGS - это массив
if ! echo "$CURRENT_ARGS" | jq -e 'type == "array"' > /dev/null 2>&1; then
    CURRENT_ARGS="[]"
fi

UPDATED_ARGS=$(echo "$CURRENT_ARGS" | jq -r --arg max_len "$MAX_MODEL_LEN" --arg gpu_util "$GPU_MEM_UTIL" '
    # Убеждаемся, что это массив
    if type != "array" then [] else . end |
    # Создаем новый массив, пропуская старые параметры и их значения
    . as $args |
    reduce range(length) as $i ([]; 
        $args[$i] as $arg |
        if $i > 0 and ($args[$i-1] == "--max-model-len" or $args[$i-1] == "--gpu-memory-utilization") then
            # Пропускаем значение после параметра
            .
        elif $arg == "--max-model-len" or $arg == "--gpu-memory-utilization" then
            # Пропускаем сам параметр
            .
        else
            # Добавляем остальные аргументы
            . + [$arg]
        end
    ) |
    # Добавляем новые параметры в конец
    . + ["--max-model-len", $max_len] |
    if $gpu_util != "" then
        . + ["--gpu-memory-utilization", $gpu_util]
    else
        .
    end
')

echo "Новые args модели:"
echo "$UPDATED_ARGS" | jq -r '.[]' | while read arg; do
    echo "  $arg"
done
echo ""

# Формирование обновленной конфигурации ноды
UPDATED_NODE=$(echo "$CURRENT_NODE" | jq --arg model "$MODEL_NAME" --argjson args "$UPDATED_ARGS" '
    .models[$model].args = $args |
    {
        id: .id,
        host: .host,
        inference_segment: (if .inference_segment then .inference_segment else "" end),
        inference_port: .inference_port,
        poc_segment: (if .poc_segment then .poc_segment else "" end),
        poc_port: .poc_port,
        max_concurrent: .max_concurrent,
        models: .models,
        hardware: (if .hardware then .hardware else [] end)
    }
')

echo "Отправка обновленной конфигурации..."
echo ""

# Отправка обновления через PUT
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$UPDATED_NODE" \
    "${ADMIN_URL}/admin/v1/nodes/${NODE_ID}" 2>/dev/null || echo -e "\n000")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Конфигурация ноды успешно обновлена!"
    echo ""
    echo "Обновленная конфигурация:"
    if command -v jq &> /dev/null; then
        echo "$BODY" | jq '.'
    else
        echo "$BODY"
    fi
    echo ""
    echo "⚠️  ВАЖНО: После обновления конфигурации нужно перезапустить vLLM:"
    echo ""
    echo "  1. Остановить текущий vLLM (если запущен):"
    echo "     curl -X POST http://localhost:8080/api/v1/inference/down"
    echo ""
    echo "  2. Подождать несколько секунд"
    echo "     sleep 5"
    echo ""
    echo "  3. Запустить vLLM с новой конфигурацией:"
    echo "     ./start_vllm.sh $NODE_ID $MODEL_NAME"
    echo ""
    echo "  Или просто (использует первую ноду из node-config.json):"
    echo "     ./start_vllm.sh"
    echo ""
    echo "  4. Проверить статус:"
    echo "     curl http://localhost:8080/api/v1/inference/up/status | jq '.'"
else
    echo "✗ Ошибка при обновлении конфигурации (HTTP $HTTP_CODE)"
    echo ""
    echo "Ответ сервера:"
    if command -v jq &> /dev/null; then
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
    else
        echo "$BODY"
    fi
    exit 1
fi

