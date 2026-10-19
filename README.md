<div align="center">

# ai-dns

**Find a working smart DNS for ChatGPT, Claude and Gemini with a double click, and roll it back exactly**
<br>
**Подбор рабочего smart DNS для ChatGPT, Claude и Gemini двойным щелчком с точным откатом**

[![CI](https://img.shields.io/github/actions/workflow/status/Mahiron-hq/ai-dns/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/Mahiron-hq/ai-dns/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-green?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen?style=flat-square)](#)

**[English](#-english)** · **[Русский](#-русский)**

</div>

---

## 🇬🇧 English

A smart DNS answers requests for geo-restricted services with the address of its own proxy, so
ChatGPT, Claude and Gemini see the proxy's region instead of yours. There are many such resolvers
and they come and go. ai-dns tests all known resolvers in a few seconds, checks every service through
the proxy it actually returns and applies the best one. The settings that existed before the first
change are saved and restored exactly.

> **Before you start.** A resolver you set as system DNS sees every domain you visit. DNS changes the
> region a service sees, not your account: an account that was blocked stays blocked. When the
> provider resets TLS connections by site name (DPI filtering), no DNS can help, and ai-dns says so.

### Scripts

| Script | What it does |
|---|---|
| `AI-DNS-Enable.bat` | Tests the resolvers, applies the best one with a fallback and verifies the result |
| `AI-DNS-Disable.bat` | Restores the saved settings and removes every trace of ai-dns |
| `AI-DNS-Update.bat` | Full rollback, then removes the cached lists and compiled engine, then selects a resolver from scratch with freshly downloaded lists |

### Usage

1. Download the repository (**Code → Download ZIP**) and keep all files in one folder.
2. Double-click the `.bat` you need.
3. Confirm administrator rights.
4. Restart the browser after the script finishes.

Run `AI-DNS-Enable.bat` again whenever a service stops opening, or `AI-DNS-Update.bat` to start over
from a clean state. The window closes 20 seconds after success; press any key to close it earlier.

#### From PowerShell

```powershell
.\AI-DNS.ps1 -Action Enable -TestOnly      # rank the resolvers, change nothing
.\AI-DNS.ps1 -Action Enable                # apply the best resolver
.\AI-DNS.ps1 -Action Update                # roll back, clear caches, enable from scratch
.\AI-DNS.ps1 -Action Disable -Full         # roll back and clean up as much as possible
```

The `.bat` files pass their arguments through, so `AI-DNS-Enable.bat -TestOnly` also works.

### Options

| Option | Applies to | Effect |
|---|---|---|
| `-TestOnly` | Enable | Rank the resolvers and stop without changing anything |
| `-DryRun` | all | Perform every check, but only log the changes instead of making them |
| `-Trace` | all | Log every DNS query, HTTPS check and change with its state before and after |
| `-Offline` | Enable, Update | Do not download provider lists; use the bundled list and the cache |
| `-Full` | Disable, Update | Reset all adapters to DHCP, delete the commented-out hosts entries, remove the data directory even after errors |
| `-EnableIPv6` | Disable, Update | Enable IPv6 on every adapter, not only where ai-dns turned it off |
| `-ResetNetwork` | Disable | Also reset Winsock and TCP/IP; a restart is required |
| `-Language en\|ru` | all | Console language; by default it follows the Windows UI language |
| `-LogDirectory <path>` | all | Where to write the log; the default is `%ProgramData%\AIDNS\logs` |
| `-NoWait` | all | Close the window as soon as the action finishes |

### How it works

1. **Provider lists.** The bundled [`src/providers.json`](src/providers.json) is merged with two
   remote lists: this repository's own `providers.json` and the community list of
   [DnsSwitch](https://github.com/WhIteGh0s1/DnsSwitch). Each is downloaded from GitHub with a
   jsDelivr mirror, cached for 6 hours, and the old copy is used when a download fails. Entries that
   share an address or host are folded into one provider.
2. **Discovery.** The current addresses of every provider are resolved from its host names and DoH
   host names through public resolvers, so a provider that moves to new servers is still found.
3. **Reference answers.** Every service is resolved through Yandex, Google and Cloudflare DNS to know
   its real addresses and tell a proxy from a direct answer.
4. **DNS poll.** All candidates are queried in one batch from a single UDP socket. The whole poll is
   bounded by two 1.5 s rounds, however many resolvers are dead.
5. **HTTPS checks.** Each service is opened through the address the resolver returned: the
   Cloudflare region from `/cdn-cgi/trace`, the answers of the OpenAI, Anthropic and Gemini APIs to a
   dummy key, transfers that stall half-way (DPI throttling), TLS resets by site name and forged
   certificates. Certificates are always validated; nothing is sent over an unvalidated connection.
6. **Selection.** Resolvers are ranked by the services they open, then by DNS and TLS latency. The
   best becomes the primary, the next one that opens the same services becomes the secondary.
   Services the primary cannot open are routed to another resolver through NRPT.
7. **Application and verification.** After the changes below, the DNS cache is flushed and every
   service is checked again through the system resolver, exactly as applications see it.

If no resolver works, nothing is applied, and an adapter that still points at a dead smart DNS is
returned to its original resolvers.

### What changes on the system

| Setting | Enable | Disable |
|---|---|---|
| IPv4 DNS of physical adapters with a gateway | primary + secondary resolver | the saved servers, or DHCP |
| IPv6 on those adapters | turned off, so ISP AAAA answers cannot bypass the proxy | turned back on where ai-dns turned it off |
| NRPT rules (comment `AIDNS`) | per-service routing when needed | removed |
| Windows DoH templates (Windows 11) | added for resolvers that serve DoH, with UDP fallback | removed |
| Chrome, Edge, Brave and Firefox policies | built-in secure DNS off | the saved values are written back |
| `hosts` entries for the services | commented out with `# AIDNS-disabled:` | uncommented (deleted with `-Full`) |
| `%ProgramData%\AIDNS` | backup, state, cache, logs | removed |

The backup is written once, before the first change, and repeated enables never overwrite it. VPN
and virtual adapters are not touched. The data directory is restricted to administrators, because
it holds a compiled assembly loaded by an elevated process and the backup that drives registry
restores. Backups written by version 2.x are read as well.

### Providers

The bundled list contains Comss.one, GeoHide (Russia, EU, US), Zapret DNS, DNS-AI, Malw.link,
Astracat, Mafioznik, XyZ DNS, Bez mezhau, WebShift DNS, Xbox DNS, a community pool of gateways and
the Iranian anti-sanction resolvers Shecan, Begzar and Electro: 57 addresses in total. Resolvers that
do not answer or do not open any service are filtered out automatically, so the list errs on the side
of completeness.

To add or update a provider, edit [`src/providers.json`](src/providers.json). The format is described
by [`src/providers.schema.json`](src/providers.schema.json) and checked in CI. Every installed copy
picks up the change from the repository within 6 hours, without a new release.

### Testing

`tests/manual` contains copies of the three scripts for manual testing. Every copy writes a detailed
log to `tests/manual/logs`:

| Copy | Changes settings | Log |
|---|---|---|
| `AI-DNS-*-Trace.bat` | yes | every query, check and change with before and after state |
| `AI-DNS-*-DryRun.bat` | no, changes are only logged | the same, with `[dry run]` for each skipped change |

The automated tests in `tests/*.Tests.ps1` use [Pester 5](https://pester.dev) and never touch
network settings:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\tests
```

### Requirements

- Windows 10 or 11 (Home included)
- Windows PowerShell 5.1 and .NET Framework 4.7 or later (both ship with Windows)
- An administrator account

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failure, details are shown in the window and the log |
| 2 | No resolver currently opens any of the services; nothing was changed |
| 3 | Finished with problems, see the warnings |
| 1223 | The elevation prompt was cancelled, nothing was changed |

---

## 🇷🇺 Русский

Smart DNS отвечает на запросы к сервисам с региональными ограничениями адресом своего прокси, и
ChatGPT, Claude и Gemini видят регион прокси, а не ваш. Таких серверов много, и они постоянно
появляются и исчезают. ai-dns за несколько секунд проверяет все известные серверы, открывает каждый
сервис через прокси, который сервер действительно выдаёт, и включает лучший. Настройки, которые были
до первого изменения, сохраняются и восстанавливаются в точности.

> **Перед началом.** Сервер, выбранный системным DNS, видит все домены, которые вы открываете. DNS
> меняет регион, который видит сервис, но не ваш аккаунт: заблокированный аккаунт останется
> заблокированным. Если провайдер сбрасывает TLS-соединения по имени сайта (фильтрация ТСПУ), DNS не
> поможет, и ai-dns прямо об этом сообщит.

### Скрипты

| Скрипт | Что делает |
|---|---|
| `AI-DNS-Enable.bat` | Проверяет серверы, включает лучший с резервным и проверяет результат |
| `AI-DNS-Disable.bat` | Восстанавливает сохранённые настройки и удаляет все следы ai-dns |
| `AI-DNS-Update.bat` | Полный откат, затем удаление кэша списков и собранного модуля, затем подбор с нуля по свежим спискам |

### Использование

1. Скачайте репозиторий (**Code → Download ZIP**) и сохраните все файлы в одну папку.
2. Запустите нужный `.bat` двойным щелчком.
3. Подтвердите права администратора.
4. После завершения перезапустите браузер.

Если сервис перестал открываться, снова запустите `AI-DNS-Enable.bat`, а чтобы начать с чистого
состояния, запустите `AI-DNS-Update.bat`. После успешного завершения окно закрывается через 20 секунд,
любая клавиша закрывает его сразу.

#### Запуск из PowerShell

```powershell
.\AI-DNS.ps1 -Action Enable -TestOnly      # проверить серверы, ничего не меняя
.\AI-DNS.ps1 -Action Enable                # включить лучший сервер
.\AI-DNS.ps1 -Action Update                # откат, очистка кэшей, подбор с нуля
.\AI-DNS.ps1 -Action Disable -Full         # откат с максимальной очисткой
```

`.bat`-файлы передают аргументы дальше, поэтому `AI-DNS-Enable.bat -TestOnly` тоже работает.

### Ключи

| Ключ | Для чего | Действие |
|---|---|---|
| `-TestOnly` | Enable | Проверить и упорядочить серверы, ничего не меняя |
| `-DryRun` | все | Выполнить все проверки, но изменения только записать в лог |
| `-Trace` | все | Записывать в лог каждый DNS-запрос, HTTPS-проверку и изменение с состоянием до и после |
| `-Offline` | Enable, Update | Не скачивать списки провайдеров, использовать встроенный список и кэш |
| `-Full` | Disable, Update | Сбросить все адаптеры на DHCP, удалить закомментированные записи hosts, удалить служебную папку даже после ошибок |
| `-EnableIPv6` | Disable, Update | Включить IPv6 на всех адаптерах, а не только там, где его выключил ai-dns |
| `-ResetNetwork` | Disable | Дополнительно сбросить Winsock и TCP/IP, потребуется перезагрузка |
| `-Language en\|ru` | все | Язык сообщений, по умолчанию берётся из языка Windows |
| `-LogDirectory <путь>` | все | Куда писать лог, по умолчанию `%ProgramData%\AIDNS\logs` |
| `-NoWait` | все | Закрыть окно сразу после завершения |

### Как это работает

1. **Списки провайдеров.** Встроенный [`src/providers.json`](src/providers.json) объединяется с
   двумя удалёнными списками: `providers.json` из этого репозитория и общим списком
   [DnsSwitch](https://github.com/WhIteGh0s1/DnsSwitch). Каждый скачивается с GitHub с зеркалом
   jsDelivr и хранится в кэше 6 часов, а при неудачной загрузке используется старая копия. Записи с
   общим адресом или именем объединяются в одного провайдера.
2. **Поиск адресов.** Актуальные адреса каждого провайдера узнаются по его именам и именам DoH через
   публичные DNS, поэтому провайдер, переехавший на новые серверы, всё равно будет найден.
3. **Эталонные ответы.** Каждый сервис разрешается через DNS Яндекса, Google и Cloudflare, чтобы
   знать его настоящие адреса и отличать прокси от прямого ответа.
4. **Опрос DNS.** Все кандидаты опрашиваются одним пакетом с одного UDP-сокета. Весь опрос занимает
   не больше двух раундов по 1,5 секунды, сколько бы серверов ни было недоступно.
5. **HTTPS-проверки.** Каждый сервис открывается по адресу, который выдал сервер. Проверяются регион
   Cloudflare из `/cdn-cgi/trace`, ответы API OpenAI, Anthropic и Gemini на фиктивный ключ, передачи,
   застревающие на середине (замедление ТСПУ), сбросы TLS по имени сайта и подменённые сертификаты.
   Сертификаты проверяются всегда, по непроверенному соединению ничего не отправляется.
6. **Выбор.** Серверы упорядочиваются по числу открываемых сервисов, затем по задержке DNS и TLS.
   Лучший становится основным, следующий, открывающий те же сервисы, становится резервным. Сервисы,
   которые основной не открывает, направляются на другой сервер через NRPT.
7. **Применение и проверка.** После изменений из таблицы ниже DNS-кэш очищается, и каждый сервис
   проверяется ещё раз через системный DNS, то есть так, как его видят приложения.

Если ни один сервер не работает, ничего не применяется. Адаптер, который всё ещё указывает на
неработающий smart DNS, возвращается к исходным серверам.

### Что меняется в системе

| Настройка | Enable | Disable |
|---|---|---|
| IPv4 DNS физических адаптеров со шлюзом | основной и резервный сервер | сохранённые серверы или DHCP |
| IPv6 на этих адаптерах | выключается, чтобы AAAA-ответы провайдера не шли в обход прокси | включается там, где его выключил ai-dns |
| Правила NRPT (комментарий `AIDNS`) | маршрутизация отдельных сервисов при необходимости | удаляются |
| Шаблоны DoH Windows (Windows 11) | добавляются для серверов с DoH, с откатом на UDP | удаляются |
| Политики Chrome, Edge, Brave и Firefox | встроенный «безопасный DNS» выключен | возвращаются сохранённые значения |
| Записи `hosts` для сервисов | комментируются меткой `# AIDNS-disabled:` | раскомментируются (с `-Full` удаляются) |
| `%ProgramData%\AIDNS` | копия, состояние, кэш, логи | удаляется |

Резервная копия записывается один раз, перед первым изменением, и повторные запуски её не
перезаписывают. VPN и виртуальные адаптеры не затрагиваются. Доступ к служебной папке есть только у
администраторов: в ней лежат собранная сборка, которую загружает процесс с повышенными правами, и
копия, по которой восстанавливается реестр. Копии версии 2.x тоже читаются.

### Провайдеры

Встроенный список включает Comss.one, GeoHide (Россия, Европа, США), Zapret DNS, DNS-AI, Malw.link,
Astracat, Mafioznik, XyZ DNS, Bez mezhau, WebShift DNS, Xbox DNS, общий пул шлюзов и иранские
антисанкционные Shecan, Begzar и Electro, всего 57 адресов. Серверы, которые не отвечают или не
открывают ни одного сервиса, отсеиваются автоматически, поэтому список составлен с запасом.

Чтобы добавить или обновить провайдера, отредактируйте [`src/providers.json`](src/providers.json).
Формат описан в [`src/providers.schema.json`](src/providers.schema.json) и проверяется в CI. Все
установленные копии подхватят изменение из репозитория в течение 6 часов, без нового релиза.

### Тестирование

В `tests/manual` лежат копии трёх скриптов для ручной проверки. Каждая пишет подробный лог в
`tests/manual/logs`:

| Копия | Меняет настройки | Лог |
|---|---|---|
| `AI-DNS-*-Trace.bat` | да | каждый запрос, проверка и изменение с состоянием до и после |
| `AI-DNS-*-DryRun.bat` | нет, изменения только записываются | то же, каждое пропущенное изменение помечено `[пробный запуск]` |

Автотесты в `tests/*.Tests.ps1` написаны на [Pester 5](https://pester.dev) и сетевые настройки не
трогают:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\tests
```

### Требования

- Windows 10 или 11 (включая Home)
- Windows PowerShell 5.1 и .NET Framework 4.7 или новее (входят в систему)
- Учётная запись администратора

### Коды завершения

| Код | Значение |
|---|---|
| 0 | Успешно |
| 1 | Ошибка, подробности в окне и в логе |
| 2 | Сейчас ни один сервер не открывает ни один из сервисов, ничего не изменено |
| 3 | Завершено с замечаниями, см. предупреждения |
| 1223 | Запрос прав администратора отменён, ничего не изменено |

---

## License / Лицензия

[Apache License 2.0](LICENSE). Copyright 2026 Lev Burmistrov (Mahiron-hq).
