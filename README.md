# Установка Traefik и 3x-ui на Ubuntu

Установщик разворачивает два проекта Docker Compose из [RewBed/default_traefik](https://github.com/RewBed/default_traefik) и [RewBed/3x-ui](https://github.com/RewBed/3x-ui) на одном сервере. Traefik получает и продлевает сертификат Let's Encrypt для панели 3x-ui через HTTP-01. Панель доступна по HTTPS со случайным путём входа.

## Перед установкой

- Подготовьте сервер Ubuntu с systemd и свободными TCP-портами 80, 443 и 2053. Для входящего трафика из интернета откройте TCP 80 и 443. Скрипт рассчитан на установку нового стека со своими каталогами данных.
- Для доступа по домену создайте запись `A` на публичный IPv4 сервера. Если есть `AAAA`, она тоже должна вести на этот сервер. При первичной установке используйте DNS-записи без проксирования через CDN. Для доступа по публичному IPv4 достаточно самого адреса и доступных портов.
- Для первого скачивания приватного `RewBed/default_traefik` подготовьте [fine-grained Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) с доступом к этому репозиторию и разрешением **Contents: Read-only**. Запустите скрипт в интерактивном терминале. Git запросит имя пользователя GitHub, а в поле `Password` нужно ввести токен. Скрипт и Git не сохраняют введённый токен.

## Запуск

```bash
git clone https://github.com/RewBed/3x-ui-installer.git
cd 3x-ui-installer
sudo bash install.sh panel.example.com admin@example.com
```

Для доступа по IP подставьте публичный IPv4 своего сервера и контактный email для ACME.

```bash
sudo bash install.sh 203.0.113.10 admin@example.com
```

Для IPv4 установщик задаёт `ACME_IP_ADDRESS` в `.env` Traefik и выбирает `letsencryptip` в `.env` 3x-ui. Traefik автоматически продлевает [короткоживущий IP-сертификат Let's Encrypt](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability/).

Скрипт устанавливает Docker Engine из официального APT-репозитория Docker, если Docker отсутствует. Для существующего Docker он проверяет наличие плагина Compose версии 2.24.4 или новее. Затем создаёт общую сеть `proxy`, скачивает зафиксированные версии Compose-конфигураций, записывает `.env` и запускает Traefik и 3x-ui. Порт панели 3x-ui привязывается к IPv4-шлюзу сети `proxy`.

После проверки HTTPS скрипт выводит адрес 3x-ui, логин и пароль. Начальные данные входа также сохраняются в `/opt/3x-ui-stack/credentials.txt` с правами `0600`. При повторном запуске укажите адрес 3x-ui и email из первой установки. База и пароль 3x-ui сохраняются. Если меняли пароль через панель, используйте актуальный пароль.

## Проверка запуска

Если HTTPS не подтвердился за три минуты, проверьте адрес панели, доступность портов и DNS при доступе по домену. Compose-проекты продолжают работать, а Traefik сможет выпустить сертификат после устранения проблемы. Журналы доступны через Docker Compose.

```bash
sudo docker compose --env-file /opt/3x-ui-stack/traefik/.env \
  -f /opt/3x-ui-stack/traefik/compose.yml logs --tail=100

sudo docker compose --env-file /opt/3x-ui-stack/3x-ui/.env \
  -f /opt/3x-ui-stack/3x-ui/compose.yaml \
  -f /opt/3x-ui-stack/3x-ui/installer.yml logs --tail=100
```

База 3x-ui хранится в `/opt/3x-ui-stack/3x-ui/db`, сертификаты Traefik в Docker volume `traefik_certificates`.
