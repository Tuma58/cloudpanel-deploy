# Changelog

## 1.1.0 — 2026-10-14

### Исправлено (уроки с реального VPS)

- CLI-переменные (`CONFIRM_INSTALL=YES` и др.) больше не перезаписываются `deploy.env`.
- HTTPS-проверка по умолчанию идёт на `install.sh` (корень installer отдаёт 403).
- Логи пишутся в stderr, чтобы `$(download_official_installer)` не ломал путь.
- `run_priv` + `DEBIAN_FRONTEND` через `env`.
- Детект частичного сбоя установщика (No space left / dpkg) даже при exit 0.
- Импорт vhost-шаблонов (`clpctl vhost-templates:import`) после install/verify/postinstall.
- Ложное предупреждение UFW на `Status: inactive`.
- Опциональный swap при малом RAM с проверкой запаса диска.

### Добавлено

- `scripts/install-interactive.sh` — установка с вопросами в консоли.
- One-liner в README.

## 1.0.0 — 2026-10-13

### Добавлено

- Комплект автоматизации развёртывания CloudPanel на чистом Debian 12/13.
- Скрипты: preflight, prepare, install, verify, postinstall.
- Общий модуль `scripts/common.sh` (логирование, конфигурация, проверки).
- Конфигурационный шаблон `config/deploy.env.example`.
- Документация на русском: установка, сеть, DNS/TLS, troubleshooting, backup, maintenance.
- Автотесты синтаксиса и конфигурации.

### Основано на официальных источниках

- Requirements: Debian 12, Debian 13; ≥2 GB RAM; ≥10 GB disk; x86/ARM64.
- Installer URL: `https://installer.cloudpanel.io/ce/v2/install.sh`
- SHA-256 (на момент сборки): `8146dbe0a488e7088b04071b0c34d59aa0ab1fe9dcec382d395fd155c9e6c476`
- Порт UI: 8443
