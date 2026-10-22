AI-DNS {version}
Smart DNS for ChatGPT, Claude and Gemini on Windows 10 and 11.
https://github.com/Mahiron-hq/ai-dns

English
=======

Install
1. Right-click the downloaded ZIP, open Properties, tick "Unblock" and press OK.
   Without this, Windows asks for confirmation before every .bat file.
2. Extract the archive to a folder that will stay where it is, for example C:\Tools\ai-dns.
3. Double-click AI-DNS-Enable.bat and allow administrator rights.
4. Restart the browser.

Files
  AI-DNS-Enable.bat     finds the best smart DNS and applies it
  AI-DNS-Disable.bat    restores the original settings and removes every trace
  AI-DNS-Update.bat     rolls back, clears the caches and selects again from scratch
  AI-DNS-Settings.bat   settings: required services, own domains, default switches
  AI-DNS.ps1, src\      the program itself; keep them next to the .bat files

New version
  Extract the new archive into the same folder and replace the files.
  Your settings.json is not part of the archive and stays as it is.

Uninstall
  Run AI-DNS-Disable.bat, then delete the folder.


Русский
=======

Установка
1. Нажмите правой кнопкой на скачанный ZIP, откройте «Свойства», отметьте «Разблокировать»
   и нажмите OK. Иначе Windows будет спрашивать подтверждение перед каждым .bat-файлом.
2. Распакуйте архив в папку, которая не будет перемещаться, например C:\Tools\ai-dns.
3. Запустите AI-DNS-Enable.bat двойным щелчком и разрешите права администратора.
4. Перезапустите браузер.

Файлы
  AI-DNS-Enable.bat     находит лучший smart DNS и включает его
  AI-DNS-Disable.bat    возвращает исходные настройки и удаляет все следы
  AI-DNS-Update.bat     откатывает, очищает кэши и подбирает заново с нуля
  AI-DNS-Settings.bat   настройки: обязательные сервисы, свои домены, ключи по умолчанию
  AI-DNS.ps1, src\      сама программа; держите их рядом с .bat-файлами

Новая версия
  Распакуйте новый архив в ту же папку с заменой файлов.
  Ваш settings.json в архив не входит и останется как есть.

Удаление
  Запустите AI-DNS-Disable.bat, затем удалите папку.
