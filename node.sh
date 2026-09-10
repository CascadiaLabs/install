#!/usr/bin/env bash
# node.sh - Cascadia Node installer script
# Usage: sudo bash -c "$(curl -sL https://github.com/CascadiaLabs/install/raw/main/node.sh)" @ install

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. Строгая проверка запуск от root
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен от имени root (или через sudo)."
fi

# Проверка синтаксиса запуска
if [[ ${1:-} != "@" || ${2:-} != "install" ]]; then
    log_error "Usage: sudo bash -c \"\$(curl -sL https://github.com/CascadiaLabs/install/raw/main/node.sh)\" @ install"
fi

# 2. Кроссдистрибутивная установка зависимостей
install_dependencies() {
    log_info "Определение дистрибутива и установка зависимостей..."
    
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-plugin openssl curl git >/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm docker docker-compose openssl curl git >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q docker docker-compose-plugin openssl curl git >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q docker openssl curl git >/dev/null
    elif command -v zypper &>/dev/null; then
        zypper refresh -q
        zypper install -y -q docker openssl curl git >/dev/null
    else
        log_error "Неподдерживаемый пакетный менеджер. Установите docker, git, curl, openssl вручную."
    fi

    # Запуск и автозагрузка Docker службы
    if command -v systemctl &>/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
}

install_dependencies

# 3. Установка в /opt/node
INSTALL_DIR="/opt/node"

# 4. Интерактивная проверка на переустановку (y/n)
if [[ -d "$INSTALL_DIR" ]]; then
    log_warn "Каталог $INSTALL_DIR уже существует."
    read -rp "Установка уже выполнена. Желаете переустановить ноду? [y/N]: " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            log_info "Продолжение переустановки..."
            ;;
        *)
            log_info "Установка отменена пользователем."
            exit 0
            ;;
    esac
fi

mkdir -p "$INSTALL_DIR"

log_info "Клонирование/обновление репозитория в $INSTALL_DIR..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR" && git pull
else
    git clone https://github.com/CascadiaLabs/node.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Сохранение или генерация API токена
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    log_info "Найден существующий .env, токен сохранен."
    TOKEN=$(grep -E '^NODE_API_TOKEN=' "$ENV_FILE" | cut -d '=' -f2)
else
    TOKEN=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
NODE_API_TOKEN=$TOKEN
NODE_API_LISTEN=0.0.0.0:6237
NODE_CONFIG_PATH=/var/lib/node/config.json
EOF
    log_info "Сгенерирован новый API токен и создан .env"
fi

# # Базовый config.json
# CONFIG_FILE="$INSTALL_DIR/config.json"
# if [[ ! -f "$CONFIG_FILE" ]]; then
#     cat > "$CONFIG_FILE" <<'EOF'
# {
#   "log": {
#     "level": "info"
#   },
#   "inbounds": [],
#   "outbounds": [],
#   "route": {
#     "rules": []
#   }
# }
# EOF
#     log_info "Создан базовый config.json"
# fi

# Генерация TLS-сертификатов
CERT_DIR="$INSTALL_DIR/certs"
mkdir -p "$CERT_DIR" "$INSTALL_DIR/data"
if [[ ! -f "$CERT_DIR/cert.pem" || ! -f "$CERT_DIR/key.pem" ]]; then
    log_info "Генерация самоподписанного TLS-сертификата..."
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 365 -nodes -subj "/CN=node/O=CascadiaLabs/C=RU" 2>/dev/null
    chmod 600 "$CERT_DIR/key.pem"
fi

log_info "Сборка Docker-образа..."
docker build -t node .

log_info "Запуск Docker-контейнера..."
docker rm -f node 2>/dev/null || true

docker run -d \
    --name node \
    --restart unless-stopped \
    --network host \
    --env-file "$ENV_FILE" \
    -v "$INSTALL_DIR/.env:/etc/node/.env:ro" \
    -v "$INSTALL_DIR/certs:/etc/node/certs:ro" \
    -v "$INSTALL_DIR/config.json:/var/lib/node/config.json" \
    -v "$INSTALL_DIR/data:/var/lib/node" \
    node

sleep 3

if docker ps --filter "name=^/node$" --filter "status=running" | grep -q node; then
    log_info "Контейнер успешно запущен!"
else
    log_error "Ошибка запуска контейнера. Проверьте логи: docker logs node"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Node успешно запущена!${NC}"
echo -e "${GREEN}API Token: ${TOKEN}${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Используйте этот токен для подключения к панели."
echo "Сертификат: $CERT_DIR/cert.pem"
echo "Приватный ключ: $CERT_DIR/key.pem"