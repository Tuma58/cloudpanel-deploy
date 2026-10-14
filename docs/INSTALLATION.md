# Установка CloudPanel

## Официальные источники

- [Requirements](https://www.cloudpanel.io/docs/v2/requirements/)
- [Install on other/dedicated server](https://www.cloudpanel.io/docs/v2/getting-started/other/)
- [WordPress](https://www.cloudpanel.io/docs/v2/php/applications/wordpress/)

## Поддерживаемые ОС (этот проект)

Согласно официальным Requirements на дату сборки проекта:

- Debian 12 (Bookworm)
- Debian 13 (Trixie)
- Архитектуры: x86_64 / amd64, aarch64 / arm64

**Не поддерживаются автоматически:** Debian 11 и ниже, Ubuntu (хотя официальный установщик умеет Ubuntu — этот комплект заточен под Debian), любые «нечистые» серверы с уже установленным веб-стеком.

## Минимальные ресурсы

- CPU ≥ 1
- RAM ≥ 2 GB
- Disk ≥ 10 GB

## Что делает официальный установщик

Устанавливает и настраивает стек самостоятельно (Nginx, PHP, выбранная БД по `DB_ENGINE`, компоненты CloudPanel, интегрированный firewall на базе UFW).  
**Не устанавливайте** Nginx/PHP/MariaDB вручную «заранее» без доказанной необходимости.

## Последовательность

```bash
# 1. Скопировать проект на сервер и перейти в каталог
cd cloudpanel-deploy   # или корень этого репозитория

# 2. Конфигурация
cp config/deploy.env.example config/deploy.env
# Отредактируйте DB_ENGINE, SITE_DOMAIN, ADMIN_SOURCE_IP, INSTALLER_SHA256

# 3. Диагностика (ничего не ставит)
sudo bash scripts/00-preflight.sh

# 4. Подготовка (curl/wget/sudo, apt update, опционально upgrade)
sudo bash scripts/10-prepare-system.sh

# 5. Установка (только после явного подтверждения)
sudo CONFIRM_INSTALL=YES bash scripts/20-install-cloudpanel.sh

# 6. Проверка
sudo bash scripts/30-verify-installation.sh

# 7. Пост-проверки и рекомендации
sudo bash scripts/40-postinstall-checks.sh
```

## Выбор DB_ENGINE

| Debian | Допустимые значения (по официальному install.sh) |
|--------|--------------------------------------------------|
| 12 | MYSQL_8.4, MYSQL_8.0, MARIADB_10.11, MARIADB_11.4, MARIADB_11.8, MARIADB_12.3 |
| 13 | MYSQL_8.4, MYSQL_8.0, MARIADB_11.8, MARIADB_12.3 |

Рекомендация для WordPress: `MARIADB_11.8`.

## Контрольная сумма установщика

Скрипт скачивает `install.sh` отдельно и сверяет SHA-256 с `INSTALLER_SHA256`.  
Перед каждой установкой сверьте значение с актуальной страницей:

https://www.cloudpanel.io/docs/v2/getting-started/other/

Не выдумывайте контрольные суммы. Если документация обновила hash — обновите `config/deploy.env`.

## Первичный администратор

1. Откройте `https://<PUBLIC_IP>:8443`.
2. Примите предупреждение о self-signed сертификате.
3. **Немедленно** создайте администратора (официально есть окно для ботов).
4. Ограничьте порт 8443 вашим IP.

## Смена hostname (вручную)

Автосмена hostname отключена. Если необходимо:

1. Сохраните доступ через консоль провайдера.
2. Проверьте текущее: `hostnamectl; hostname -f`.
3. Измените: `hostnamectl set-hostname newname`.
4. Обновите `/etc/hosts` (127.0.1.1 → newname).
5. Перелогиньтесь по SSH и повторите `00-preflight.sh`.

## Создание сайта WordPress

После установки панели (не автоматизируется без ваших данных):

1. UI: **+ Add Site → Create a WordPress Site**.
2. Укажите Domain Name, Site Title, Admin User Name, Admin Password, Admin E-Mail.
3. Скопируйте выданные учётные данные в безопасное хранилище.
4. Настройте DNS A/AAAA на IP сервера.
5. Выпустите Let's Encrypt в настройках сайта.
6. Файлы сайта — от имени site user (`/home/<siteUser>/htdocs/...`), не от root.
7. Включите Remote Backups.
8. Проверьте сайт извне по HTTPS.

Официально: https://www.cloudpanel.io/docs/v2/php/applications/wordpress/
