#!/usr/bin/env bash
# Проверка результата установки CloudPanel без вывода секретов.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

load_config
init_runtime "30-verify-installation"

declare -a VERIFY_OK=()
declare -a VERIFY_FAIL=()
declare -a VERIFY_WARN=()
declare -a DIAG_COMMANDS=()

ok() { VERIFY_OK+=("$*"); log_success "$*"; }
fail() { VERIFY_FAIL+=("$*"); log_error "$*"; }
warn() { VERIFY_WARN+=("$*"); log_warn "$*"; }
hint() { DIAG_COMMANDS+=("$*"); }

check_binaries_and_paths() {
  set_stage "components"
  if [[ -x /usr/bin/clpctl ]]; then
    ok "Найден clpctl: /usr/bin/clpctl"
  else
    fail "clpctl не найден в /usr/bin/clpctl"
    hint "ls -la /usr/bin/clpctl; dpkg -l | grep -i cloudpanel"
  fi

  if [[ -d /home/clp ]]; then
    ok "Каталог /home/clp существует"
  else
    warn "Каталог /home/clp не найден (структура может отличаться между версиями)"
  fi

  # Не утверждаем конкретные unit-имена без проверки фактического состояния
  if have_cmd systemctl; then
    local units
    units="$(systemctl list-unit-files 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /cloudpanel|clp|nginx|mariadb|mysql|php.*fpm/ {print $1}' | head -n 40)"
    if [[ -n "${units}" ]]; then
      ok "Обнаружены связанные unit-файлы"
      printf '%s\n' "${units}" | while read -r u; do
        log_info "unit: ${u}"
      done
    else
      warn "Не удалось сопоставить unit-файлы CloudPanel по имени"
    fi
  fi
}

check_services() {
  set_stage "services"
  if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      ok "Служба nginx активна"
    else
      fail "Служба nginx не активна"
      hint "systemctl status nginx --no-pager"
    fi
  fi

  # MySQL и MariaDB — взаимоисключающие имена
  if systemctl list-unit-files mysql.service >/dev/null 2>&1 && systemctl is-active --quiet mysql; then
    ok "Служба mysql активна"
  elif systemctl list-unit-files mariadb.service >/dev/null 2>&1 && systemctl is-active --quiet mariadb; then
    ok "Служба mariadb активна"
  else
    warn "Не удалось подтвердить активную службу mysql/mariadb"
    hint "systemctl status mysql mariadb --no-pager"
  fi

  local fpm
  fpm="$(systemctl list-units --type=service --all 2>/dev/null | awk '/php.*fpm/ {print $1}' | head -n1 || true)"
  if [[ -n "${fpm}" ]]; then
    if systemctl is-active --quiet "${fpm}"; then
      ok "PHP-FPM активен: ${fpm}"
    else
      warn "PHP-FPM найден, но не активен: ${fpm}"
    fi
  else
    warn "Unit PHP-FPM не обнаружен по шаблону имени"
  fi
}

check_ports() {
  set_stage "ports"
  local port
  for port in "${HTTP_PORT}" "${HTTPS_PORT}" "${CLOUDPANEL_PORT}"; do
    if have_cmd ss && ss -tlnn 2>/dev/null | grep -qE ":${port}\\b"; then
      ok "Порт ${port}/tcp слушается локально"
    elif have_cmd lsof && lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      ok "Порт ${port}/tcp слушается локально"
    else
      fail "Порт ${port}/tcp не слушается"
      hint "ss -tlnp | grep :${port}"
    fi
  done
}

check_local_ui() {
  set_stage "local-ui"
  if ! have_cmd curl; then
    warn "curl отсутствует — локальная проверка UI пропущена"
    return 0
  fi

  local code
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    "https://127.0.0.1:${CLOUDPANEL_PORT}/" 2>/dev/null || echo "000")"
  if [[ "${code}" =~ ^[23] ]]; then
    ok "Локальный UI отвечает HTTPS на 127.0.0.1:${CLOUDPANEL_PORT} (HTTP ${code})"
  elif [[ "${code}" == "000" ]]; then
    fail "Локальный UI недоступен (нет соединения)"
    hint "curl -vk https://127.0.0.1:${CLOUDPANEL_PORT}/"
  else
    warn "Локальный UI вернул HTTP ${code} (возможна страница создания админа / редирект)"
  fi
}

check_firewall_conflict() {
  set_stage "firewall"
  if have_cmd ufw; then
    local st
    st="$(ufw status 2>/dev/null | head -n1 || true)"
    log_info "UFW: ${st}"
    # Важно: "Status: inactive" тоже содержит подстроку "active"
    if echo "${st}" | grep -Eqi 'Status:[[:space:]]+active'; then
      if ! ufw status 2>/dev/null | grep -qE "${CLOUDPANEL_PORT}|Nginx Full|Nginx HTTP|80/tcp|443/tcp"; then
        warn "UFW активен; убедитесь, что порты 80/443/${CLOUDPANEL_PORT} разрешены"
        hint "sudo ufw status verbose"
      else
        ok "UFW активен и содержит связанные правила (проверьте детально)"
      fi
    else
      ok "UFW не активен (или не в состоянии active)"
    fi
  fi

  # Различаем локальный и внешний firewall
  warn "Внешний firewall провайдера этим скриптом не проверяется. Сверьте security group / панель VPS."
  hint "Проверка извне: curl -vk https://<PUBLIC_IP>:${CLOUDPANEL_PORT}/"
}

check_vhost_templates() {
  set_stage "vhost-templates"
  if ! have_cmd clpctl; then
    warn "clpctl нет — проверка шаблонов пропущена"
    return 0
  fi
  local out
  out="$(clpctl vhost-templates:list 2>/dev/null || true)"
  if echo "${out}" | grep -qi 'WordPress'; then
    ok "Vhost-шаблон WordPress присутствует"
  else
    warn "Шаблон WordPress не найден — выполняется импорт"
    if ensure_vhost_templates; then
      ok "Шаблоны импортированы"
    else
      fail "Не удалось импортировать vhost-шаблоны (ошибка создания WordPress Site)"
      hint "sudo clpctl vhost-templates:import"
    fi
  fi
}

check_dns_if_configured() {
  set_stage "dns"
  if [[ -z "${SITE_DOMAIN}" ]]; then
    log_info "SITE_DOMAIN не задан — проверка DNS сайта пропущена"
    return 0
  fi
  if dns_resolves "${SITE_DOMAIN}"; then
    ok "DNS резолвит ${SITE_DOMAIN}"
    local resolved public_ip
    if have_cmd getent; then
      resolved="$(getent ahostsv4 "${SITE_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    else
      resolved=""
    fi
    public_ip="$(detect_public_ipv4)"
    if [[ -n "${resolved}" && -n "${public_ip}" && "${resolved}" != "${public_ip}" ]]; then
      warn "DNS ${SITE_DOMAIN} -> ${resolved}, публичный IP сервера ${public_ip} (возможное несоответствие)"
      hint "dig +short ${SITE_DOMAIN}; dig +short A ${SITE_DOMAIN}"
    fi
  else
    fail "DNS не резолвит SITE_DOMAIN=${SITE_DOMAIN}"
    hint "dig +short ${SITE_DOMAIN}"
  fi
}

check_install_logs() {
  set_stage "install-logs"
  local latest=""
  local candidate
  while IFS= read -r candidate; do
    latest="${candidate}"
    break
  done < <(find "${LOG_DIR}" -maxdepth 1 -type f -name 'cloudpanel-installer_*.log' -print 2>/dev/null | sort -r)

  if [[ -z "${latest}" ]]; then
    warn "Журнал официального установщика не найден в ${LOG_DIR}"
    return 0
  fi
  log_info "Анализ журнала: ${latest}"
  local tmp_errs
  tmp_errs="$(mktemp)"
  if grep -Ei 'error|fatal|failed' "${latest}" | grep -Eiv 'setaf|tput|VERBOSE' | tail -n 20 >"${tmp_errs}" 2>/dev/null; then
    if [[ -s "${tmp_errs}" ]]; then
      warn "В журнале установщика есть строки с error/failed (просмотрите вручную)"
      head -n 10 "${tmp_errs}" | while read -r line; do
        log_warn "installer-log: $(sanitize_for_log "${line}")"
      done
    else
      ok "Критических маркеров в журнале установщика не видно"
    fi
  else
    ok "Критических маркеров в журнале установщика не видно"
  fi
  rm -f "${tmp_errs}"
}

check_php_db_presence() {
  set_stage "php-db"
  if have_cmd php; then
    ok "PHP CLI доступен: $(php -v 2>/dev/null | head -n1)"
  else
    # CloudPanel может не класть php в PATH root — это не всегда ошибка
    warn "php в PATH не найден; проверьте версии PHP через UI CloudPanel"
  fi
  if have_cmd mysql; then
    ok "Клиент mysql/mariadb в PATH доступен"
  else
    warn "Клиент mysql не найден в PATH"
  fi
}

classify_external_access() {
  set_stage "access-classification"
  cat <<EOF

Классификация проблем внешнего доступа (если UI недоступен из браузера):
1) Служба не запущена     -> systemctl status nginx
2) Порт не слушается      -> ss -tlnp | grep -E ':80|:443|:${CLOUDPANEL_PORT}'
3) Локальный firewall     -> sudo ufw status verbose; sudo iptables -L -n
4) Firewall провайдера    -> security group / панель VPS (откройте 80/443; 8443 только для вашего IP)
5) DNS на другой IP       -> dig +short <domain>
6) TLS ещё self-signed    -> ожидаемо для https://IP:8443 до выпуска сертификата
7) NAT/маршрутизация      -> сравните локальный IP и публичный IP

EOF
}

write_verify_report() {
  local status="$1"
  local report="${LOG_DIR}/verify-report_${RUN_ID}.txt"
  {
    echo "CloudPanel Deploy — отчёт проверки установки"
    echo "Время: $(human_time)"
    echo "Итог: ${status}"
    print_report_section "Успешные проверки" "${VERIFY_OK[@]:-}"
    print_report_section "Предупреждения" "${VERIFY_WARN[@]:-}"
    print_report_section "Ошибки" "${VERIFY_FAIL[@]:-}"
    print_report_section "Команды для диагностики" "${DIAG_COMMANDS[@]:-}"
  } | tee "${report}"
  chmod 640 "${report}" || true
  write_state_file "verify.status" "${status}"
  write_state_file "verify.report" "${report}"
}

main() {
  require_root_or_sudo || true
  check_binaries_and_paths
  check_services
  check_ports
  check_local_ui
  check_firewall_conflict
  check_vhost_templates
  check_dns_if_configured
  check_install_logs
  check_php_db_presence
  classify_external_access

  local status
  if [[ ${#VERIFY_FAIL[@]} -gt 0 ]]; then
    status="FAILED"
  elif [[ ${#VERIFY_WARN[@]} -gt 0 ]]; then
    status="PASSED_WITH_WARNINGS"
  else
    status="PASSED"
  fi
  write_verify_report "${status}"

  if [[ "${status}" == "FAILED" ]]; then
    log_error "Проверка не пройдена. Не заявляйте об успешной установке."
    finish_runtime "FAILED"
    exit 1
  fi

  log_success "Проверка завершена: ${status}"
  log_info "Далее: sudo bash ${SCRIPTS_DIR}/40-postinstall-checks.sh"
  log_info "Создайте администратора в UI: https://<IP>:${CLOUDPANEL_PORT}"
  finish_runtime "SUCCESS"
}

main "$@"
