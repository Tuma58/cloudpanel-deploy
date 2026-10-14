#!/usr/bin/env bash
# Интерактивная установка CloudPanel на чистый Debian VPS.
# Запуск: sudo bash scripts/install-interactive.sh
# Отвечает на ключевые вопросы в консоли и выполняет 00→10→20→30→40.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ask() {
  local prompt="$1"
  local default="${2:-}"
  local reply
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " reply || true
    printf '%s' "${reply:-${default}}"
  else
    read -r -p "${prompt}: " reply || true
    printf '%s' "${reply}"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply
  reply="$(ask "${prompt} (y/N)" "${default}")"
  case "$(printf '%s' "${reply}" | tr '[:upper:]' '[:lower:]')" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

require_root_or_sudo || exit 1

cat <<'EOF'

╔══════════════════════════════════════════════════════════╗
║   CloudPanel Deploy — интерактивная установка (Debian)  ║
╚══════════════════════════════════════════════════════════╝

Требования: чистый Debian 12/13, x86_64 или ARM64, ≥2 GB RAM, ≥10 GB диск
            (рекомендуется ≥20 GB диска). Официальный установщик необратим.

EOF

if ! ask_yes_no "Сервер чистый и это поддерживаемый Debian VPS? Продолжить" "N"; then
  echo "Отменено."
  exit 0
fi

mkdir -p "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_DIR}/deploy.env" ]]; then
  cp "${CONFIG_DIR}/deploy.env.example" "${CONFIG_DIR}/deploy.env"
  echo "Создан config/deploy.env из example."
fi

echo ""
echo "Движок БД для Debian 12/13:"
echo "  1) MARIADB_11.8  (рекомендуется для WordPress)"
echo "  2) MARIADB_12.3"
echo "  3) MYSQL_8.4"
echo "  4) MYSQL_8.0"
db_choice="$(ask "Выбор" "1")"
case "${db_choice}" in
  2) DB_ENGINE="MARIADB_12.3" ;;
  3) DB_ENGINE="MYSQL_8.4" ;;
  4) DB_ENGINE="MYSQL_8.0" ;;
  *) DB_ENGINE="MARIADB_11.8" ;;
esac

SITE_DOMAIN="$(ask "Домен будущего сайта (можно пусто)" "")"
ADMIN_SOURCE_IP="$(ask "Ваш IP для ограничения 8443 (можно пусто)" "")"

if ask_yes_no "Выполнить apt upgrade перед установкой" "Y"; then
  APPLY_SECURITY_UPDATES="YES"
else
  APPLY_SECURITY_UPDATES="NO"
fi

if ask_yes_no "Разрешить reboot после upgrade, если система потребует" "N"; then
  CONFIRM_REBOOT="YES"
else
  CONFIRM_REBOOT="NO"
fi

echo ""
echo "Будет установлено:"
echo "  DB_ENGINE=${DB_ENGINE}"
echo "  SITE_DOMAIN=${SITE_DOMAIN:-"(не задан)"}"
echo "  ADMIN_SOURCE_IP=${ADMIN_SOURCE_IP:-"(не задан)"}"
echo "  APPLY_SECURITY_UPDATES=${APPLY_SECURITY_UPDATES}"
echo "  CONFIRM_REBOOT=${CONFIRM_REBOOT}"
echo ""

if ! ask_yes_no "Подтверждаете установку CloudPanel (необратимо)" "N"; then
  echo "Отменено. Можно сначала запустить только диагностику:"
  echo "  sudo bash ${SCRIPTS_DIR}/00-preflight.sh"
  exit 0
fi

# Записать ответы в deploy.env (без секретов)
{
  echo "PROJECT_NAME=\"cloudpanel-deploy\""
  echo "DB_ENGINE=\"${DB_ENGINE}\""
  echo "SITE_DOMAIN=\"${SITE_DOMAIN}\""
  echo "ADMIN_SOURCE_IP=\"${ADMIN_SOURCE_IP}\""
  echo "APPLY_SECURITY_UPDATES=\"${APPLY_SECURITY_UPDATES}\""
  echo "CONFIRM_REBOOT=\"${CONFIRM_REBOOT}\""
  echo "CONFIRM_INSTALL=\"YES\""
  echo "ENSURE_SWAP=\"YES\""
  echo "HTTPS_TEST_URL=\"https://installer.cloudpanel.io/ce/v2/install.sh\""
  echo "INSTALLER_URL=\"https://installer.cloudpanel.io/ce/v2/install.sh\""
  echo "INSTALLER_SHA256=\"${INSTALLER_SHA256}\""
} >"${CONFIG_DIR}/deploy.env"
chmod 600 "${CONFIG_DIR}/deploy.env"

export CONFIRM_INSTALL=YES
export DB_ENGINE APPLY_SECURITY_UPDATES CONFIRM_REBOOT SITE_DOMAIN ADMIN_SOURCE_IP

echo ""
echo "==> 00-preflight.sh"
bash "${SCRIPTS_DIR}/00-preflight.sh"

echo ""
echo "==> 10-prepare-system.sh"
bash "${SCRIPTS_DIR}/10-prepare-system.sh"

echo ""
echo "==> 20-install-cloudpanel.sh"
bash "${SCRIPTS_DIR}/20-install-cloudpanel.sh"

echo ""
echo "==> 30-verify-installation.sh"
bash "${SCRIPTS_DIR}/30-verify-installation.sh"

echo ""
echo "==> 40-postinstall-checks.sh"
bash "${SCRIPTS_DIR}/40-postinstall-checks.sh"

ip="$(detect_public_ipv4)"
[[ -z "${ip}" ]] && ip="<PUBLIC_IP>"

cat <<EOF

══════════════════════════════════════════════════════════
Установка завершена (проверьте отчёты выше на WARN/ERROR).

Откройте сейчас: https://${ip}:8443
Создайте администратора и ограничьте порт 8443 вашим IP.
══════════════════════════════════════════════════════════
EOF
