# Ручное тестирование AI-DNS

## Русский

`Start-TestSession.ps1` записывает всю тестовую сессию: каждое действие AI-DNS с подробным логом
(`-Trace`), состояние сети до и после него, различия, а также ваши заметки после каждого шага.
Всё сохраняется в `tests\manual\sessions\<дата_время>\`:

| Файл | Что в нём |
|---|---|
| `journal.txt` | Ход сессии: шаги, коды завершения, ваши заметки |
| `transcript.txt` | Всё, что было в окне сессии |
| `00-initial.json`, `99-final.json` | Состояние в начале и в конце |
| `NN-<действие>\before.json`, `after.json` | Состояние до и после шага: DNS всех адаптеров (IPv4 и IPv6, статические и действующие), IPv6, маршруты по умолчанию, NRPT, DoH-шаблоны, политики браузеров, записи `hosts`, папка `%ProgramData%\AIDNS`, `backup.json`, `state.json`, `settings.json`, VPN/zapret-процессы и службы |
| `NN-<действие>\diff.txt` | Что изменилось за шаг |
| `NN-<действие>\logs\` | Подробный лог AI-DNS этого шага |

Папка `sessions` в Git не попадает. В ней есть адреса DNS, имена адаптеров и строки `hosts` вашего
компьютера, поэтому выкладывать её целиком не стоит.

### Запуск

Из обычного (не администраторского) окна PowerShell в папке репозитория:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\manual\Start-TestSession.ps1
```

Сначала скрипт попросит описать обстановку (VPN включён или нет, работает ли zapret, какая сеть).
Затем выбирайте действия цифрами; после каждого скрипт покажет путь к `diff.txt` и спросит, что вы
увидели. `N` добавляет заметку в любой момент, `0` завершает сессию. Действия, которые меняют
систему, как обычно попросят права администратора.

### Сценарии для 3.1.1

Выполняйте по порядку в одной сессии. В скобках номер пункта меню.

1. **Проверка без изменений (5, `Enable -TestOnly`).** Окна UAC быть не должно. В `diff.txt` – «No
   differences.» (папка `%ProgramData%\AIDNS` не создаётся и не меняется).
2. **Пробный запуск (6, `Enable -DryRun`).** Появится UAC. В `diff.txt` могут измениться только
   логи; DNS, политики, NRPT, DoH, `hosts` не меняются.
3. **Включение (1, `Enable`).** Ошибок «Records ... пустая коллекция» нет (issue #1), итог зелёный.
   В `diff.txt`: DNS адаптера, IPv6, восемь политик браузеров, при Windows 11 – DoH-шаблоны. В
   `after.json` в `Backup` у адаптера заполнено `AppliedV4`, у DoH – раздел `Doh`.
4. **Состояние (2, `Status`).** Без UAC. Все обязательные сервисы работают.
5. **Повторное включение (1).** В выводе «Исходная копия от … сохраняется», в `diff.txt` раздел
   `Backup` меняет только `AppliedV4`, если сменился сервер.
6. **Выключение (3, `Disable`).** `diff.txt` возвращает всё, что изменил шаг 3; в `99-final.json`
   состояние совпадает с `00-initial.json` (кроме времени и логов).

Дополнительные проверки владения (нужно администраторское окно PowerShell для подготовки):

7. **Чужая политика браузера.** До шага 3 выполните
   `reg add HKLM\SOFTWARE\Policies\Google\Chrome /v DnsOverHttpsMode /t REG_SZ /d off /f`,
   затем шаги 3 и 6. После Disable значение должно остаться (раньше удалялось). Уберите его потом:
   `reg delete HKLM\SOFTWARE\Policies\Google\Chrome /v DnsOverHttpsMode /f`.
8. **Повреждённый settings.json.** Скопируйте `settings.json` в сторону, запишите в него `{ broken`,
   выполните шаг 5: файл не должен измениться. Затем пункт 8 (`Settings`), измените любую
   настройку: рядом появится `settings.broken-<время>.json`, а `settings.json` станет правильным.
   Верните свою копию.
9. **Повреждённый backup.json.** После шага 3 в администраторском окне выполните
   `Set-Content C:\ProgramData\AIDNS\backup.json '{ broken'`, затем шаг 1. AI-DNS должен
   остановиться и спросить: `Esc` – ничего не меняется; повторите шаг 1 и нажмите `Enter` – файл
   сохраняется как `backup.broken-<время>.json`, работа продолжается. Учтите: исходные настройки
   из повреждённой копии потеряны, после шага 6 адаптер вернётся на DHCP.

Когда закончите, скажите, какую папку сессии смотреть.

## English

`Start-TestSession.ps1` records a manual test session: every AI-DNS action with a trace log, the
network state before and after it, the differences, and the tester's notes, in
`tests\manual\sessions\<date_time>\`. Run it from a normal PowerShell window:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\manual\Start-TestSession.ps1
```

Pick actions by number, add notes with `N`, finish with `0`. The `sessions` folder is ignored by Git
and contains machine details, so do not publish it as is. The scenarios above (TestOnly without
UAC, dry run, enable, status, repeated enable, disable, ownership checks) are the release checklist.
