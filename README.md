# cloudpanel-deploy

Автоматизированное, безопасное первоначальное развёртывание **CloudPanel** на **чистом VPS с Debian** для последующего размещения WordPress.

Проект предназначен администратору небольшого IT-бизнеса: диагностика → подготовка → официальная установка → проверка → рекомендации по hardening и WordPress.

> Скрипты установки запускайте только на чистом поддерживаемом Debian VPS.  
> Резервные копии не заменяют проверку восстановления.

## Назначение

- Проверить, что сервер чистый и соответствует официальным Requirements CloudPanel.
- Подготовить минимальные зависимости (`curl`, `wget`, `sudo`).
- Установить CloudPanel **официальным** установщиком с проверкой SHA-256.
- Проверить результат и подготовить чеклист безопасности / WordPress.

## Архитектура

```
.
├── README.md
├── SECURITY.md
├── CHANGELOG.md
├── config/          # шаблоны конфигурации (без секретов)
├── scripts/         # исполняемые сценарии Bash
├── tests/           # синтаксис и автопроверки
├── logs/            # журналы выполнения (не в Git)
├── state/           # маркеры идемпотентности (локально)
├── artifacts/       # снимки системы / установщик (локально)
└── docs/            # эксплуатационная документация (RU)
```

## Поддерживаемые ОС

По [официальным Requirements](https://www.cloudpanel.io/docs/v2/requirements/) (зафиксировано в проекте):

| ОС | Статус в этом проекте |
|----|------------------------|
| Debian 12 (Bookworm) | Поддерживается |
| Debian 13 (Trixie) | Поддерживается |
| Debian 11 | Блокируется (нет в актуальных Requirements) |
| Ubuntu | Вне скоупа этого комплекта |
| x86_64 / amd64 | Поддерживается |
| aarch64 / arm64 | Поддерживается |

## Требования к VPS

- Чистый Debian 12 или 13
- ≥ 1 CPU, ≥ 2 GB RAM, ≥ 10 GB disk (**рекомендуется ≥20 GB диска**)
- SSH + root или sudo
- Публичный IPv4 (IPv6 опционально)
- Возможность открыть порты в панели провайдера

## Официальная документация

- https://www.cloudpanel.io/
- https://www.cloudpanel.io/docs/v2/requirements/
- https://www.cloudpanel.io/docs/v2/getting-started/other/
- https://www.cloudpanel.io/docs/v2/guides/best-practices/security/
- https://www.cloudpanel.io/docs/v2/frontend-area/tls/
- https://www.cloudpanel.io/docs/v2/php/applications/wordpress/
- https://github.com/cloudpanel-io
- https://www.debian.org/doc/
- https://letsencrypt.org/docs/

## Одна команда (скопировать → вставить в bash на VPS)

На **чистом** Debian 12/13 от root. Скрипт задаст вопросы в консоли (БД, обновления, подтверждение) и выполнит установку:

```bash
git clone https://github.com/Tuma58/cloudpanel-deploy.git && cd cloudpanel-deploy && sudo bash scripts/install-interactive.sh
```

Если репозиторий уже на сервере:

```bash
cd cloudpanel-deploy && sudo bash scripts/install-interactive.sh
```

Вопросы мастера: чистота сервера → движок БД → домен → IP для 8443 → apt upgrade → reboot → финальное `YES` на установку.

## Пошаговый запуск

```bash
cp config/deploy.env.example config/deploy.env
# Отредактируйте deploy.env: DB_ENGINE, SITE_DOMAIN, ADMIN_SOURCE_IP,
# сверьте INSTALLER_SHA256 с официальной документацией

sudo bash scripts/00-preflight.sh
sudo bash scripts/10-prepare-system.sh
sudo CONFIRM_INSTALL=YES bash scripts/20-install-cloudpanel.sh
sudo bash scripts/30-verify-installation.sh
sudo bash scripts/40-postinstall-checks.sh
```

### Скрипты

| Скрипт | Назначение |
|--------|------------|
| `install-interactive.sh` | Мастер с вопросами в консоли (рекомендуется) |
| `00-preflight.sh` | Диагностика ОС, ресурсов, сети, конфликтов. Ничего не ставит |
| `10-prepare-system.sh` | Проверки, swap при малом RAM, apt, curl/wget/sudo |
| `20-install-cloudpanel.sh` | Загрузка, проверка SHA-256, официальный install.sh, импорт шаблонов |
| `30-verify-installation.sh` | Службы, порты, UI, WordPress vhost template |
| `40-postinstall-checks.sh` | Админ, firewall, TLS, импорт шаблонов при необходимости |
| `common.sh` | Общий модуль логирования и проверок |

## Конфигурация

Скопируйте `config/deploy.env.example` → `config/deploy.env`.

Важные параметры:

- `DB_ENGINE` — по умолчанию `MARIADB_11.8`
- `CONFIRM_INSTALL` — установка только при `YES`
- `INSTALLER_SHA256` — из официальной документации (не выдумывать)
- `ADMIN_SOURCE_IP` — для рекомендаций по ограничению 8443
- `APPLY_SECURITY_UPDATES` / `CONFIRM_REBOOT` — обновления до установки

Секреты в Git не хранятся (см. `SECURITY.md`, `.gitignore`).

## Пример фрагмента диагностического отчёта

```
=== Статус: READY ===
ОС: Debian GNU/Linux 13 (trixie)
Архитектура: x86_64
RAM: 2048 MB
Свободно /: 20 GB
Конфликты: (нет)
```

или

```
=== Статус: BLOCKED ===
Конфликты:
- Установлен пакет nginx
- Порт 80 уже слушается
```

## Сеть и HTTPS

См. `docs/NETWORK.md`, `docs/DNS-AND-TLS.md`, `config/firewall-requirements.md`.

Кратко: **22** и **8443** — только ваш IP; **80/443** — для сайтов; UI сразу после установки: `https://<IP>:8443`.

## Первоначальная настройка CloudPanel

1. Открыть `https://<IP>:8443`, создать администратора немедленно.
2. Ограничить 8443 на firewall провайдера.
3. При необходимости — Basic Auth / 2FA.
4. Настроить Remote Backups.

## WordPress

Автоматическое создание сайта **не выполняется** (нужны ваши домен/учётки).  
Инструкция: `docs/INSTALLATION.md` и https://www.cloudpanel.io/docs/v2/php/applications/wordpress/

## Обновления, бэкапы, восстановление

- Обновления ОС: `docs/MAINTENANCE.md`
- Бэкапы и restore: `docs/BACKUP-AND-RECOVERY.md`
- Типовые ошибки: `docs/TROUBLESHOOTING.md`

## Тесты

```bash
bash tests/shellcheck.sh
bash tests/test-config.sh
```

Тесты проверяют синтаксис, структуру, отказ без `CONFIRM_INSTALL`, матрицу DB engine и поведение на не-Debian.  
Они **не** означают, что CloudPanel установлен на реальном VPS.

## Ограничения автоматизации

- Нет доступа к вашему VPS из среды разработки — полная установка на боевом сервере не имитируется.
- Hostname, SSH и firewall не меняются автоматически.
- Повторная установка поверх частичной — блокируется.
- Администратор CloudPanel создаётся только через официальный UI.
- SHA-256 установщика может измениться у вендора — всегда сверяйте с документацией.

## Лицензия и ответственность

Используйте на свой риск. Следуйте лицензии и условиям CloudPanel. Автор автоматизации не подменяет официальную поддержку вендора.
