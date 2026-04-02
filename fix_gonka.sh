#!/bin/bash

set -e

MODE=$1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_DIR="/mnt/ssd/gonka/deploy/join"
APP_CONFIG="$BASE_DIR/.inference/config/app.toml"
CONFIG_TOML="$BASE_DIR/.inference/config/config.toml"
DOCKER_COMPOSE="$BASE_DIR/docker-compose.yml"
MLNODE_COMPOSE="$BASE_DIR/docker-compose.mlnode.yml"
PEER_SCRIPT="$SCRIPT_DIR/peer_speed_test.py"

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

status_ok() {
  echo -e "${GREEN}✔ $1${NC}"
}

status_fail() {
  echo -e "${RED}✘ $1${NC}"
}

ask_fix() {
  if [ "$MODE" == "fix" ]; then
    read -p "Исправить? (y/n): " choice
    [[ "$choice" == "y" ]]
  else
    return 1
  fi
}

echo "=== MODE: $MODE ==="

# -------------------------
# PRUNING
# -------------------------
echo "== PRUNING =="

grep -q 'pruning = "custom"' $APP_CONFIG &&
grep -q 'pruning-keep-recent = "20000"' $APP_CONFIG &&
grep -q 'pruning-interval = "512"' $APP_CONFIG

if [ $? -eq 0 ]; then
  status_ok "Pruning настроен"
else
  status_fail "Pruning НЕ настроен"
  if ask_fix; then
    sed -i 's/^pruning *= *.*/pruning = "custom"/' $APP_CONFIG
    sed -i 's/^pruning-keep-recent *= *.*/pruning-keep-recent = "20000"/' $APP_CONFIG
    sed -i 's/^pruning-interval *= *.*/pruning-interval = "512"/' $APP_CONFIG
    status_ok "Исправлено"
  fi
fi

# -------------------------
# SNAPSHOT
# -------------------------
echo "== SNAPSHOT =="

grep -q "SNAPSHOT_INTERVAL=1000" $DOCKER_COMPOSE &&
grep -q "SNAPSHOT_KEEP_RECENT=2" $DOCKER_COMPOSE

if [ $? -eq 0 ]; then
  status_ok "Snapshot OK"
else
  status_fail "Snapshot НЕ настроен"
  if ask_fix; then
    sed -i '/environment:/a\      - SNAPSHOT_INTERVAL=1000' $DOCKER_COMPOSE
    sed -i '/environment:/a\      - SNAPSHOT_KEEP_RECENT=2' $DOCKER_COMPOSE
    status_ok "Исправлено"
  fi
fi

# -------------------------
# BACKUP
# -------------------------
echo "== BACKUP =="

grep -q "UNSAFE_SKIP_BACKUP=true" $DOCKER_COMPOSE

if [ $? -eq 0 ]; then
  status_ok "Backup отключен"
else
  status_fail "Backup ВКЛЮЧЕН"
  if ask_fix; then
    sed -i '/environment:/a\      - UNSAFE_SKIP_BACKUP=true' $DOCKER_COMPOSE
    status_ok "Исправлено"
  fi
fi

# -------------------------
# HF OFFLINE
# -------------------------
echo "== HF OFFLINE =="

grep -q "HF_HUB_OFFLINE=true" $MLNODE_COMPOSE

if [ $? -eq 0 ]; then
  status_ok "HF offline включен"
else
  status_fail "HF offline ВЫКЛЮЧЕН"
  if ask_fix; then
    sed -i '/environment:/a\      - HF_HUB_OFFLINE=true' $MLNODE_COMPOSE
    status_ok "Исправлено"
  fi
fi

# -------------------------
# ULIMIT
# -------------------------
echo "== ULIMIT =="

ULIMIT=$(sudo docker exec node sh -c "ulimit -n")

if [ "$ULIMIT" == "65535" ]; then
  status_ok "ulimit = 65535"
else
  status_fail "ulimit = $ULIMIT (ожидается 65535)"
fi

# -------------------------
# PEERS
# -------------------------
echo "== PEERS =="

if [ ! -f "$PEER_SCRIPT" ]; then
  status_fail "peer script не найден"
else
  PEERS=$(python3 "$PEER_SCRIPT" node1.gonka.ai | grep -Eo '[a-z0-9@.:]+' | paste -sd "," -)

  if [ -z "$PEERS" ]; then
    status_fail "не удалось получить peers"
  else
    CURRENT=$(grep "^persistent_peers" $CONFIG_TOML)

    if [[ "$CURRENT" == *"$PEERS"* ]]; then
      status_ok "Peers актуальны"
    else
      status_fail "Peers устарели"
      if ask_fix; then
        sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" $CONFIG_TOML
        status_ok "Обновлено"
      fi
    fi
  fi
fi

# -------------------------
# RESTART
# -------------------------
if [ "$MODE" == "fix" ]; then
  echo "== RESTART DOCKER =="

  read -p "Перезапустить контейнеры? (y/n): " restart
  if [[ "$restart" == "y" ]]; then
    cd $BASE_DIR
    sudo docker-compose down
    sudo docker-compose up -d
    status_ok "Контейнеры перезапущены"
  fi
fi

echo "=== DONE ==="
