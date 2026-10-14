# Устранение неисправностей

## Preflight = BLOCKED

| Симптом | Действие |
|---------|----------|
| Не Debian / не 12/13 | Переустановите ОС на поддерживаемую версию |
| Мало RAM/диска | Увеличьте ресурсы VPS |
| Заняты 80/443/3306 | Освободите порты на **чистом** сервере; не ставьте поверх рабочей системы |
| Найдены nginx/apache/mysql/docker/панели | Используйте новый VPS; автоудаление запрещено |
| apt занят | Дождитесь завершения; `sudo dpkg --configure -a` |
| Нет DNS/HTTPS | Исправьте resolv.conf / firewall исходящих соединений |

## Установщик не скачивается / SHA mismatch

1. Откройте https://www.cloudpanel.io/docs/v2/getting-started/other/
2. Скопируйте актуальный SHA-256 в `INSTALLER_SHA256`.
3. Проверьте доступность `https://installer.cloudpanel.io/ce/v2/install.sh`.

## Установщик упал посередине

1. **Не** запускайте повторно вслепую.
2. Сохраните `logs/` и `artifacts/`.
3. Выполните `sudo bash scripts/30-verify-installation.sh`.
4. Оцените состояние вручную. Полный откат может быть невозможен — часто проще переустановить ОС.

Статус незавершённой установки хранится в `state/install.status`.

## No space left / пакет cloudpanel в состоянии iF

Типично на диске ~10 GB: установщик пишет «complete», но `dpkg` падает.

1. `df -h /` — освободите место (`apt-get clean`, удалите незавершённые `/home/clp/backups/*`).
2. `dpkg -l cloudpanel` — если не `ii`, устраните причину и `sudo dpkg --configure -a`.
3. При битой SQLite БД панели см. восстановление через `doctrine:schema:update` / переустановку ОС.
4. Рекомендация: VPS ≥20 GB диска и ≥2 GB RAM.

## WordPress: «Шаблон виртуального хоста WordPress не существует»

После частичной установки postinst мог не вызвать импорт шаблонов:

```bash
sudo clpctl vhost-templates:import
sudo bash scripts/30-verify-installation.sh
```

Затем снова создайте сайт в UI.

## CONFIRM_INSTALL=YES игнорируется

Переменные из командной строки имеют приоритет над `deploy.env` (исправлено в common.sh).  
Проверьте: `CONFIRM_INSTALL=YES sudo -E bash scripts/20-install-cloudpanel.sh`  
или задайте `CONFIRM_INSTALL=YES` в `config/deploy.env`.

## UI недоступен извне

Различайте причины:

1. Служба не запущена → `systemctl status nginx`
2. Порт не слушается → `ss -tlnp | grep 8443`
3. Локальный FW → `ufw status verbose`
4. Внешний FW провайдера → security group
5. DNS на другой IP → `dig +short domain`
6. Self-signed TLS → предупреждение браузера нормально для IP:8443
7. NAT → сравните локальный и публичный IP

## Боты создали администратора раньше вас

Ограничьте 8443 немедленно. Если компрометация вероятна — переустановите ОС и панель на чистом VPS, усилив firewall **до** первого открытия 8443 (или сразу после установки через консоль провайдера).

## Повторный запуск install

Если `state/install.status` = `STARTED` или `FINISHED`, скрипт откажется продолжать. Это защита от повторной установки поверх частичного состояния.
