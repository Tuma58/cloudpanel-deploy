#!/usr/bin/env bash
# Пост-установочные проверки безопасности и рекомендации по первоначальной настройке.
# Не создаёт администратора CloudPanel неофициальными способами.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_config
init_runtime "40-postinstall-checks"

print_admin_guidance() {
  set_stage "admin-access"
  local ip
  ip="$(detect_public_ipv4)"
  [[ -z "${ip}" ]] && ip="<PUBLIC_IP>"

  cat <<EOF

=== Административный доступ CloudPanel ===
Официальный способ создания администратора — через веб-интерфейс сразу после установки:
  https://${ip}:${CLOUDPANEL_PORT}

Важно (официальная документация):
- Есть окно, в котором боты могут создать пользователя первыми.
- Как можно быстрее откройте UI и создайте администратора.
- По возможности откройте порт ${CLOUDPANEL_PORT} только для вашего IP.

Этот скрипт НЕ создаёт админа через SQL или правку внутренней БД.
Не передавайте пароли в аргументах командной строки и не пишите их в журналы.

Если порт ${CLOUDPANEL_PORT} нельзя ограничить по IP — включите Basic Auth в CloudPanel
(Security -> Basic Auth) или через официальный clpctl после создания админа
(пароль вводите интерактивно / из защищённого ввода, не оставляйте в истории shell).

Документация: ${OFFICIAL_DOCS_SECURITY}

EOF
}

print_port_matrix() {
  set_stage "ports-matrix"
  cat <<EOF

=== Матрица портов ===
Порт/протокол     Назначение                 Где открывать                 Кому
${SSH_PORT}/tcp           SSH                        Провайдер + локальный FW     Только ваш IP / VPN
${HTTP_PORT}/tcp           HTTP (сайты, ACME)         Провайдер + локальный FW     Публично (для сайтов)
${HTTPS_PORT}/tcp          HTTPS / HTTP3(UDP 443*)    Провайдер + локальный FW     Публично (для сайтов)
${CLOUDPANEL_PORT}/tcp         CloudPanel Admin UI       Провайдер + локальный FW     Только ваш IP

* UDP/443 нужен для HTTP/3 при использовании QUIC (рекомендация CloudPanel для облачных SG).

НЕ открывайте все порты «на всякий случай».
НЕ блокируйте текущую SSH-сессию без консоли провайдера.

Подробности: ${CONFIG_DIR}/firewall-requirements.md и docs/NETWORK.md

EOF

  if [[ -n "${ADMIN_SOURCE_IP}" ]]; then
    log_info "Рекомендуемое ограничение 8443 для ADMIN_SOURCE_IP=${ADMIN_SOURCE_IP}"
    log_warn "Автоматическое изменение firewall НЕ выполняется этим скриптом."
    cat <<EOF
Пример для панели провайдера / security group:
  Allow TCP ${CLOUDPANEL_PORT} from ${ADMIN_SOURCE_IP}/32
  Allow TCP ${SSH_PORT} from ${ADMIN_SOURCE_IP}/32
  Allow TCP ${HTTP_PORT},${HTTPS_PORT} from 0.0.0.0/0 (и ::/0 при IPv6)

Если используете встроенный UFW CloudPanel — настраивайте правила в UI Security,
предварительно сохранив доступ через консоль VPS.

EOF
  else
    log_warn "ADMIN_SOURCE_IP не задан — укажите его в deploy.env для адресных рекомендаций."
  fi
}

check_tls_guidance() {
  set_stage "tls"
  cat <<EOF

=== SSL/TLS ===
1) Интерфейс CloudPanel по IP использует self-signed сертификат — это ожидаемо.
2) Для сайта WordPress выпускайте Let's Encrypt только после того, как DNS A/AAAA
   указывает на IP этого сервера и порты 80/443 доступны извне.
3) В UI сайта: Actions -> New Let's Encrypt Certificate.
   CLI (после создания сайта): clpctl lets-encrypt:install:certificate --domainName=www.example.com
4) Не отключайте проверку сертификатов в клиентах администрирования без необходимости.
5) Приватные ключи не сохраняйте в Git и в журналах проекта.

Документация: ${OFFICIAL_DOCS_TLS}

EOF

  if [[ -n "${SITE_DOMAIN}" ]]; then
    if dns_resolves "${SITE_DOMAIN}"; then
      log_info "SITE_DOMAIN=${SITE_DOMAIN} резолвится. Перед выпуском сертификата проверьте, что IP совпадает с сервером."
    else
      log_warn "SITE_DOMAIN=${SITE_DOMAIN} пока не резолвится — выпуск сертификата преждевременен."
    fi
  fi
}

check_system_security() {
  set_stage "system-security"

  if [[ -f /var/run/reboot-required ]]; then
    log_warn "Требуется перезагрузка для применения обновлений."
  else
    log_info "Флаг reboot-required отсутствует."
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -Eq '^PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config; then
      log_warn "PasswordAuthentication yes — рассмотрите ключи SSH и отключение паролей после проверки доступа."
    fi
    if grep -Eq '^PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config; then
      log_warn "PermitRootLogin yes — усильте политику после настройки ключей и консоли провайдера."
    fi
    log_info "Параметры SSH только проверяются, не изменяются."
  fi

  local fw_managers=0
  have_cmd ufw && fw_managers=$((fw_managers + 1))
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    fw_managers=$((fw_managers + 1))
    log_warn "Обнаружен firewalld. Не управляйте двумя firewall одновременно с UFW CloudPanel."
  fi
  log_info "Обнаружено менеджеров firewall (грубая оценка): ${fw_managers}"

  if have_cmd timedatectl; then
    local sync
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
    log_info "NTPSynchronized=${sync}"
  fi

  find "${LOG_DIR}" -type f -exec chmod 640 {} \; 2>/dev/null || true
  chmod 750 "${LOG_DIR}" "${STATE_DIR}" "${ARTIFACT_DIR}" 2>/dev/null || true
  log_info "Права на журналы/состояние проверены (750/640)."

  # Поиск очевидных секретов в tracked-конфигах проекта
  if grep -RInE 'password\s*=\s*[^#]+|BEGIN (RSA |OPENSSH )?PRIVATE KEY' \
    "${CONFIG_DIR}" --exclude="*.example" 2>/dev/null | grep -v 'REDACTED' | grep -q .; then
    log_error "Возможные секреты в config/. Удалите их из файлов и из истории Git."
  else
    log_info "В config/ явных секретов не обнаружено (базовая эвристика)."
  fi

  if cloudpanel_apparently_installed; then
    log_info "Признаки CloudPanel присутствуют — настройте Remote Backups в панели."
  fi

  # Лишние публичные службы
  if have_cmd ss; then
    local odd
    odd="$(ss -tlnn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(21|23|25|110|143|3306)\\b' || true)"
    if echo "${odd}" | grep -q ':3306'; then
      log_warn "MySQL/MariaDB слушает порт 3306. Убедитесь, что он не открыт во внешнем firewall."
    fi
  fi
}

print_wordpress_next_steps() {
  set_stage "wordpress-guidance"
  cat <<EOF

=== Подготовка WordPress (вручную через CloudPanel) ===
1. Создайте сайт: + Add Site -> Create a WordPress Site
2. Укажите домен, title, admin user/password/email
3. PHP выбирается мастером CloudPanel / может быть изменён позже в настройках сайта
4. БД и пользователь создаются панелью автоматически для WordPress Site
5. Выпустите Let's Encrypt после корректного DNS
6. Работайте с файлами от site user, не от root
7. Включите автообновления WordPress/плагинов осознанно
8. Настройте Remote Backups вне этого VPS
9. Проверьте сайт извне по HTTPS

Официально: ${OFFICIAL_DOCS_WORDPRESS}
Локально: ${DOCS_DIR}/INSTALLATION.md (раздел WordPress)

EOF
}

write_postinstall_report() {
  local report="${LOG_DIR}/postinstall-report_${RUN_ID}.txt"
  {
    echo "CloudPanel Deploy — пост-установочный отчёт"
    echo "Время: $(human_time)"
    echo "Предупреждения: ${#WARNINGS[@]}"
    echo "Ошибки: ${#ERRORS[@]}"
    print_report_section "Предупреждения" "${WARNINGS[@]:-}"
    print_report_section "Ошибки" "${ERRORS[@]:-}"
  } | tee "${report}"
  chmod 640 "${report}" || true
  write_state_file "postinstall.report" "${report}"
}

ensure_templates_for_wordpress() {
  set_stage "vhost-templates"
  if cloudpanel_apparently_installed && have_cmd clpctl; then
    local listed
    listed="$(clpctl vhost-templates:list 2>/dev/null || true)"
    if ! echo "${listed}" | grep -qi 'WordPress'; then
      log_warn "Шаблон WordPress отсутствует — импортируем (типичный сбой после нехватки диска)."
      ensure_vhost_templates || log_error "Импорт шаблонов не удался. Выполните: clpctl vhost-templates:import"
    else
      log_info "Шаблон WordPress уже есть в CloudPanel."
    fi
  fi
}

main() {
  require_root_or_sudo || true
  print_admin_guidance
  print_port_matrix
  check_tls_guidance
  check_system_security
  ensure_templates_for_wordpress
  print_wordpress_next_steps
  write_postinstall_report

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log_error "Пост-проверка завершена с ошибками."
    finish_runtime "FAILED"
    exit 1
  fi
  log_success "Пост-проверка завершена. Создайте администратора в UI и ограничьте порт ${CLOUDPANEL_PORT}."
  finish_runtime "SUCCESS"
}

main "$@"
