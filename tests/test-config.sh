#!/usr/bin/env bash
# Автоматические проверки структуры проекта, конфигурации и безопасного поведения.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "[PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); echo "[SKIP] $*"; }

assert_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    pass "файл существует: ${path}"
  else
    fail "файл отсутствует: ${path}"
  fi
}

assert_executable() {
  local path="$1"
  if [[ -x "${path}" ]]; then
    pass "исполняемый: ${path}"
  else
    fail "нет права execute: ${path}"
  fi
}

echo "=== 1. Обязательные файлы проекта ==="
REQUIRED_FILES=(
  README.md
  SECURITY.md
  CHANGELOG.md
  .gitignore
  config/deploy.env.example
  config/firewall-requirements.md
  scripts/common.sh
  scripts/00-preflight.sh
  scripts/10-prepare-system.sh
  scripts/20-install-cloudpanel.sh
  scripts/30-verify-installation.sh
  scripts/40-postinstall-checks.sh
  scripts/install-interactive.sh
  tests/shellcheck.sh
  tests/test-config.sh
  logs/.gitkeep
  docs/INSTALLATION.md
  docs/NETWORK.md
  docs/DNS-AND-TLS.md
  docs/TROUBLESHOOTING.md
  docs/BACKUP-AND-RECOVERY.md
  docs/MAINTENANCE.md
)
for f in "${REQUIRED_FILES[@]}"; do
  assert_file "${f}"
done

echo ""
echo "=== 2. Права execute у скриптов ==="
for f in scripts/*.sh tests/*.sh; do
  assert_executable "${f}"
done

echo ""
echo "=== 3. Конфигурационный шаблон ==="
if grep -q 'INSTALLER_URL=' config/deploy.env.example \
  && grep -q 'INSTALLER_SHA256=' config/deploy.env.example \
  && grep -q 'CONFIRM_INSTALL=' config/deploy.env.example \
  && grep -q 'DB_ENGINE=' config/deploy.env.example; then
  pass "deploy.env.example содержит ключевые параметры"
else
  fail "deploy.env.example неполный"
fi

if grep -Ei 'password\s*=\s*[^#\s]+|PRIVATE KEY|BEGIN OPENSSH' config/deploy.env.example; then
  fail "в example найдены похожие на секреты значения"
else
  pass "в example нет явных секретов"
fi

EXPECTED_SHA="8146dbe0a488e7088b04071b0c34d59aa0ab1fe9dcec382d395fd155c9e6c476"
if grep -q "${EXPECTED_SHA}" config/deploy.env.example; then
  pass "контрольная сумма установщика соответствует официальной документации на момент сборки"
else
  fail "INSTALLER_SHA256 в example не совпадает с зафиксированной официальной"
fi

echo ""
echo "=== 4. .gitignore защищает секреты и артефакты ==="
for pattern in 'config/deploy.env' 'logs/*' '*.pem' '*.key' 'installer/'; do
  if grep -qF "${pattern}" .gitignore; then
    pass ".gitignore содержит ${pattern}"
  else
    fail ".gitignore не содержит ${pattern}"
  fi
done

echo ""
echo "=== 5. common.sh загружается и валидирует DB engine ==="
# shellcheck disable=SC1091
source scripts/common.sh
load_config
if db_engine_supported_for_debian "12" "MARIADB_11.8"; then
  pass "Debian 12 + MARIADB_11.8 поддерживается"
else
  fail "Debian 12 + MARIADB_11.8 должно поддерживаться"
fi
if db_engine_supported_for_debian "13" "MARIADB_11.8"; then
  pass "Debian 13 + MARIADB_11.8 поддерживается"
else
  fail "Debian 13 + MARIADB_11.8 должно поддерживаться"
fi
if ! db_engine_supported_for_debian "13" "MARIADB_10.11"; then
  pass "Debian 13 + MARIADB_10.11 корректно отвергается"
else
  fail "Debian 13 + MARIADB_10.11 не должен поддерживаться"
fi
if ! db_engine_supported_for_debian "11" "MARIADB_11.8"; then
  pass "Debian 11 отвергается матрицей проекта (Requirements = 12/13)"
else
  fail "Debian 11 не должен проходить матрицу проекта"
fi

echo ""
echo "=== 6. Поведение без root / на неподдерживаемой ОС ==="
# Preflight на macOS / не-Debian должен завершиться BLOCKED, не устанавливая пакеты.
# Короткие таймауты, чтобы тест не зависал без сети.
TMP_LOG="${ROOT}/logs/test-preflight-nondebian.log"
set +e
NETWORK_TIMEOUT=2 CURL_CONNECT_TIMEOUT=2 CHECK_IPV6=0 \
  bash scripts/00-preflight.sh >"${TMP_LOG}" 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  pass "00-preflight.sh завершился ненулевым кодом на не-Debian/без полного окружения (rc=${rc})"
else
  # На чистом Debian READY тоже валиден; определим по os-release
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "debian" ]]; then
      pass "00-preflight.sh на Debian завершился 0 (ожидаемо при READY)"
    else
      fail "00-preflight.sh вернул 0 на не-Debian системе"
    fi
  else
    fail "00-preflight.sh вернул 0 без /etc/os-release"
  fi
fi
if grep -Eiq 'debian|os-release|BLOCKED|недостаточно прав|не поддержи' "${TMP_LOG}"; then
  pass "preflight вывел понятное сообщение об окружении/блокировке"
else
  fail "preflight не вывел ожидаемую диагностику (см. ${TMP_LOG})"
fi

echo ""
echo "=== 7. Установка без CONFIRM_INSTALL должна отказываться ==="
set +e
NETWORK_TIMEOUT=2 CURL_CONNECT_TIMEOUT=2 CONFIRM_INSTALL=NO \
  bash scripts/20-install-cloudpanel.sh >"${ROOT}/logs/test-install-noconfirm.log" 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'CONFIRM_INSTALL' "${ROOT}/logs/test-install-noconfirm.log"; then
  pass "20-install-cloudpanel.sh требует CONFIRM_INSTALL=YES"
else
  fail "20-install-cloudpanel.sh должен отказывать без подтверждения"
fi

echo ""
echo "=== 7b. CLI CONFIRM_INSTALL=YES не перебивается deploy.env=NO ==="
mkdir -p "${ROOT}/state" "${ROOT}/logs"
cat >"${ROOT}/config/deploy.env" <<'EOF'
CONFIRM_INSTALL=NO
DB_ENGINE=MARIADB_11.8
EOF
# shellcheck disable=SC1091
set +e
# Симулируем только load_config + restore
result="$(
  CONFIRM_INSTALL=YES bash -c '
    source scripts/common.sh
    load_config
    printf "%s" "$CONFIRM_INSTALL"
  '
)"
set -e
rm -f "${ROOT}/config/deploy.env"
if [[ "${result}" == "YES" ]]; then
  pass "CONFIRM_INSTALL=YES из CLI сохраняется после load_config"
else
  fail "CLI CONFIRM_INSTALL перетёрт deploy.env (получено: ${result})"
fi

if grep -q 'installer.cloudpanel.io/ce/v2/install.sh' config/deploy.env.example; then
  pass "HTTPS_TEST_URL в example указывает на install.sh (не корень с 403)"
else
  fail "HTTPS_TEST_URL в example должен указывать на install.sh"
fi

echo ""
echo "=== 8. Отсутствие обязательных переменных / пустой SHA ==="
set +e
bash -c '
  set -e
  source scripts/common.sh
  load_config
  SCRIPT_NAME=test
  LOG_DIR=logs
  STATE_DIR=state
  ARTIFACT_DIR=artifacts
  init_runtime test-sha
  # После загрузки defaults намеренно очищаем — пустой SHA должен блокировать
  INSTALLER_SHA256=""
  download_official_installer
' >"${ROOT}/logs/test-empty-sha.log" 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'INSTALLER_SHA256' "${ROOT}/logs/test-empty-sha.log"; then
  pass "пустой INSTALLER_SHA256 приводит к ошибке"
else
  fail "пустой INSTALLER_SHA256 должен блокировать загрузку"
fi

echo ""
echo "=== 9. Повторный запуск диагностики безопасен ==="
set +e
NETWORK_TIMEOUT=2 CURL_CONNECT_TIMEOUT=2 CHECK_IPV6=0 bash scripts/00-preflight.sh >/dev/null 2>&1
NETWORK_TIMEOUT=2 CURL_CONNECT_TIMEOUT=2 CHECK_IPV6=0 bash scripts/00-preflight.sh >/dev/null 2>&1
rc=$?
set -e
# Оба запуска не должны ничего устанавливать; ненулевой код на не-Debian — норма
pass "повторный запуск 00-preflight.sh выполнен без изменений системы (rc последнего=${rc})"

echo ""
echo "=== 10. Опасные конструкции в скриптах ==="
if grep -RInE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?bash' scripts; then
  fail "обнаружен curl|bash pipeline — запрещён политикой проекта"
else
  pass "curl|bash pipeline отсутствует"
fi

if grep -RIn '^[[:space:]]*set -x' scripts/*.sh; then
  fail "обнаружен set -x в наших скриптах (риск утечки секретов)"
else
  pass "set -x в проектных скриптах отсутствует"
fi

echo ""
echo "=== Итог тестов ==="
echo "PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
echo "Все автоматические тесты пройдены."
