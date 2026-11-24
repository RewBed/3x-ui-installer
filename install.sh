#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly install_dir=/opt/3x-ui-stack
readonly traefik_repo=git@github.com:RewBed/default_traefik.git
readonly traefik_commit=9326d23d70b4bb657c314ba067a7198208a3d736
readonly panel_repo=https://github.com/RewBed/3x-ui.git
readonly panel_commit=bfaf87b9889da928ae856a172642cd52d68e7609

usage() {
    printf 'Использование: sudo bash install.sh PANEL_DOMAIN TRAEFIK_DOMAIN ACME_EMAIL\n'
}

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

valid_domain() {
    local domain=$1
    local pattern='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
    [[ ${#domain} -le 253 && $domain =~ $pattern ]]
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-remove "$@"
}

install_dependencies() {
    local missing=()
    command -v git >/dev/null || missing+=(git)
    command -v ssh >/dev/null || missing+=(openssh-client)
    command -v curl >/dev/null || missing+=(curl)
    command -v openssl >/dev/null || missing+=(openssl)
    command -v htpasswd >/dev/null || missing+=(apache2-utils)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)

    if ((${#missing[@]})); then
        apt-get update
        apt_install "${missing[@]}"
    fi
}

fetch_source() (
    local repo=$1 commit=$2 dest=$3 staging
    if [[ -d $dest ]]; then
        [[ $(git -C "$dest" rev-parse HEAD) == "$commit" ]] ||
            die "В $dest ожидался коммит $commit."
        exit 0
    fi

    staging=$(mktemp -d "$install_dir/.source.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    git -C "$staging" init --quiet
    git -C "$staging" fetch --quiet --depth=1 "$repo" "$commit" ||
        die "Не удалось скачать $repo. Проверьте доступ к репозиторию и SSH-ключ Traefik."
    git -C "$staging" checkout --quiet --detach "$commit"
    mv -T -- "$staging" "$dest"
)

add_docker_repository() {
    local key
    install -d -m 0755 /etc/apt/keyrings
    key=$(mktemp)
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key"; then
        rm -f -- "$key"
        die 'Не удалось загрузить ключ APT Docker.'
    fi
    install -m 0644 "$key" /etc/apt/keyrings/docker.asc
    rm -f -- "$key"

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    chmod 0644 /etc/apt/sources.list.d/docker.sources
}

install_docker() {
    local compose_version
    export DOCKER_HOST=unix:///var/run/docker.sock
    unset DOCKER_CONTEXT

    if ! command -v docker >/dev/null; then
        printf 'Установка Docker Engine из официального репозитория Docker.\n'
        if [[ ! -f /etc/apt/sources.list.d/docker.sources && ! -f /etc/apt/sources.list.d/docker.list ]]; then
            add_docker_repository
        fi
        apt-get update
        apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
    elif ! docker compose version >/dev/null 2>&1; then
        printf 'Установка плагина Docker Compose для существующего Docker.\n'
        if [[ $(dpkg-query -W -f='${Status}' docker.io 2>/dev/null || true) == 'install ok installed' ]]; then
            apt-get update
            apt_install docker-compose-v2
        else
            if [[ ! -f /etc/apt/sources.list.d/docker.sources && ! -f /etc/apt/sources.list.d/docker.list ]]; then
                add_docker_repository
            fi
            apt-get update
            apt_install docker-compose-plugin
        fi
    fi

    docker info >/dev/null 2>&1 || systemctl start docker
    docker info >/dev/null || die 'Локальный Docker Engine недоступен.'
    compose_version=$(docker compose version --short)
    compose_version=${compose_version#v}
    dpkg --compare-versions "$compose_version" ge 2.24.4 ||
        die "Требуется Docker Compose 2.24.4 или новее. Установлена версия $compose_version."
}

traefik() {
    docker compose --env-file "$traefik_dir/.env" \
        -f "$traefik_dir/compose.yml" -f "$traefik_dir/installer.yml" "$@"
}

panel() {
    docker compose --env-file "$panel_dir/.env" \
        -f "$panel_dir/compose.yaml" -f "$panel_dir/installer.yml" "$@"
}

configure_stack() {
    local bind_ip=$1
    if [[ -f $panel_dir/.env ]] && ! grep -Fxq "PANEL_BIND_IP=$bind_ip" "$panel_dir/.env"; then
        die 'Изменился шлюз Docker-сети proxy. Проверьте сеть и адрес привязки 3x-ui.'
    fi

    printf 'ACME_EMAIL=%s\nDASHBOARD_DOMAIN=%s\n' "$acme_email" "$traefik_domain" > "$traefik_dir/.env"
    install -m 0600 "$script_dir/traefik.compose.yml" "$traefik_dir/installer.yml"
    htpasswd -niBC 10 admin <<< "$dashboard_password" > "$traefik_dir/dashboard.htpasswd"

    cat > "$panel_dir/.env.new" <<EOF
DOMAIN=$panel_domain
TRAEFIK_CERT_RESOLVER=letsencrypt
PANEL_PORT=2053
PANEL_BIND_IP=$bind_ip
SUB_PORT=2096
SUB_PATH=/sub/
EOF
    mv -T -- "$panel_dir/.env.new" "$panel_dir/.env"
    install -m 0600 "$script_dir/3x-ui.compose.yml" "$panel_dir/installer.yml"
}

init_panel() {
    local result
    if [[ -f $install_dir/.panel-initialized ]]; then
        [[ -s $panel_dir/db/x-ui.db ]] || die "В $panel_dir/db отсутствует база 3x-ui. Восстановите её перед запуском."
        return 0
    fi

    # Run only the settings command. The web server starts after its admin has been configured.
    if ! result=$(panel run --rm --no-deps -T --entrypoint /app/x-ui 3xui \
        setting -username "$panel_user" -password "$panel_password" -port 2053 \
        -listenIP "$bind_ip" -webBasePath "$panel_path"); then
        die 'Команда настройки 3x-ui завершилась ошибкой.'
    fi
    # x-ui can report a failed setting on stdout while returning exit code 0.
    [[ $result == *'Username and password updated successfully'* &&
       $result == *'Port set successfully: 2053'* &&
       $result == *"listen $bind_ip set successfully"* &&
       $result == *'Base URI path set successfully'* ]] ||
        die '3x-ui не подтвердил сохранение логина, пароля, порта и пути панели.'
    [[ -s $panel_dir/db/x-ui.db ]] || die '3x-ui не сохранил базу настроек.'
    touch "$install_dir/.panel-initialized"
}

wait_for_https() {
    local deadline=$((SECONDS + 180)) panel_status dashboard_status
    printf 'Ожидание HTTPS для обоих доменов, до трёх минут.\n'
    while (( SECONDS < deadline )); do
        panel_status=$(curl --silent --noproxy '*' --max-time 4 --output /dev/null \
            --write-out '%{http_code}' --resolve "$panel_domain:443:127.0.0.1" "$panel_url") || panel_status=000
        dashboard_status=$(curl --silent --noproxy '*' --max-time 4 --output /dev/null \
            --write-out '%{http_code}' --resolve "$traefik_domain:443:127.0.0.1" "$dashboard_url") || dashboard_status=000
        if [[ $panel_status == 200 && $dashboard_status == 401 ]]; then
            dashboard_status=$(curl --silent --noproxy '*' --max-time 4 --output /dev/null \
                --write-out '%{http_code}' --resolve "$traefik_domain:443:127.0.0.1" "$dashboard_url" \
                --config - <<< "user = \"admin:$dashboard_password\"") || dashboard_status=000
            [[ $dashboard_status == 200 ]] && return 0
        fi
        sleep 3
    done
    die "HTTPS ещё не проверен (3x-ui: $panel_status, Traefik: $dashboard_status). Проверьте DNS, TCP 80/443 и журналы Compose. Данные входа: $install_dir/credentials.txt."
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# != 3 ]]; then
    usage >&2
    exit 2
fi
[[ $EUID == 0 ]] || die 'Запустите скрипт через sudo.'
[[ -r /etc/os-release ]] || die 'Требуется Ubuntu.'
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu ]] || die 'Требуется Ubuntu.'

panel_domain=${1,,}
traefik_domain=${2,,}
acme_email=$3
valid_domain "$panel_domain" && valid_domain "$traefik_domain" || die 'Укажите два DNS-имени.'
[[ $panel_domain != "$traefik_domain" ]] || die 'Домены панели и Traefik должны различаться.'
email_pattern='^[A-Za-z0-9][A-Za-z0-9._+%-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
[[ $acme_email =~ $email_pattern ]] || die 'Некорректный адрес электронной почты ACME.'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
traefik_dir=$install_dir/traefik
panel_dir=$install_dir/3x-ui
[[ -f $script_dir/traefik.compose.yml && -f $script_dir/3x-ui.compose.yml ]] ||
    die 'Склонируйте репозиторий установщика целиком.'

exec 9>/run/lock/3x-ui-installer.lock
flock -n 9 || die 'Другой экземпляр установщика уже работает.'
if [[ ! -e $install_dir ]]; then
    mkdir -m 0700 -- "$install_dir"
fi
[[ ! -L $install_dir && -d $install_dir && $(stat -c '%u:%a' "$install_dir") == 0:700 ]] ||
    die "Требуется обычный каталог $install_dir с владельцем root и правами 0700."

install_dependencies
if [[ ! -f $install_dir/credentials.txt ]]; then
    [[ ! -e $panel_dir && ! -e $traefik_dir ]] || die "В $install_dir уже есть конфигурация."
    panel_user=admin-$(openssl rand -hex 4)
    panel_password=$(openssl rand -hex 24)
    panel_path=/$(openssl rand -hex 12)/
    dashboard_password=$(openssl rand -hex 24)
    cat > "$install_dir/credentials.new" <<EOF
PANEL_DOMAIN=$panel_domain
TRAEFIK_DOMAIN=$traefik_domain
ACME_EMAIL=$acme_email
PANEL_USER=$panel_user
PANEL_PASSWORD=$panel_password
PANEL_PATH=$panel_path
TRAEFIK_USER=admin
TRAEFIK_PASSWORD=$dashboard_password
EOF
    mv -T -- "$install_dir/credentials.new" "$install_dir/credentials.txt"
fi

read_setting() {
    local line
    line=$(grep -m 1 "^$1=" "$install_dir/credentials.txt") || die "В credentials.txt отсутствует $1."
    printf '%s\n' "${line#*=}"
}

[[ $(read_setting PANEL_DOMAIN) == "$panel_domain" && $(read_setting TRAEFIK_DOMAIN) == "$traefik_domain" &&
   $(read_setting ACME_EMAIL) == "$acme_email" ]] || die "Укажите домены и email из $install_dir/credentials.txt."
panel_user=$(read_setting PANEL_USER)
panel_password=$(read_setting PANEL_PASSWORD)
panel_path=$(read_setting PANEL_PATH)
dashboard_password=$(read_setting TRAEFIK_PASSWORD)
panel_url=https://$panel_domain$panel_path
dashboard_url=https://$traefik_domain/dashboard/

printf 'Загрузка конфигураций Traefik и 3x-ui.\n'
fetch_source "$traefik_repo" "$traefik_commit" "$traefik_dir"
fetch_source "$panel_repo" "$panel_commit" "$panel_dir"
install_docker
docker network inspect proxy >/dev/null 2>&1 || docker network create --driver bridge proxy
[[ $(docker network inspect --format '{{.Driver}}' proxy) == bridge ]] || die 'Сеть proxy должна быть типа bridge.'
bind_ip=$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' proxy)
[[ $bind_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Сети proxy нужен IPv4-шлюз.'

configure_stack "$bind_ip"
traefik config --quiet
panel config --quiet
printf 'Запуск Traefik.\n'
traefik up -d
printf 'Настройка и запуск 3x-ui.\n'
init_panel
panel up -d
wait_for_https

printf '\n3x-ui: %s\nЛогин: %s\nПароль: %s\n' "$panel_url" "$panel_user" "$panel_password"
printf '\nTraefik: %s\nЛогин: admin\nПароль: %s\n' "$dashboard_url" "$dashboard_password"
printf '\nДанные входа сохранены в %s/credentials.txt (только root).\n' "$install_dir"
