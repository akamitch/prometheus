#!/bin/bash

# Скрипт для проверки, откуда берутся параметры модели
# Показывает конфигурацию из разных источников

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
NODE_CONFIG=${NODE_CONFIG:-./node-config.json}

echo "Проверка конфигурации ноды"
echo "=========================="
echo ""

# Проверка наличия jq
if ! command -v jq &> /dev/null; then
    echo "Ошибка: jq не найден. Установите jq для работы скрипта."
    exit 1
fi

# 1. Проверка node-config.json
echo "1. Конфигурация из node-config.json:"
if [ -f "$NODE_CONFIG" ]; then
    echo "$(cat "$NODE_CONFIG" | jq '.')"
else
    echo "  Файл не найден: $NODE_CONFIG"
fi
echo ""

# 2. Проверка Admin API
echo "2. Конфигурация из Admin API (localhost:${ADMIN_PORT}):"
if curl -s -f "${ADMIN_URL}/admin/v1/nodes" > /dev/null 2>&1; then
    NODES_JSON=$(curl -s "${ADMIN_URL}/admin/v1/nodes" 2>/dev/null || echo "[]")
    if echo "$NODES_JSON" | jq empty 2>/dev/null; then
        echo "$NODES_JSON" | jq '.'
    else
        echo "  Ошибка: Не удалось получить валидный JSON"
        echo "$NODES_JSON"
    fi
else
    echo "  Admin API недоступен"
fi
echo ""

# 3. Проверка SQLite БД (если доступна)
echo "3. Конфигурация из SQLite БД:"
# Проверяем несколько возможных путей
SQLITE_PATHS=(
    "./.dapi/gonka.db"
    "./gonka.db"
    "${API_SQLITE_PATH:-}"
)

SQLITE_FOUND=false
for SQLITE_PATH in "${SQLITE_PATHS[@]}"; do
    if [ -n "$SQLITE_PATH" ] && [ -f "$SQLITE_PATH" ]; then
        echo "  ✓ БД найдена: $SQLITE_PATH"
        SQLITE_FOUND=true
        
        # Проверяем наличие sqlite3
        if command -v sqlite3 &> /dev/null; then
            echo ""
            echo "  Содержимое таблицы inference_nodes:"
            sqlite3 "$SQLITE_PATH" "SELECT id, models_json FROM inference_nodes;" 2>/dev/null | while IFS='|' read -r id models_json; do
                echo "  Node ID: $id"
                echo "$models_json" | jq '.' 2>/dev/null || echo "    $models_json"
            done
        else
            echo "  sqlite3 не найден. Установите для просмотра содержимого."
            echo "  Или используйте:"
            echo "    docker exec api sqlite3 /root/.dapi/gonka.db 'SELECT id, models_json FROM inference_nodes;' | jq '.'"
        fi
        break
    fi
done

if [ "$SQLITE_FOUND" = false ]; then
    echo "  БД не найдена в стандартных местах."
    echo "  Проверьте:"
    echo "    - ./.dapi/gonka.db"
    echo "    - ./gonka.db"
    echo "    - Или переменную окружения API_SQLITE_PATH"
    echo ""
    echo "  Или проверьте внутри контейнера api:"
    echo "    docker exec api ls -la /root/.dapi/"
    echo "    docker exec api sqlite3 /root/.dapi/gonka.db 'SELECT id, models_json FROM inference_nodes;' | jq '.'"
fi
echo ""

# 4. Информация о том, откуда берутся параметры при запуске vLLM
echo "4. Откуда берутся параметры при запуске vLLM:"
echo ""
echo "  При автоматическом запуске через API (InferenceUpNodeCommand):"
echo "    - epochModel.ModelArgs (из blockchain governance) - ПРИОРИТЕТ!"
echo "    - localArgs (из Admin API / SQLite БД)"
echo "    - Объединяются через MergeModelArgs (epochArgs имеют приоритет)"
echo ""
echo "  При ручном запуске через start_vllm.sh:"
echo "    - Читает из node-config.json"
echo "    - Отправляет напрямую в MLNode API"
echo "    - НЕ использует MergeModelArgs"
echo ""
echo "  ⚠️  ПРОБЛЕМА: Если в blockchain governance установлен --max-model-len 40960,"
echo "     то локальные args из Admin API НЕ смогут его перезаписать!"
echo ""
echo "  Решение: Нужно проверить, что находится в epochModel.ModelArgs"
echo "           (это значение из blockchain governance для модели)"
echo ""

# 5. Анализ текущей ситуации
echo "5. Анализ текущей ситуации:"
echo ""

# Проверяем, есть ли данные из Admin API
if [ -n "$NODES_JSON" ] && echo "$NODES_JSON" | jq empty 2>/dev/null; then
    # Проверка пустых args
    if echo "$NODES_JSON" | jq -e '.[0].node.models."Qwen/Qwen3-32B-FP8".args | length == 0' > /dev/null 2>&1; then
        echo "  ⚠️  ПРОБЛЕМА ОБНАРУЖЕНА:"
        echo "     В Admin API args пустые: []"
        echo ""
        echo "  Это означает, что:"
        echo "    1. Обновление через update_node_max_model_len.sh не сохранило args"
        echo "    2. Или args были пустыми при обновлении"
        echo ""
        echo "  Проверьте SQLite БД (см. раздел 3 выше)"
        echo "  Если в БД тоже пусто, значит обновление не применилось."
        echo ""
        echo "  Решение:"
        echo "    1. Убедитесь, что скрипт update_node_max_model_len.sh выполнился успешно"
        echo "    2. Проверьте логи контейнера api на ошибки"
        echo "    3. Попробуйте обновить еще раз:"
        echo "       ./update_node_max_model_len.sh node14 Qwen/Qwen3-32B-FP8 16384 0.95"
        echo ""
    fi
    
    # Проверка epoch_models на наличие ModelArgs
    EPOCH_MODEL_ARGS=$(echo "$NODES_JSON" | jq -r '.[0].state.epoch_models."Qwen/Qwen3-32B-FP8".model_args // empty' 2>/dev/null || echo "")
    if [ -n "$EPOCH_MODEL_ARGS" ] && [ "$EPOCH_MODEL_ARGS" != "null" ]; then
        echo "  ⚠️  ВНИМАНИЕ: В epoch_models есть ModelArgs из governance:"
        echo "     $EPOCH_MODEL_ARGS"
        echo ""
        echo "  Эти args имеют ПРИОРИТЕТ над локальными args!"
    else
        echo "  ✓ В epoch_models нет ModelArgs (или они пустые)"
        echo "    Значит используется дефолтное значение max_model_len из конфига модели (40960)"
    fi
fi

