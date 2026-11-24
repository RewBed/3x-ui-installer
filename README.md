# Установка Traefik и 3x-ui на Ubuntu

Установщик разворачивает два проекта Docker Compose из [RewBed/default_traefik](https://github.com/RewBed/default_traefik) и [RewBed/3x-ui](https://github.com/RewBed/3x-ui) на одном сервере. Traefik получает и продлевает сертификат Let's Encrypt для панели 3x-ui через HTTP-01. Панель доступна по HTTPS со случайным путём входа.

## Перед установкой

- Подготовьте сервер Ubuntu с systemd и свободными TCP-портами 80, 443 и 2053. Для входящего трафика из интернета откройте TCP 80 и 443. Скрипт рассчитан на установку нового стека со своими каталогами данных.
- Создайте DNS-запись `A` для домена панели, например `panel.example.com`, и укажите публичный IPv4 сервера. Если есть `AAAA`, она тоже должна вести на этот сервер. При первичной установке используйте DNS-записи без проксирования через CDN.
- Для приватного репозитория `RewBed/default_traefik` дайте серверу SSH-доступ на чтение. Можно добавить публичный ключ сервера в **Settings → Deploy keys** этого репозитория. Приватный ключ должен быть доступен пользователю `root`, от которого запускается установщик.

Проверьте доступ к Traefik. При первом SSH-подключении сверьте ключ хоста с [опубликованными отпечатками GitHub](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).

```bash
sudo git ls-remote git@github.com:RewBed/default_traefik.git HEAD
```

Если ключ уже загружен в ваш SSH-агент, можно передать его сокет через `sudo --preserve-env=SSH_AUTH_SOCK` при проверке доступа и запуске установщика.

## Запуск

```bash
git clone https://github.com/RewBed/3x-ui-installer.git
cd 3x-ui-installer
sudo bash install.sh panel.example.com admin@example.com
```

Укажите домен панели и email для ACME. Скрипт устанавливает Docker Engine из официального APT-репозитория Docker, если Docker отсутствует. Для существующего Docker он проверяет наличие плагина Compose версии 2.24.4 или новее. Затем создаёт общую сеть `proxy`, скачивает зафиксированные версии Compose-конфигураций, записывает `.env` и запускает Traefik и 3x-ui. Порт панели 3x-ui привязывается к IPv4-шлюзу сети `proxy`.

После проверки HTTPS скрипт выводит адрес 3x-ui, логин и пароль. Начальные данные входа также сохраняются в `/opt/3x-ui-stack/credentials.txt` с правами `0600`. При повторном запуске укажите домен 3x-ui и email из первой установки. База и пароль 3x-ui сохраняются. Если меняли пароль через панель, используйте актуальный пароль.

## Проверка запуска

Если HTTPS не подтвердился за три минуты, проверьте DNS и доступность портов. Compose-проекты продолжают работать, а Traefik сможет выпустить сертификат после устранения проблемы. Журналы доступны через Docker Compose.

```bash
sudo docker compose --env-file /opt/3x-ui-stack/traefik/.env \
  -f /opt/3x-ui-stack/traefik/compose.yml logs --tail=100

sudo docker compose --env-file /opt/3x-ui-stack/3x-ui/.env \
  -f /opt/3x-ui-stack/3x-ui/compose.yaml \
  -f /opt/3x-ui-stack/3x-ui/installer.yml logs --tail=100
```

База 3x-ui хранится в `/opt/3x-ui-stack/3x-ui/db`, сертификаты Traefik в Docker volume `traefik_certificates`.
