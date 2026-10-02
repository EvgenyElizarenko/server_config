#!/usr/bin/env bash
# =============================================================================
# Мастер настройки сервера (Ubuntu 24.04 / Debian 12)
#   1) Настройка сервера
#   2) Установка прокси (autoXRAY)
#   3) Активация root
#   4) Деактивация root
#   5) Пересборка OpenSSL (nginx + OpenSSL 3.5)
#   6) Тесты (IP region, IPQuality, Censorcheck, iPerf3, Speedtest, YABS, bench.sh)
# Запуск: sudo bash server-setup.sh   (или от root)
# =============================================================================
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
INSTALL_DIR="/usr/local/share/server-setup"
INSTALLED_SCRIPT="$INSTALL_DIR/setup.sh"
SSHD_CONFIG="/etc/ssh/sshd_config"
CLOUD_INIT_CONFIG="/etc/ssh/sshd_config.d/50-cloud-init.conf"
UFW_BEFORE="/etc/ufw/before.rules"
MARK_BEGIN="# >>> server-setup autorun >>>"
MARK_END="# <<< server-setup autorun <<<"

# ---------- root-права ----------
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$SCRIPT_PATH" "$@"
    fi
    echo "Запустите скрипт от root (sudo не найден)." >&2
    exit 1
fi

# ---------- вспомогательные функции ----------
info() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }

backup() { cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }

# ---------- прерывание работы ----------
# Ctrl+C / kill -> корректный выход; на любом вопросе "q" (или Ctrl+D) отменяет текущий шаг
TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}" 2>/dev/null; return 0; }
on_interrupt() {
    echo
    warn "Прервано пользователем. Уже выполненные шаги не откатываются."
    exit 130
}
trap on_interrupt INT TERM
trap cleanup EXIT

cancelled() { warn "Отменено пользователем. Уже выполненные шаги не откатываются."; }

# ask <переменная> <приглашение>: возвращает 1, если введено q/Q или конец ввода (Ctrl+D)
ask() {
    local __v
    read -rp "$2" __v || { echo; return 1; }
    [[ $__v == [qQ] ]] && return 1
    printf -v "$1" '%s' "$__v"
}

# set_opt <файл> <ключ> <значение>: заменяет (в т.ч. закомментированную) строку
# или добавляет ключ в начало файла, если его нет вообще
set_opt() {
    local file=$1 key=$2 value=$3
    if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "$file"
    else
        sed -i "1i ${key} ${value}" "$file"
    fi
}

restart_ssh() {
    mkdir -p /run/sshd
    if ! sshd -t; then
        err "sshd -t обнаружил ошибку в конфигурации, ssh НЕ перезапущен."
        return 1
    fi
    # Ubuntu 24.04: сокет-активация игнорирует Port из sshd_config -> отключаем ssh.socket
    if systemctl cat ssh.socket >/dev/null 2>&1 && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf
        systemctl enable ssh.service >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload && systemctl restart ssh
}

show_effective_ssh() {
    echo "Действующие параметры sshd:"
    sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) ' || true
}

# ---------- пункты 3 и 4: root ----------
set_root_access() {   # yes | no
    local val=$1
    (
        set -euo pipefail
        backup "$SSHD_CONFIG"
        set_opt "$SSHD_CONFIG" PermitRootLogin "$val"
        set_opt "$SSHD_CONFIG" PasswordAuthentication "$val"

        if [[ -f $CLOUD_INIT_CONFIG ]]; then
            backup "$CLOUD_INIT_CONFIG"
            set_opt "$CLOUD_INIT_CONFIG" PasswordAuthentication "$val"
            echo "Проверка $CLOUD_INIT_CONFIG:"
            grep -E '^PasswordAuthentication' "$CLOUD_INIT_CONFIG" || true
        else
            echo "Файл $CLOUD_INIT_CONFIG не найден, пропускаю."
        fi

        echo "Проверка итоговых строк в $SSHD_CONFIG:"
        grep -E '^(PermitRootLogin|PasswordAuthentication)' "$SSHD_CONFIG"

        restart_ssh
        show_effective_ssh
    ) || { err "Не удалось применить изменения."; return 1; }

    if [[ $val == yes ]]; then
        echo "Готово: root-логин и парольная аутентификация включены."
    else
        echo "Готово: root-логин и парольная аутентификация отключены."
    fi
}

# ---------- пункт 2: прокси ----------
install_proxy() {
    command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl || return 1; }
    local domain
    while true; do
        ask domain "Введите ваш домен (например example.com; q — отмена): " || { cancelled; return 1; }
        if [[ $domain =~ ^[A-Za-z0-9._-]+\.[A-Za-z0-9-]+$ ]]; then break; fi
        warn "Некорректный домен, попробуйте ещё раз."
    done
    bash -c "$(curl -L https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAY2.sh)" -- "$domain"
}

# ---------- пункт 1: настройка сервера ----------
server_setup() {
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}-${VERSION_ID:-}" in
        ubuntu-24.04|ubuntu-26.04|debian-12) ;;
        *)
            warn "Скрипт рассчитан на Ubuntu 24.04 / 26.04 и Debian 12, у вас: ${PRETTY_NAME:-unknown}"
            ask a "Продолжить всё равно? [y/N] " || { cancelled; return 0; }
            [[ $a =~ ^[Yy]$ ]] || return 0
            ;;
    esac

    # 1. Обновление
    info "1/13 Обновление системы"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt update && apt full-upgrade -y -o Dpkg::Options::="--force-confold" && apt autoremove -y \
        || { err "Ошибка обновления."; return 1; }

    # 2. Пакеты
    info "2/13 Проверка пакетов sudo, curl, ufw"
    local missing=() p
    for p in sudo curl ufw; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    [[ -f $SSHD_CONFIG ]] || missing+=(openssh-server)
    if ((${#missing[@]})); then
        echo "Устанавливаю: ${missing[*]}"
        apt install -y "${missing[@]}" || { err "Не удалось установить пакеты."; return 1; }
    else
        echo "Все нужные пакеты уже установлены."
    fi

    # 3. Пароль root
    info "3/13 Смена пароля root"
    until passwd root; do warn "Пароль не изменён, повторите."; done

    # 4. Новый пользователь
    info "4/13 Создание нового пользователя"
    local NEW_USER
    while true; do
        ask NEW_USER "Имя нового пользователя (q — отмена): " || { cancelled; return 1; }
        if [[ $NEW_USER == root ]]; then warn "Нужен пользователь, отличный от root."; continue; fi
        if [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        warn "Допустимы строчные латинские буквы, цифры, '_' и '-' (не начинается с цифры)."
    done
    if id "$NEW_USER" >/dev/null 2>&1; then
        warn "Пользователь $NEW_USER уже существует, использую его."
    else
        adduser --gecos "" "$NEW_USER" || { err "Не удалось создать пользователя."; return 1; }
    fi

    # 5. Группа sudo
    info "5/13 Добавление $NEW_USER в группу sudo"
    usermod -aG sudo "$NEW_USER"

    # 6. Папка .ssh
    info "6/13 Создание ~/.ssh"
    local USER_HOME USER_GROUP
    USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
    USER_GROUP=$(id -gn "$NEW_USER")
    install -d -m 700 -o "$NEW_USER" -g "$USER_GROUP" "$USER_HOME/.ssh"

    # 7. authorized_keys
    info "7/13 Ключ SSH"
    local SSH_KEY tmp
    while true; do
        ask SSH_KEY "Вставьте публичный SSH-ключ одной строкой (q — отмена): " || { cancelled; return 1; }
        tmp=$(mktemp)
        TMP_FILES+=("$tmp")
        printf '%s\n' "$SSH_KEY" > "$tmp"
        if [[ -n $SSH_KEY ]] && ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"; break
        fi
        rm -f "$tmp"
        warn "Это не похоже на корректный публичный ключ, попробуйте ещё раз."
    done
    local AK="$USER_HOME/.ssh/authorized_keys"
    touch "$AK"
    grep -qxF "$SSH_KEY" "$AK" || printf '%s\n' "$SSH_KEY" >> "$AK"
    chown "$NEW_USER:$USER_GROUP" "$AK"
    chmod 600 "$AK"

    # 8. sshd_config
    info "8/13 Настройка $SSHD_CONFIG"
    local SSH_PORT
    while true; do
        ask SSH_PORT "Новый порт SSH [22] (q — отмена): " || { cancelled; return 1; }
        SSH_PORT=${SSH_PORT:-22}
        if [[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)); then break; fi
        warn "Порт должен быть числом от 1 до 65535."
    done
    backup "$SSHD_CONFIG"
    set_opt "$SSHD_CONFIG" Port "$SSH_PORT"
    set_opt "$SSHD_CONFIG" PasswordAuthentication no
    set_opt "$SSHD_CONFIG" PermitRootLogin no
    set_opt "$SSHD_CONFIG" PubkeyAuthentication yes

    # 9. cloud-init
    info "9/13 $CLOUD_INIT_CONFIG"
    if [[ -f $CLOUD_INIT_CONFIG ]]; then
        backup "$CLOUD_INIT_CONFIG"
        set_opt "$CLOUD_INIT_CONFIG" PasswordAuthentication no
        echo "Готово."
    else
        echo "Файл не найден, пропускаю."
    fi

    # 10. Перезапуск ssh
    info "10/13 Перезапуск ssh"
    restart_ssh || return 1
    show_effective_ssh

    # 11. before.rules (ICMP)
    info "11/13 Правка $UFW_BEFORE"
    [[ -f $UFW_BEFORE ]] || { err "$UFW_BEFORE не найден."; return 1; }
    backup "$UFW_BEFORE"
    sed -i -E '/^-A ufw-before-(input|forward) -p icmp --icmp-type /s/-j ACCEPT/-j DROP/' "$UFW_BEFORE"
    if ! grep -q -- '^-A ufw-before-input -p icmp --icmp-type source-quench' "$UFW_BEFORE"; then
        sed -i '/^-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$UFW_BEFORE"
    fi
    grep -E '^-A ufw-before-(input|forward) -p icmp' "$UFW_BEFORE"

    # 12. UFW
    info "12/13 Настройка UFW"
    local PORTS_RAW PORT_LIST=() item
    ask PORTS_RAW "Какие порты открыть? (через пробел/запятую, напр.: 80 443 51820/udp; Enter — только SSH; q — отмена): " || { cancelled; return 1; }
    PORTS_RAW=${PORTS_RAW//,/ }
    for item in $PORTS_RAW; do
        if [[ $item =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] && (( ${item%%/*} >= 1 && ${item%%/*} <= 65535 )); then
            PORT_LIST+=("$item")
        else
            warn "Пропускаю некорректное значение: $item"
        fi
    done
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    for item in "${PORT_LIST[@]}"; do ufw allow "$item"; done
    ufw --force enable
    ufw reload
    ufw status verbose

    # 13. Перезагрузка + автозапуск под новым пользователем
    info "13/13 Подготовка к перезагрузке"
    install -d -m 755 "$INSTALL_DIR"
    [[ $SCRIPT_PATH == "$INSTALLED_SCRIPT" ]] || install -m 755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT"

    touch "$USER_HOME/.profile"
    sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$USER_HOME/.profile"
    cat >> "$USER_HOME/.profile" <<EOF
$MARK_BEGIN
if [ -f "\$HOME/.server-setup-once" ] && [ -t 0 ]; then
    rm -f "\$HOME/.server-setup-once"
    sudo bash "$INSTALLED_SCRIPT" --after-reboot
fi
$MARK_END
EOF
    touch "$USER_HOME/.server-setup-once"
    chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.profile" "$USER_HOME/.server-setup-once"

    echo
    echo "==============================================================="
    echo " Настройка завершена. После перезагрузки подключайтесь так:"
    echo "   ssh -p $SSH_PORT $NEW_USER@<IP-сервера>"
    echo " При первом входе скрипт запустится ещё раз (через sudo)."
    echo "==============================================================="
    local _x
    ask _x "Нажмите Enter для перезагрузки (q — отмена): " || {
        warn "Перезагрузка отменена. Выполните её вручную: reboot (автозапуск скрипта сработает при следующем входе $NEW_USER)."
        return 0
    }
    reboot
}

# ---------- пункт 5: пересборка nginx с OpenSSL 3.5 ----------
rebuild_openssl() {
    local tmp ver a
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.* ]]; then
        warn "В Ubuntu 26.04 системный OpenSSL уже 3.5.x: $(openssl version 2>/dev/null)"
        warn "Пересборка из ванильных исходников nginx.org уберёт патчи безопасности Ubuntu, а версия 3.5.2 по умолчанию старше системной."
        ask a "Всё равно продолжить? [y/N] " || { cancelled; return 0; }
        [[ $a =~ ^[Yy]$ ]] || return 0
    fi
    tmp=$(mktemp /tmp/rebuild_nginx_openssl35.XXXXXX) || return 1
    TMP_FILES+=("$tmp")
    cat > "$tmp" <<'REBUILD_OPENSSL_EOF'
#!/usr/bin/env bash
#
# rebuild_nginx_openssl35.sh
#
# Собирает OpenSSL 3.5 из исходников и пересобирает уже установленный nginx
# так, чтобы он был статически слинкован с этой версией OpenSSL.
#
# Системный OpenSSL (используемый apt/ssh/curl и т.д.) НЕ трогается и не
# заменяется — это гарантирует, что скрипт не сломает остальную систему.
# OpenSSL 3.5 собирается в отдельную директорию и используется только
# при сборке nginx (--with-openssl=<src>).
#
# Проверено на Ubuntu 24.04.
#
# Использование:
#   sudo ./rebuild_nginx_openssl35.sh
#
# Переменные окружения (опционально):
#   OPENSSL_VERSION   - версия OpenSSL (по умолчанию последняя 3.5.x)
#   NGINX_MODULES     - дополнительные --add-module=... через пробел
#   DRY_RUN=1         - только показать план действий, ничего не собирать/не ставить
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Настройки
# ---------------------------------------------------------------------------
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.2}"
BUILD_DIR="/usr/local/src/nginx-openssl-build"
OPENSSL_SRC_DIR="${BUILD_DIR}/openssl-${OPENSSL_VERSION}"
NGINX_SRC_DIR=""
DRY_RUN="${DRY_RUN:-0}"
NGINX_MODULES="${NGINX_MODULES:-}"

LOG_FILE="/var/log/rebuild_nginx_openssl35.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ОШИБКА: $*"
    exit 1
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "(dry-run) $*"
    else
        eval "$@"
    fi
}

# ---------------------------------------------------------------------------
# Проверки перед стартом
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "Скрипт нужно запускать от root (sudo)."
fi

if ! command -v nginx >/dev/null 2>&1; then
    die "nginx не найден в PATH. Скрипт предназначен для пересборки уже установленного nginx."
fi

touch "$LOG_FILE" 2>/dev/null || die "Нет доступа для записи в $LOG_FILE"

log "=== Старт: установка OpenSSL ${OPENSSL_VERSION} и пересборка nginx ==="

# ---------------------------------------------------------------------------
# 1. Получаем текущую конфигурацию nginx (configure arguments, версия)
# ---------------------------------------------------------------------------
CURRENT_NGINX_VERSION="$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')"
[[ -n "$CURRENT_NGINX_VERSION" ]] || die "Не удалось определить версию установленного nginx"

CONFIGURE_ARGS_RAW="$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/configure arguments: //')"
log "Обнаружен nginx версии: ${CURRENT_NGINX_VERSION}"
log "Текущие configure arguments: ${CONFIGURE_ARGS_RAW}"

# Убираем из старых configure-аргументов любые упоминания --with-openssl,
# --with-openssl-opt и --with-debug (добавим свои/актуальные значения сами)
CONFIGURE_ARGS_CLEAN="$(echo "$CONFIGURE_ARGS_RAW" \
    | sed -E 's/--with-openssl=[^ ]+//g' \
    | sed -E 's/--with-openssl-opt=[^ ]+//g')"

NGINX_BIN_PATH="$(command -v nginx)"

# ---------------------------------------------------------------------------
# 2. Устанавливаем зависимости для сборки
# ---------------------------------------------------------------------------
log "Устанавливаем пакеты, необходимые для сборки..."

if [[ "$DRY_RUN" == "1" ]]; then
    echo "(dry-run) apt-get update -y"
else
    # apt-get update возвращает ненулевой код, если хотя бы один репозиторий
    # (в т.ч. сторонний, добавленный вручную и не относящийся к сборке)
    # недоступен или битый (например, отсутствует Release-файл). Не роняем
    # весь скрипт из-за этого — если основные репозитории Ubuntu обновились
    # успешно, установка нужных пакетов ниже всё равно сработает. Если же
    # проблема в самих нужных пакетах — apt-get install ниже упадёт сам и
    # остановит скрипт через set -e.
    if ! apt-get update -y 2>&1 | tee -a "$LOG_FILE"; then
        log "ПРЕДУПРЕЖДЕНИЕ: apt-get update завершился с ошибкой на одном из репозиториев (см. вывод выше). Продолжаем, если это сторонний репозиторий, а не основной архив Ubuntu — установка пакетов ниже это выявит."
    fi
fi

run "DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    wget \
    git \
    perl \
    libpcre2-dev \
    zlib1g-dev \
    libssl-dev \
    dpkg-dev \
    libxml2-dev \
    libxslt1-dev \
    libgd-dev \
    libgeoip-dev \
    libperl-dev"
# libxml2-dev/libxslt1-dev -- для --with-http_xslt_module
# libgd-dev                -- для --with-http_image_filter_module
# libgeoip-dev             -- для --with-http_geoip_module / --with-stream_geoip_module
# libperl-dev              -- для --with-http_perl_module / --with-mail (perl-скрипты)
#
# Примечание: пакет libgeoip-dev использует устаревшую библиотеку GeoIP (legacy),
# которая давно не обновляется upstream (замена — libmaxminddb), но она нужна
# именно потому, что исходный nginx собран с --with-http_geoip_module=dynamic
# и это единственный способ повторить идентичную сборку.

# ---------------------------------------------------------------------------
# 3. Скачиваем и распаковываем исходники OpenSSL 3.5
# ---------------------------------------------------------------------------
run "mkdir -p '$BUILD_DIR'"
cd "$BUILD_DIR" 2>/dev/null || true

OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_TARBALL}"

download_and_extract_openssl() {
    log "Скачиваем исходники OpenSSL ${OPENSSL_VERSION}..."
    run "cd '$BUILD_DIR' && wget -q '$OPENSSL_URL' -O '$OPENSSL_TARBALL'"

    # Проверяем, что архив скачался целиком и не битый, прежде чем распаковывать.
    # Битый/неполный архив — самая частая причина ошибки make на шаге
    # "No rule to make target 'test/build.info'".
    if [[ "$DRY_RUN" != "1" ]]; then
        if ! tar tzf "${BUILD_DIR}/${OPENSSL_TARBALL}" >/dev/null 2>&1; then
            rm -f "${BUILD_DIR}/${OPENSSL_TARBALL}"
            die "Скачанный архив ${OPENSSL_TARBALL} повреждён (не проходит проверку tar tzf). Проверьте место на диске (df -h) и сеть, затем запустите скрипт заново."
        fi
    fi

    run "cd '$BUILD_DIR' && tar xzf '$OPENSSL_TARBALL'"
}

if [[ ! -d "$OPENSSL_SRC_DIR" ]]; then
    download_and_extract_openssl
else
    log "Исходники OpenSSL ${OPENSSL_VERSION} уже распакованы, пропускаем скачивание."
fi

# Проверяем целостность дерева исходников ВСЕГДА — не только сразу после
# распаковки, но и при переиспользовании ранее закешированной директории.
# Иначе однажды повреждённая директория (например, от старого неудачного
# запуска) так и будет тихо переиспользоваться при каждом следующем запуске
# скрипта (в т.ч. после обновления версии nginx), и ошибка make будет
# повторяться бесконечно.
if [[ "$DRY_RUN" != "1" ]]; then
    if [[ ! -f "${OPENSSL_SRC_DIR}/test/build.info" ]]; then
        log "Обнаружено неполное/повреждённое дерево исходников OpenSSL в ${OPENSSL_SRC_DIR} (нет test/build.info) — пересобираем с нуля."
        rm -rf "$OPENSSL_SRC_DIR"
        rm -f "${BUILD_DIR}/${OPENSSL_TARBALL}"
        download_and_extract_openssl
        if [[ ! -f "${OPENSSL_SRC_DIR}/test/build.info" ]]; then
            die "Повторная закачка/распаковка OpenSSL всё равно не дала полного дерева исходников. Проверьте место на диске (df -h) и сетевое соединение."
        fi
    fi

    # На всякий случай чистим артефакты предыдущей сборки (Makefile,
    # configdata.pm, установленные .openssl-файлы) — они могли остаться от
    # прошлого запуска (например, под другую версию nginx или с другими
    # --with-openssl-opt) и привести к несогласованному состоянию при
    # повторной сборке. Сами исходники (.c/.h/build.info и т.п.) не трогаем.
    if [[ -f "${OPENSSL_SRC_DIR}/Makefile" || -f "${OPENSSL_SRC_DIR}/configdata.pm" || -d "${OPENSSL_SRC_DIR}/.openssl" ]]; then
        log "Очищаем артефакты предыдущей сборки OpenSSL перед повторной сборкой..."
        rm -f "${OPENSSL_SRC_DIR}/Makefile" "${OPENSSL_SRC_DIR}/configdata.pm"
        rm -rf "${OPENSSL_SRC_DIR}/.openssl"
    fi
fi

if [[ "$DRY_RUN" != "1" ]]; then
    [[ -d "$OPENSSL_SRC_DIR" ]] || die "Не удалось найти распакованные исходники OpenSSL по пути $OPENSSL_SRC_DIR"
fi

# ---------------------------------------------------------------------------
# 4. Скачиваем исходники той же версии nginx, что установлена
# ---------------------------------------------------------------------------
NGINX_TARBALL="nginx-${CURRENT_NGINX_VERSION}.tar.gz"
NGINX_URL="https://nginx.org/download/${NGINX_TARBALL}"
NGINX_SRC_DIR="${BUILD_DIR}/nginx-${CURRENT_NGINX_VERSION}"

if [[ ! -d "$NGINX_SRC_DIR" ]]; then
    log "Скачиваем исходники nginx ${CURRENT_NGINX_VERSION}..."
    run "cd '$BUILD_DIR' && wget -q '$NGINX_URL' -O '$NGINX_TARBALL'"
    run "cd '$BUILD_DIR' && tar xzf '$NGINX_TARBALL'"
else
    log "Исходники nginx ${CURRENT_NGINX_VERSION} уже распакованы, пропускаем скачивание."
fi

if [[ "$DRY_RUN" != "1" ]]; then
    [[ -d "$NGINX_SRC_DIR" ]] || die "Не удалось найти распакованные исходники nginx по пути $NGINX_SRC_DIR. Возможно, версия ${CURRENT_NGINX_VERSION} снята с nginx.org (например, это сборка из PPA/vendor-патча) — проверьте вручную на https://nginx.org/download/ или у вендора."
fi

# ---------------------------------------------------------------------------
# 5. Собираем nginx, статически линкуя с OpenSSL 3.5
# ---------------------------------------------------------------------------
log "Конфигурируем сборку nginx с OpenSSL ${OPENSSL_VERSION} (статическая линковка)..."

FULL_CONFIGURE_ARGS="${CONFIGURE_ARGS_CLEAN} --with-openssl=${OPENSSL_SRC_DIR} --with-openssl-opt=no-shared ${NGINX_MODULES}"

log "Итоговые configure arguments:"
log "$FULL_CONFIGURE_ARGS"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "(dry-run) cd '$NGINX_SRC_DIR' && ./configure $FULL_CONFIGURE_ARGS"
    echo "(dry-run) make -j\$(nproc)"
    log "Dry-run завершён. Реальная сборка не выполнялась."
    exit 0
fi

cd "$NGINX_SRC_DIR"
eval ./configure "$FULL_CONFIGURE_ARGS" 2>&1 | tee -a "$LOG_FILE"
make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"

# Проверяем, что бинарник действительно слинкован со свежим OpenSSL
NEW_BIN="./objs/nginx"
[[ -x "$NEW_BIN" ]] || die "Сборка не создала исполняемый файл nginx"

NEW_VERSION_OUTPUT="$("$NEW_BIN" -V 2>&1)"
if ! echo "$NEW_VERSION_OUTPUT" | grep -q "OpenSSL ${OPENSSL_VERSION}"; then
    log "ПРЕДУПРЕЖДЕНИЕ: собранный бинарник не подтверждает версию OpenSSL ${OPENSSL_VERSION} в выводе -V:"
    log "$NEW_VERSION_OUTPUT"
fi

# ---------------------------------------------------------------------------
# 6. Бэкап старого бинарника и установка нового
# ---------------------------------------------------------------------------
BACKUP_PATH="${NGINX_BIN_PATH}.bak.$(date +%Y%m%d%H%M%S)"
log "Делаем резервную копию текущего nginx: ${BACKUP_PATH}"
cp "$NGINX_BIN_PATH" "$BACKUP_PATH"

log "Останавливаем nginx перед заменой бинарника..."
systemctl stop nginx || log "Не удалось остановить сервис через systemctl (возможно, управляется иначе)"

log "Устанавливаем новый бинарник nginx..."
cp "$NEW_BIN" "$NGINX_BIN_PATH"
chmod 755 "$NGINX_BIN_PATH"

log "Проверяем корректность конфигурации (nginx -t)..."
if ! nginx -t 2>&1 | tee -a "$LOG_FILE"; then
    log "Конфигурация некорректна — откатываем бинарник обратно."
    cp "$BACKUP_PATH" "$NGINX_BIN_PATH"
    systemctl start nginx || true
    die "Проверка конфигурации не пройдена, выполнен откат к предыдущей версии nginx."
fi

log "Запускаем nginx..."
systemctl start nginx

sleep 1
if ! systemctl is-active --quiet nginx; then
    log "nginx не запустился — откатываем бинарник обратно."
    cp "$BACKUP_PATH" "$NGINX_BIN_PATH"
    systemctl start nginx || true
    die "nginx не запустился после обновления, выполнен откат к предыдущей версии."
fi

# ---------------------------------------------------------------------------
# 7. Защита от перезаписи apt при системных обновлениях
# ---------------------------------------------------------------------------
# Пакет nginx в dpkg остаётся "установленным" в исходной версии из репозитория,
# хотя бинарник на диске уже пересобран с OpenSSL 3.5. Обычный `apt upgrade`
# или `apt install --reinstall nginx` увидит несовпадение чексуммы и молча
# перезапишет бинарник обратно оригинальным пакетом (со старым OpenSSL).
# apt-mark hold блокирует апгрейд/переустановку именно этого пакета через apt,
# не затрагивая остальные пакеты системы.
log "Ставим пакет nginx на hold, чтобы apt не перезаписал пересобранный бинарник..."
if apt-mark hold nginx 2>&1 | tee -a "$LOG_FILE"; then
    log "nginx помещён в hold. Проверить: apt-mark showhold"
    log "Снять hold (если понадобится штатное обновление из репозитория): apt-mark unhold nginx"
else
    log "ПРЕДУПРЕЖДЕНИЕ: не удалось выполнить apt-mark hold nginx — сделайте это вручную: sudo apt-mark hold nginx"
fi

# ---------------------------------------------------------------------------
# 8. Итоговая проверка
# ---------------------------------------------------------------------------
log "=== Готово ==="
log "Версия nginx и линковка с OpenSSL:"
nginx -V 2>&1 | tee -a "$LOG_FILE"

log ""
log "Резервная копия предыдущего бинарника сохранена в: ${BACKUP_PATH}"
log "Исходники сборки остались в: ${BUILD_DIR} (можно удалить вручную, если больше не нужны)"
log ""
log "Совет: проверьте работу TLS снаружи, например:"
log "  echo | openssl s_client -connect <ваш_домен>:443 -tls1_3 2>/dev/null | grep -A2 'Protocol\\|Cipher'"
REBUILD_OPENSSL_EOF

    ask ver "Версия OpenSSL [3.5.2] (q — отмена): " || { cancelled; rm -f "$tmp"; return 0; }
    ver=${ver:-3.5.2}
    if [[ ! $ver =~ ^3\.5\.[0-9]+$ ]]; then
        warn "Ожидается версия вида 3.5.x."
        rm -f "$tmp"
        return 1
    fi
    OPENSSL_VERSION="$ver" bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    if ((rc != 0)); then
        err "Пересборка завершилась с ошибкой (код $rc). Лог: /var/log/rebuild_nginx_openssl35.log"
        return 1
    fi
}

# ---------- пункт 6: тесты ----------
# ensure_cmds <утилита>...: молча доустанавливает недостающие пакеты (на все вопросы установщика — ответ по умолчанию)
ensure_cmds() {
    local c missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) && return 0
    info "Не найдено: ${missing[*]} — устанавливаю"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        "${missing[@]}" || { err "Не удалось установить: ${missing[*]}"; return 1; }
}

# run_test <название> <функция>: Ctrl+C во время теста останавливает только тест и возвращает в меню тестов
run_test() {
    local title=$1 rc _x
    shift
    info "$title"
    trap 'echo; warn "Тест прерван (Ctrl+C)."' INT
    "$@"
    rc=$?
    trap on_interrupt INT
    ((rc == 0)) || warn "Тест завершился с кодом $rc."
    ask _x "Enter — вернуться в меню тестов: " || true
}

t_ipregion()  { ensure_cmds wget || return 1; bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh); }
t_ipquality() { ensure_cmds curl || return 1; bash <(curl -Ls IP.Check.Place) -l en; }
t_dpi()       { ensure_cmds wget || return 1; bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi; }
t_geoblock()  { ensure_cmds wget || return 1; bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock; }
t_iperf()     { ensure_cmds wget iperf3 || return 1; bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh); }
t_speedtest() { ensure_cmds wget || return 1; wget -qO- speedtest.artydev.ru | bash; }
t_yabs()      { ensure_cmds curl || return 1; curl -sL yabs.sh | bash -s -- -4; }
t_bench()     { ensure_cmds wget || return 1; wget -qO- bench.sh | bash; }

tests_menu() {
    local c
    while true; do
        cat <<'EOF'

=====================================
   ТЕСТЫ
=====================================
 1) IP region
 2) IPQuality
 3) Censorcheck DPI
 4) Censorcheck Geoblock
 5) Тест до российских iPerf3 серверов
 6) Speedtest
 7) YABS (быстрый тест производительности)
 8) Server test (bench.sh)
 0) Назад
=====================================
 Ctrl+C во время теста — остановить тест
EOF
        read -rp "Выберите тест: " c || { echo; return 0; }
        case $c in
            1) run_test "IP region" t_ipregion ;;
            2) run_test "IPQuality" t_ipquality ;;
            3) run_test "Censorcheck DPI" t_dpi ;;
            4) run_test "Censorcheck Geoblock" t_geoblock ;;
            5) run_test "Тест до российских iPerf3 серверов" t_iperf ;;
            6) run_test "Speedtest" t_speedtest ;;
            7) run_test "YABS" t_yabs ;;
            8) run_test "Server test" t_bench ;;
            0|q|Q) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ---------- очистка автозапуска (после reboot) ----------
cleanup_autorun() {
    local u=${SUDO_USER:-} home f
    [[ -n $u && $u != root ]] || return 0
    home=$(getent passwd "$u" | cut -d: -f6)
    f="$home/.profile"
    [[ -f $f ]] && sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$f"
    return 0
}

# ---------- копирование скрипта в домашнюю папку пользователя ----------
copy_script_home() {
    local u=${SUDO_USER:-} home dest
    [[ -n $u && $u != root ]] || return 0
    home=$(getent passwd "$u" | cut -d: -f6)
    dest="$home/server-setup.sh"
    if install -m 755 -o "$u" -g "$(id -gn "$u")" "$SCRIPT_PATH" "$dest"; then
        info "Скрипт скопирован в $dest"
    else
        warn "Не удалось скопировать скрипт в $dest"
    fi
}

# ---------- меню ----------
main_menu() {
    local choice
    while true; do
        cat <<'EOF'

=====================================
   МАСТЕР НАСТРОЙКИ СЕРВЕРА
=====================================
 1) Настройка сервера
 2) Установка прокси (autoXRAY)
 3) Активация root
 4) Деактивация root
 5) Пересборка OpenSSL (nginx + OpenSSL 3.5)
 6) Тесты
 0) Выход
=====================================
 Ctrl+C — прервать скрипт, q — отменить текущий шаг
EOF
        read -rp "Выберите пункт: " choice || { echo; exit 0; }
        case $choice in
            1) server_setup ;;
            2) install_proxy ;;
            3) set_root_access yes ;;
            4) set_root_access no ;;
            5) rebuild_openssl ;;
            6) tests_menu ;;
            0|q|Q) exit 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

if [[ ${1:-} == --after-reboot ]]; then
    cleanup_autorun
    copy_script_home
fi

main_menu
