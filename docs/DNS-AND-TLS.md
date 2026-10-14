# DNS и TLS

## DNS для сайта

1. Создайте A-запись домена на публичный IPv4 сервера.
2. При наличии IPv6 — AAAA на публичный IPv6.
3. Дождитесь распространения DNS: `dig +short example.com`.
4. Убедитесь, что резолвящийся IP совпадает с сервером (учитывайте CDN/прокси).

Не выпускайте Let's Encrypt, пока DNS не указывает на этот сервер и порты 80/443 не открыты снаружи.

## TLS для сайтов

Официально: https://www.cloudpanel.io/docs/v2/frontend-area/tls/

1. В карточке сайта: **Actions → New Let's Encrypt Certificate**.
2. Добавьте домены/алиасы.
3. **Create and Install**.

CLI (после создания сайта):

```bash
clpctl lets-encrypt:install:certificate --domainName=www.example.com
```

Автопродление обрабатывается инфраструктурой CloudPanel/Let's Encrypt — проверяйте обновление сертификата до истечения срока на тестовой среде и по факту в панели.

## TLS для интерфейса CloudPanel

- По IP: self-signed сертификат — ожидаемо.
- Кастомный домен для панели: Admin Area → Settings → General → Domain Name (нужна DNS-запись).  
  Документация: https://www.cloudpanel.io/docs/v2/admin-area/settings/

## Cloudflare

Если используете Cloudflare Proxy, следуйте официальной рекомендации Full SSL и при необходимости ограничьте прямой трафик к origin.
Не храните приватные ключи в Git.
