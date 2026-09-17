#!/usr/bin/env bash
# panel.sh - Cascadia Panel installer script
# Usage: sudo bash -c "$(curl -sL https://github.com/CascadiaLabs/install/raw/main/panel.sh)" @ install

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. Строгая проверка запуска от root
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен от имени root (или через sudo)."
fi

# Проверка синтаксиса запуска
# bash -c '...' @ install: @ находится в $0, install — в $1.
# Прямой запуск bash panel.sh @ install также поддерживается.
if [[ ! ( "$0" == "@" && "${1:-}" == "install" ) && ! ( "${1:-}" == "@" && "${2:-}" == "install" ) ]]; then
    log_error "Usage: sudo bash -c \"\$(curl -sL https://github.com/CascadiaLabs/install/raw/main/panel.sh)\" @ install"
fi

# 2. Кроссдистрибутивная установка зависимостей
install_dependencies() {
    log_info "Определение дистрибутива и установка зависимостей..."

    # Уже установленные зависимости не трогаем: повторная установка docker.io
    # на сервере с docker-ce/podman роняет apt (pkgProblemResolver: generated breaks).
    local missing=()
    for c in docker curl openssl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "docker, curl, openssl уже установлены — пропускаем установку."
        return
    fi
    log_info "Устанавливаю недостающее: ${missing[*]}"

    if command -v apt-get &>/dev/null; then
        local apkgs=()
        for c in "${missing[@]}"; do
            [[ $c == docker ]] && c=docker.io
            apkgs+=("$c")
        done
        apt-get update -qq
        apt-get install -y -qq "${apkgs[@]}" >/dev/null \
            || log_error "apt не может установить ${apkgs[*]}. Проверьте: apt-get -f install, apt-mark showhold."
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "${missing[@]}" >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "${missing[@]}" >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q "${missing[@]}" >/dev/null
    elif command -v zypper &>/dev/null; then
        zypper refresh -q
        zypper install -y -q "${missing[@]}" >/dev/null
    else
        log_error "Неподдерживаемый пакетный менеджер. Установите docker, curl, openssl вручную."
    fi

    # Запуск и автозагрузка Docker службы
    if command -v systemctl &>/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
}

install_dependencies

# CLI-утилита casc (управление панелью/нодой после установки).
install_casc() {
    log_info "Установка утилиты casc в /usr/local/bin/casc..."
    if curl -fsSL "https://raw.githubusercontent.com/CascadiaLabs/install/main/casc" -o /usr/local/bin/casc; then
        chmod +x /usr/local/bin/casc
        log_info "casc установлена: sudo casc status / sudo casc password reset"
    else
        log_warn "Не удалось загрузить casc. Установите вручную: sudo curl -fsSL https://raw.githubusercontent.com/CascadiaLabs/install/main/casc -o /usr/local/bin/casc && sudo chmod +x /usr/local/bin/casc"
    fi
}
install_casc

# Установка certbot (только когда пользователь выберет домен и SSL).
install_certbot() {
    if command -v certbot &>/dev/null; then
        return
    fi
    log_info "Установка certbot (Let's Encrypt)..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq certbot >/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm certbot >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q certbot >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q certbot >/dev/null
    elif command -v zypper &>/dev/null; then
        zypper refresh -q >/dev/null
        zypper install -y -q certbot >/dev/null
    else
        log_error "Не удалось установить certbot. Установите его вручную: https://certbot.eff.org/instructions"
    fi
}

# Запуск контейнера. PANEL_TLS_OPTS добавляет ssl-флаги и объем при
# включённом домене.
start_panel() {
    docker rm -f panel 2>/dev/null || true
    docker run -d \
        --pull always \
        --name panel \
        --restart unless-stopped \
        -p 2083:2083 \
        --env-file "$ENV_FILE" \
        -v "$INSTALL_DIR/data:/var/lib/panel" \
        ${PANEL_TLS_OPTS:-} \
        "$PANEL_IMAGE"

    sleep 3

    if docker ps --filter "name=^/panel$" --filter "status=running" | grep -q panel; then
        log_info "Контейнер panel запущен."
    else
        log_error "Ошибка запуска контейнера. Проверьте логи: docker logs panel"
    fi
}

# 3. Установка в /opt/panel
INSTALL_DIR="/opt/panel"
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/cascadialabs/panel:latest}"

# 4. Интерактивная проверка на переустановку (y/n)
if [[ -d "$INSTALL_DIR" ]]; then
    log_warn "Каталог $INSTALL_DIR уже существует."
    read -rp "Установка уже выполнена. Желаете переустановить панель? [y/N]: " confirm
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

# Секреты доступны только root.
umask 077
# Сохранение или генерация API-токена (machine-to-machine, для скриптов).
# Логин в веб-интерфейсе — по паролю (admin), задаётся PANEL_ADMIN_PASSWORD
# или генерируется при первом старте (смотрите логи контейнера).
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    log_info "Найден существующий .env, токен сохранен."
    TOKEN=$(grep -E '^PANEL_TOKEN=' "$ENV_FILE" | cut -d '=' -f2- || true)
    [[ -n "$TOKEN" ]] || log_error "В $ENV_FILE отсутствует PANEL_TOKEN; укажите непустой токен."
else
    TOKEN=$(openssl rand -hex 32)
    if [[ -n "${PANEL_ADMIN_PASSWORD:-}" ]]; then
        ADMIN_PASSWORD_LINE="PANEL_ADMIN_PASSWORD=${PANEL_ADMIN_PASSWORD}"
    fi
    cat > "$ENV_FILE" <<EOF
PANEL_TOKEN=$TOKEN
${ADMIN_PASSWORD_LINE:-}
DB_PATH=/var/lib/panel/panel.db
LISTEN_ADDR=0.0.0.0:2083
EOF
    log_info "Сгенерирован новый API-токен и создан .env"
fi

chmod 600 "$ENV_FILE"

log_info "Загрузка Docker-образа $PANEL_IMAGE..."
docker pull "$PANEL_IMAGE"

# Панель запускается только после выбора TLS. Иначе первый старт создаёт admin
# и печатает одноразовый пароль, а перезапуск после настройки SSL очищает
# доступный через `docker logs` вывод контейнера.
PANEL_TLS_OPTS=""

echo ""
log_info "Опционально: домен и SSL-сертификат (Let's Encrypt) для защищённого HTTPS-доступа к панели."
log_info "Панель продолжит работать без домена — выберите N, чтобы пропустить."
read -rp "Хотите настроить домен и SSL сейчас? [y/N]: " tls_confirm
if [[ "$tls_confirm" =~ ^[yY]([eE][sS])?$ ]]; then
    install_certbot
    read -rp "Домен (A-запись уже должна указывать на IP этого сервера): " PANEL_DOMAIN
    [[ -n "${PANEL_DOMAIN:-}" ]] || log_error "Домен не задан."
    read -rp "E-mail для уведомлений Let's Encrypt (Enter — пропустить): " LE_EMAIL

    log_info "Выпуск сертификата для $PANEL_DOMAIN (certbot временно займёт порт 80)..."
    certbot_args=(certonly --standalone --non-interactive --agree-tos -d "$PANEL_DOMAIN")
    if [[ -n "${LE_EMAIL:-}" ]]; then
        certbot_args+=(--email "$LE_EMAIL")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi
    certbot "${certbot_args[@]}"

    cat >> "$ENV_FILE" <<EOF
PANEL_TLS_CERT=/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem
PANEL_TLS_KEY=/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem
EOF
    chmod 600 "$ENV_FILE"
    PANEL_TLS_OPTS="-v /etc/letsencrypt:/etc/letsencrypt:ro"

    # Авто-продление: сертификаты живут ~90 дней. Под systemd — таймер,
    # иначе crontab. После продления контейнер перезапускается, чтобы панель
    # перечитала новый сертификат.
    log_info "Настройка авто-продления сертификата..."
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/cascadia-panel-renew.service <<EOF
[Unit]
Description=Renew Cascadia panel Let's Encrypt certificate
After=network-online.target
[Service]
Type=oneshot
ExecStart=certbot renew -q --deploy-hook "docker restart panel"
EOF
        cat > /etc/systemd/system/cascadia-panel-renew.timer <<EOF
[Unit]
Description=Twice-daily certbot renewal for the Cascadia panel
[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload >/dev/null
        systemctl enable --now cascadia-panel-renew.timer >/dev/null 2>&1 || true
    else
        ( crontab -l 2>/dev/null | grep -v 'cascadia-panel-renew'; \
          echo '0 3 * * * certbot renew -q --deploy-hook "docker restart panel"' ) | crontab -
    fi
    PANEL_TLS="on"
else
    PANEL_TLS="off"
fi

# Единственный первый запуск: при пустой БД здесь будет создан admin и его
# пароль останется в логах, независимо от того, был ли выбран SSL.
start_panel

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Панель успешно запущена!${NC}"
if [[ "$PANEL_TLS" == "on" ]]; then
    echo -e "${GREEN}URL: https://${PANEL_DOMAIN}:2083${NC}"
else
    echo -e "${GREEN}URL: http://<IP-этой-машины>:2083${NC}"
fi
echo -e "${GREEN}Логин: admin${NC}"
echo -e "${GREEN}Пароль: docker logs panel 2>&1 | grep -i 'FIRST LOGIN'${NC}"
echo -e "${GREEN}API-токен (для скриптов): ${TOKEN}${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Веб-интерфейс: войдите как admin и сразу смените пароль (Login → Смена пароля)."
echo "PANEL_ADMIN_PASSWORD в .env задаёт пароль только при ПЕРВОМ старте (пустая БД)."
