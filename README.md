# Meetings — `c51.meetings`

Ein MeetingBar-Ersatz für Omarchy. Drei Dinge:

- ein **Bar-Widget**, das den nächsten Google-Kalender-Termin zeigt (`󰃭 14:00 Standup · 12m`) —
  Linksklick öffnet die Agenda, Rechts- oder Mittelklick holt die Termine neu; **kein** Klick löst
  den Vollbild-Alarm aus (mehr dazu im Mouseover-Tooltip),
- ein **Agenda-Popup** unter dem Bar-Eintrag: Zeitleiste, `HEUTE`, `MORGEN`, Fußzeile mit
  Aktionen — die Liste, die man von MeetingBar unter macOS kennt,
- ein **Vollbild-Alarm**, der kurz vor dem Start den Bildschirm zumacht.

Der Vollbild-Alarm ist der eigentliche Zweck. Gewöhnliche Benachrichtigungen werden
übersehen — ein Overlay, das den Bildschirm blockiert und eine Taste verlangt, wird es nicht.

---

## Grenzen — bitte zuerst lesen

Diese Punkte sind keine Bugs, sondern Eigenschaften der Plattform. Wer sie nicht kennt,
verlässt sich auf einen Alarm, der in genau diesen Fällen nicht kommt.

1. **Gesperrte Session: kein Vollbild-Alarm, nur Benachrichtigung + Ton.**
   Omarchy sperrt über `WlSessionLock` (`ext-session-lock-v1`, First-Party-Plugin
   `omarchy.lock`). Das Protokoll gibt der Lock-Oberfläche den obersten Layer; ein
   Drittanbieter-Overlay kann darüber grundsätzlich nicht zeichnen. Der Service erkennt den
   Sperrzustand, verschiebt den Alarm und zeigt ihn **sofort nach dem Entsperren** — solange
   das noch innerhalb von `grace_seconds` nach Meeting-Start passiert. Benachrichtigung
   (`-u critical`, umgeht DND) und Ton laufen trotzdem, auch im gesperrten Zustand.

2. **Suspendierter Laptop wird nicht geweckt.**
   Aufwecken aus Suspend braucht einen RTC-Wakeup-Alarm auf Systemebene
   (`WakeSystem` / `rtcwake`) und damit Root-Rechte. Das Plugin läuft komplett im
   User-Kontext und tut das nicht. Nach dem Aufwachen wird ein verpasster Termin
   nachgeholt, wenn er noch innerhalb von `grace_seconds` liegt — sonst gar nicht.
   Wer sich auf den Alarm verlassen muss, darf den Deckel nicht schließen.
   Gegen Blank/Lock *vor* dem Meeting hilft dagegen der Idle-Inhibitor
   (`inhibit_lead_seconds`, Standard 5 Minuten vorher).

3. **Das `ics`-Backend hängt bis zu ~24 h nach.**
   Google erzeugt den privaten ICS-Feed nur etwa einmal täglich neu. Ein Termin, der heute
   Morgen verschoben wurde, fehlt darin. `ics` ist ein dokumentierter Notfall-Rückfall,
   keine Alternative zu `eds`. Es braucht außerdem `python-icalendar` und
   `python-recurring-ical-events`, die hier nicht installiert sind — ohne sie meldet der
   Fetcher `status: "error"`.

4. **Widget von der Bar nehmen schaltet das ganze Plugin ab.**
   Omarchy definiert „aktiviert“ als „die Plugin-ID steht irgendwo in `shell.json`“
   (`PluginRegistry.isEnabled`). Bei einem Bar-Widget ist dieser Eintrag der Bar-Layout-Eintrag.
   Fällt er weg, sind auch Service und Overlay weg — kein Alarm mehr.
   Zum Ausblenden also `widget.hide_when_empty` benutzen, nicht die Bar-Position löschen.

5. **Das `eds`-Backend ist erprobt — aber nur gegen genau ein Konto.**
   Stand 2026-09-10 sind `gnome-online-accounts`, `gnome-online-accounts-gtk` und
   `evolution-data-server` installiert und ein Google-Workspace-Konto ist verbunden. An echten
   Daten nachgemessen: die Zeitzonen-Umrechnung, `X-GOOGLE-CONFERENCE` als Quelle des
   Join-Links (auf allen Terminen im Fenster), und der `PARTSTAT`-Lauf für `declined` — über
   ein 65-h-Fenster 7 × ACCEPTED, 1 × DECLINED und 2 × ohne `PARTSTAT`, weil man dort gar
   nicht in der Teilnehmerliste steht. Unverifiziert bleibt: mehrere GOA-Konten gleichzeitig.
   `declined` kennen außerdem nur `eds`-Termine; `ics` und `demo` schreiben immer `false` —
   das ist richtig so und kein Bug, nur eben nichts, worauf man sich dort verlassen kann.
   Ohne verbundenes Konto funktioniert `"backend": "demo"` weiterhin vollständig.

6. **Plugins laufen unsandboxed im `omarchy-shell`-Prozess.** Das gilt für dieses hier genauso
   wie für jedes andere. QML-Fehler landen im Journal, nicht in einer Sandbox.

---

## Installation

```bash
cd ~/.config/omarchy/plugins/c51.meetings
./install.sh --dry-run     # zeigt alles, ändert nichts
./install.sh
```

`install.sh` ist idempotent und ruft **nie** `sudo` auf. Es

- prüft, dass es wirklich in `~/.config/omarchy/plugins/c51.meetings/` liegt,
- lässt `omarchy plugin validate` über sich laufen und bricht bei Fehlern ab,
- legt `~/.config/omarchy/meetings.json` aus `config.example.json` an — **nur wenn es
  noch nicht existiert**, mit Modus 0600,
- meldet fehlende Pakete und **druckt** den `pacman`-Befehl (sudo braucht hier ein Passwort,
  also führt das Script es nicht aus),
- registriert das Plugin: `omarchy-shell shell rescanPlugins`, dann
  `omarchy plugin enable c51.meetings`, und prüft das Ergebnis mit
  `omarchy plugin list --json`,
- legt `~/.local/bin/meetings-fetch` an — einen Wrapper, damit der Fetcher aus jedem
  Verzeichnis aufrufbar ist (`meetings-fetch --diagnose` statt Pfad tippen). Absichtlich
  ohne `omarchy-`-Präfix, weil die omarchy-CLI `omarchy <gruppe> <aktion>` auf
  `omarchy-<gruppe>-<aktion>` im PATH auflöst und das hier kein First-Party-Befehl ist.

Danach von Hand:

```bash
sudo pacman -S --needed gnome-online-accounts gnome-online-accounts-gtk evolution-data-server
```

`config.example.json` liefert `"backend": "eds"` als Zielzustand. Solange die Pakete fehlen
oder kein Konto verbunden ist, auf `demo` stellen — sonst meldet der Cache nur
`status: "error"`:

```bash
jq '.backend = "demo"' ~/.config/omarchy/meetings.json > /tmp/meetings.json \
  && mv /tmp/meetings.json ~/.config/omarchy/meetings.json
```

### Google Workspace verbinden

```bash
gnome-online-accounts-gtk
```

(`/usr/bin/gnome-online-accounts-gtk` aus dem Paket gleichen Namens — das ist hier der
einzige GOA-Dialog; `gnome-control-center` ist auf dieser Maschine nicht installiert und
wird auch nicht gebraucht.)

Google auswählen → im Browser anmelden (inkl. 2FA) → **Kalender** einschalten.
GOA legt das Konto als Collection-Source in `evolution-data-server` an; die Kalender
erscheinen als CalDAV-Kindquellen darunter. Prüfen mit:

```bash
meetings-fetch --diagnose
```

Erst wenn dort Kalender auftauchen, das Backend umstellen:

```bash
jq '.backend = "eds"' ~/.config/omarchy/meetings.json > /tmp/meetings.json \
  && mv /tmp/meetings.json ~/.config/omarchy/meetings.json
```

*(unverifiziert)* Manche Workspace-Tenants blockieren Drittanbieter-OAuth-Clients. Hier hat die
Anmeldung funktioniert; wird sie abgewiesen, muss die Administration den Client freigeben — dann
bleibt nur `ics` mit seinem Tagesverzug oder gar nichts.

---

## Bar-Eintrag und Agenda-Popup

Der Bar-Eintrag zeigt genau **einen** Termin: den nächsten, der noch alarmieren kann — nicht
ganztägig, nicht abgelehnt (solange `skip_declined` an ist), noch nicht vorbei. Ein laufendes
Meeting bleibt „der nächste“, bis es endet. Farbe: `colors.running`, sobald es läuft, sonst
`colors.upcoming` — ab `widget.warn_minutes` vor dem Start in voller Stärke, davor mit 75 %
Alpha. Ein `󰀦` heißt „lesbar, aber eingeschränkt“; der Grund steht im Tooltip, ebenso wie
Kalenderfehler, Cache-Alter und der nächste Termin im Klartext.

| Klick | Wirkung |
|---|---|
| **Links** | Agenda-Popup auf/zu |
| **Rechts** | Termine jetzt neu holen |
| **Mitte** | dasselbe |

**Kein** Klick löst den Vollbild-Alarm aus. Der unterbricht jemanden, der *nicht* auf die Bar
schaut — wer gerade geklickt hat, hat den Termin schon gesehen. Zum Ansehen bleibt
`omarchy-shell meetings preview` als Diagnose.

Das Popup zeigt von oben nach unten:

- den nächsten Termin mit Countdown und einer Aktion zum Neuladen,
- eine **Zeitleiste** über heute und morgen, mit einer Marke für „jetzt“,
- `HEUTE · DO., 10. SEPT.` und darunter eine Zeile pro Termin: Beginn–Ende, Provider-Glyph
  (nur wenn ein Join-Link existiert), Titel, Chevron,
- dasselbe für `MORGEN`,
- eine Fußzeile mit Aktionszeilen.

Zeilenzustände: **erledigte** Termine stehen abgedunkelt da, das **laufende** ist hervorgehoben,
**abgelehnte** sind durchgestrichen. Das ist der eigentliche Unterschied zu vorher:
`skip_declined` heißt jetzt „alarmiert nie“, nicht „ist unsichtbar“ — abgelehnte und schon
beendete Termine stehen in der Liste, damit die Agenda den Tag zeigt und nicht nur den Rest
davon (Invariante 5 der Spec). Ein Klick auf eine Zeile mit Join-Link öffnet das Meeting im
Browser.

Tastatur: solange das Popup offen ist, hat es den Fokus — Pfeiltasten (oder `j`/`k`) bewegen den
Cursor, Enter löst die Zeile aus, Esc schließt; das ist die Standardbelegung von
`PanelKeyCatcher`. Ein Klick daneben oder auf ein anderes Bar-Symbol schließt ebenfalls, wie bei
jedem First-Party-Panel.

Drei Dinge, die man wissen sollte:

- Mit `widget.hide_when_empty` (Standard) verschwindet der Bar-Eintrag, wenn kein Termin mehr
  ansteht — dann ist auch das Popup nicht erreichbar, denn es hängt an diesem Eintrag. Wer die
  Agenda auch abends noch aufklappen will, setzt den Schlüssel auf `false`.
- Das Widget liest höchstens 256 Termine aus dem Cache. Das ist keine Kalendergrenze, sondern
  eine Obergrenze gegen eine kaputte Datei; zwei Tage passen darunter bequem.
- Das Popup hat nur `HEUTE` und `MORGEN`. Reicht `lookahead_minutes` weiter als bis morgen
  Mitternacht, stehen die Termine von übermorgen im Cache und können sogar den Bar-Eintrag
  füllen — im Popup erscheinen sie nicht. Das ist gewollt: es ist eine Agenda für heute und
  morgen, keine Kalender-App.

Das Popup rendert nur — jede Aktion läuft über das Widget zurück (`join`, `requestRefresh`,
`openUrl`, `close`), damit genau eine Datei mit der Außenwelt spricht und der https-Check vor
dem Browser-Aufruf nur an einer Stelle steht. Es ist bewusst **kein** `panel`-Kind im Manifest:
`shell.qml` reduziert die Kinds eines Plugins auf einen Loader, `panel` schlägt dort `overlay` —
der Vollbild-Alarm würde nie mehr laden.

---

## Konfiguration — `~/.config/omarchy/meetings.json`

Eine Datei für alles. Sie wird vom Python-Fetcher **und** vom QML gelesen. Jeder Schlüssel ist
optional; fehlt einer, greift der Standard unten. Eine kaputte Datei führt nicht zum Absturz,
sondern zu den eingebauten Standards (und einer Zeile im Journal).

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `backend` | `"eds"` | `eds` = Google via GOA/Evolution. `ics` = Notfall-Feed (siehe Grenzen). `demo` = synthetische Termine, kein Konto nötig. |
| `ics_urls` | `[]` | Private ICS-URLs für `backend: "ics"`. **Geheim** — sie sind Zugangsdaten und werden nie geloggt. |
| `lookahead_minutes` | `720` | Wie weit über die Agenda hinaus Termine geholt werden (12 h). Das Fenster ist **mindestens** heute + morgen — das ist die Agenda, die das Popup zeigt; dieser Schlüssel kann es nur verlängern, nie verkürzen. |
| `refresh_seconds` | `300` | Mindestabstand zwischen echten **Netz**-Abfragen (EDS `refresh_sync`). EDS' eigener Standard wäre 60 min. |
| `fetch_interval_seconds` | `60` | Wie oft der Service den Fetcher startet (lokales Lesen, kein Netz). |
| `alert_lead_seconds` | `60` | So viele Sekunden vor Start kommt der Vollbild-Alarm. |
| `auto_dismiss_seconds` | `90` | Alarm schließt sich von selbst. `0` = bleibt, bis man ihn wegklickt. |
| `colors.running` | `#FF9500` | Farbe für ein **laufendes** Meeting — im Bar-Eintrag und im Countdown des Vollbild-Alarms. Nur `#rrggbb`; alles andere fällt auf den Standard zurück. |
| `colors.upcoming` | `#00BEFF` | Farbe für ein **anstehendes** Meeting, ebenfalls in Bar und Alarm. |
| `inhibit_lead_seconds` | `600` | Ab so vielen Sekunden vor Start wird ein Wayland-Idle-Inhibitor gehalten (bis `start + grace_seconds`), damit die Session nicht in den Alarm hinein sperrt. |
| `grace_seconds` | `300` | Nachlauf: ein Termin, dessen Start höchstens so lange her ist, wird noch alarmiert (Suspend, Sperre). Älter = nie. |
| `sound` | `.../alarm-clock-elapsed.oga` | Wird per `pw-play` gespielt. Leerer String = kein Ton. Omarchy liefert selbst keine Sounds; die Datei kommt aus `sound-theme-freedesktop` und ist vorhanden. |
| `notify` | `true` | Zusätzlich `omarchy-notification-send -u critical` (umgeht DND). |
| `wake_display` | `true` | Vor dem Alarm `omarchy-brightness-display on`. |
| `skip_all_day` | `true` | Ganztagstermine gar nicht erst in den Cache holen (also auch nicht in die Agenda). Alarmieren würden sie ohnehin nie — ein Ganztagstermin hat keinen Startmoment (Invariante 4). |
| `skip_declined` | `true` | Selbst abgelehnte Termine (`PARTSTAT: DECLINED`) **alarmieren nie** — sie stehen aber durchgestrichen in der Agenda und zählen nicht als „nächster Termin“. `false` = eine abgelehnte Einladung wird wie jede andere behandelt, Alarm inklusive. Nur `eds` kennt das Flag. |
| `min_duration_minutes` | `0` | Termine kürzer als das ignorieren. `0` = keine Untergrenze. |
| `title_blocklist` | `[]` | Titel-Fragmente, die einen Termin ausschließen. |
| `calendars_exclude` | `[]` | Kalendernamen, die nicht berücksichtigt werden. |
| `widget.warn_minutes` | `15` | Ab so vielen Minuten vor Start leuchtet der Bar-Eintrag in voller Stärke; davor mit 75 % Alpha. Die *Farbe* selbst sagt nur, ob das Meeting läuft (`colors.running`) oder ansteht (`colors.upcoming`). |
| `widget.max_title_chars` | `28` | Titel im Bar-Eintrag kürzen (im Popup begrenzt die Kartenbreite). |
| `widget.hide_when_empty` | `true` | Ohne anstehenden Termin auf Breite 0 zusammenfallen. Dann ist auch das Popup nicht mehr anklickbar; ein Cache-Fehler oder eine Warnung hält den Eintrag trotzdem sichtbar. |

Der `manifest.json`-Block `barWidget.defaults` / `barWidget.schema` führt dieselben drei
`widget.*`-Schlüssel mit identischen Namen und Standards, damit eine künftige Einstellungs-UI
sie anbieten kann. **Maßgeblich ist `meetings.json`.** In Omarchy 4.0.0.alpha rendert nichts
im Shell-Baum `barWidget.schema`; der Block ist heute reine Metadatenvorsorge.

---

## Test und Fehlersuche

```bash
omarchy-shell meetings test       # Vollbild-Alarm sofort, synthetisch, ohne Kalender
omarchy-shell meetings status     # JSON: Backend-Status, Cache-Alter, nächster Termin, Flags
omarchy-shell meetings preview    # Alarm für den echten nächsten Termin, ohne ihn als
                                  # "gefeuert" zu markieren
omarchy-shell meetings refresh    # Fetcher jetzt laufen lassen
omarchy-shell meetings dismiss    # Alarm wegschalten

meetings-fetch --diagnose   # Pakete, Typelibs, GOA-Konten, gefundene Kalender,
                                  # Alter des letzten Syncs — ohne Termininhalte
meetings-fetch --print      # Cache-JSON nach stdout statt in die Cache-Datei
meetings-fetch --backend demo --in-seconds 20   # Termin in 20 s erzeugen

journalctl --user -t omarchy-shell -f    # QML-Fehler und Zustandswechsel
quickshell log -f                        # dasselbe Log direkt von Quickshell
omarchy plugin list --json | jq '.[] | select(.id == "c51.meetings")'
```

Der Ereignis-Cache liegt in `$XDG_RUNTIME_DIR/omarchy-meetings/events.json`,
der Merker für schon gefeuerte Termine in `state.json` daneben.

Häufige Fälle:

- **Widget zeigt ein blasses `󰃭 —`** → der Cache fehlt, `status != "ok"`, oder es steht
  einfach nichts mehr an. Was davon, sagt der Tooltip (und er sagt auch, wie viele Termine die
  Agenda noch listet); genauer: `omarchy-shell meetings status` und dann `--diagnose`.
- **Ein Termin fehlt im Popup** → `skip_all_day`, `min_duration_minutes`, `title_blocklist` und
  `calendars_exclude` werfen Termine schon im Fetcher weg, die stehen dann auch nicht in der
  Agenda. `skip_declined` tut das ausdrücklich **nicht** mehr. Gegenprobe ohne Termininhalte:
  `meetings-fetch --print | jq '.events | length'`.
- **Popup öffnet nicht** → der Bar-Eintrag läuft unabhängig weiter, ein Fehler in `Popup.qml`
  lässt nur den Loader leer und jeden Aufruf ins Leere laufen; nachsehen in
  `journalctl --user -t omarchy-shell`. Und: mit `widget.hide_when_empty` ist ohne anstehenden
  Termin gar kein Eintrag da, den man anklicken könnte.
- **Alarm kommt nicht** → `status` prüfen: steht der Termin überhaupt im Cache? Ist seine ID
  schon in `state.json` (dann wurde er bereits gefeuert)? War die Session gesperrt (siehe
  Grenze 1)?
- **Alarm kommt doppelt** → die Event-ID ist zwischen zwei Fetches nicht stabil geblieben.
  `--print` zweimal laufen lassen und die `id`-Felder vergleichen.
- **Nach einer Code-Änderung tut sich nichts** → `omarchy restart shell`. Das Speichern einer
  Datei unter `~/.config/omarchy/plugins/` löst zwar einen Reload aus (im Journal:
  `Local plugin changed, reloading: c51.meetings`, danach `service-ready`), aber am
  2026-09-10 auf Omarchy 4.0.x / Quickshell 0.3.1 nachgemessen: **die laufende
  Service-Instanz wird dabei nicht durch den neuen Code ersetzt** — auch nicht nach
  `omarchy-shell shell rescanPlugins` oder nach Löschen von `~/.cache/quickshell/qmlcache`.
  Erst ein Shell-Neustart lädt den Service neu. Änderungen an `meetings.json` greifen dagegen
  sofort, weil die Config über ein `FileView` gelesen wird (nachprüfbar an
  `omarchy-shell meetings status | jq .settings`).
- **Fetcher scheitert dauerhaft** → das ist gewollt leise: nach dem ersten Fehlschlag
  verdoppelt sich der Abstand (60 s → 120 → 240 → 480 → max. 900 s), und ins Journal geht nur
  eine Zeile pro Eskalationsstufe. Der Zähler steht in `status` unter
  `fetch.failStreak` / `fetch.retryInSeconds`. Ein Erfolg oder eine Änderung an
  `meetings.json` setzt den Backoff sofort zurück.

### Zu `keepLoaded`

`keepLoaded` ist in `manifest.json` **absichtlich nicht gesetzt**: `true` würde den Service
über `rescanPlugins` hinweg am Leben halten, aber laut `shell/README.md` wird die behaltene
Instanz dann *nicht ersetzt* — Code-Änderungen am Service bräuchten einen vollen
Shell-Neustart (`unloadPluginServices()` in `shell.qml` behält genau diese Instanzen). Unser
Service rechnet seinen kompletten Zustand beim Laden aus `meetings.json`, `events.json` und
`state.json` neu, und `state.json` verhindert ein erneutes Feuern nach dem Neu-Einhängen.
Damit kostet das Neu-Einhängen nichts.

Der erhoffte Vorteil — schnelles Nachladen beim Editieren — tritt in der Praxis allerdings
nicht ein: siehe den Punkt zur Code-Änderung oben, ein Code-Wechsel braucht so oder so
`omarchy restart shell`. `keepLoaded` bleibt trotzdem ungesetzt, weil der Service dann nach
einem Reload garantiert genau einmal existiert und seinen Zustand frisch von der Platte
liest.

---

## Sicherheit und Datenschutz

- **Der Google-Refresh-Token gehört GOA, nicht diesem Plugin.** GOA legt ihn über
  `libsecret` im lokalen Schlüsselbund ab. Das Plugin sieht ihn nie, fragt ihn nie ab und
  schreibt ihn nirgendwohin.
- **Der Schlüsselbund auf dieser Maschine ist unverschlüsselt, und die Anmeldung ist
  automatisch.** Beides geprüft: `~/.local/share/keyrings/Default_keyring.keyring` beginnt
  mit dem Klartext-Header `[keyring]` (das unverschlüsselte gnome-keyring-Format), und die
  aktive Session läuft über `sddm-autologin`. Praktisch heißt das: wer die Maschine
  einschaltet, hat eine angemeldete Session mit offenem Schlüsselbund — und damit Zugriff auf
  das Google-Konto. Das ist eine Eigenschaft dieser Maschine, nicht des Plugins, aber ein
  verbundenes Workspace-Konto erhöht den Einsatz deutlich. Wer das nicht will:
  Schlüsselbund mit Passwort versehen und Autologin abschalten, **bevor** das Konto
  verbunden wird.
- **Der Cache liegt in tmpfs.** `$XDG_RUNTIME_DIR/omarchy-meetings/` ist Modus 0700, die
  Dateien darin 0600, geschrieben mit `os.replace` (atomar). `/run/user/1000` ist tmpfs —
  nach einem Reboot ist kein Termininhalt mehr auf der Platte.
- **Der Cache ist seit Schema 2 die Agenda**, nicht mehr die Liste der Alarm-Kandidaten: er
  enthält heute und morgen komplett, also auch schon beendete und abgelehnte Termine, weil das
  Popup sie anzeigt. Mehr Zeilen in tmpfs — dieselben Felder, dasselbe Ende beim Reboot.
- **Im Cache steht nur das Nötige:** Titel, Start, Ende, Ganztags-Flag, Abgelehnt-Flag,
  Join-URL, Kalendername, Ort. Keine Teilnehmer, keine Beschreibung, kein Organisator, keine
  E-Mail-Adressen. Ins Journal gehen nur Zustandswechsel und Zählwerte — keine Titel.
- **Fehlermeldungen sind bereinigt:** ICS-URLs und Tokens landen nie in `error` oder im Log.
- **Keine Shell-Strings aus Termindaten.** Jeder externe Aufruf ist ein Argv-Array
  (`Process.command`, `Quickshell.execDetached([...])`, `Util.execArgv`), damit ein
  Meeting-Titel keine Befehle ausführen kann.

Für rechtliche Fragen zur Verarbeitung von Kalenderdaten aus einem Workspace-Konto
(Betriebsrat, Auftragsverarbeitung, Aufbewahrung) sollte eine Fachperson prüfen — das ist
hier nicht beurteilt.
