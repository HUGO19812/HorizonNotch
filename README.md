# Horizon Notch

Macht aus der MacBook-Notch eine **Dynamic Island**: Musik, System-Anzeigen, Akku, Timer, Ablage mit AirDrop, Kalender, Wetter, Verbindungen und ein Musik-Player auf dem Sperrbildschirm. Native macOS-App (Swift, SwiftUI und AppKit), läuft in der Menüleiste ohne Dock-Symbol.

Auf Macs und Bildschirmen ohne Notch erscheint oben in der Mitte eine schwebende Kapsel.

## Installieren (DMG)

**[⬇︎ HorizonNotch.dmg herunterladen](https://github.com/HUGO19812/HorizonNotch/releases/latest/download/HorizonNotch.dmg)** – immer die neueste Version.

1. DMG öffnen und **Horizon Notch** auf den Ordner **Programme** ziehen.
2. Beim allerersten Start meldet macOS, dass die App nicht geprüft werden kann (sie ist nicht von Apple notarisiert). Dann **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz unten **„Dennoch öffnen“** klicken und bestätigen. Das ist nur einmal nötig.

   Alternativ im Terminal: `xattr -dr com.apple.quarantine /Applications/HorizonNotch.app`

Es läuft immer nur eine Horizon Notch: Wird eine zweite Kopie gestartet, beendet sie die erste.

### DMG selbst bauen

```bash
./scripts/make-dmg.sh
```

Legt `build/HorizonNotch.dmg` an (Apple Silicon und Intel). Die Version in der App kommt aus `MARKETING_VERSION` im Xcode-Projekt.

Automatisch geht es über GitHub Actions: Bei jedem Push auf `main` baut der Workflow **DMG** (`.github/workflows/release.yml`) die DMG und veröffentlicht sie als Release `v<MARKETING_VERSION>`; gibt es die Version schon, wird ihre DMG ersetzt. Für eine neue Version `MARKETING_VERSION` im Xcode-Projekt erhöhen. Der Download-Link oben zeigt immer auf das neueste Release.

Ohne Warnung beim Öffnen geht es nur mit einem kostenpflichtigen Apple-Developer-Konto. Dafür im Repo unter *Settings → Secrets → Actions* hinterlegen: `MACOS_CERT_P12` (Developer-ID-Zertifikat als Base64), `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` und `APPLE_APP_PASSWORD` (app-spezifisches Passwort). Dann wird die DMG signiert und notarisiert. Lokal geht das mit `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<Profil> ./scripts/make-dmg.sh`.

## Einrichten (aus dem Quellcode)

Doppelklick auf **`build.command`**. Das Skript baut die Release-Version, legt sie nach `/Applications/HorizonNotch.app` und startet sie.

Voraussetzungen:
- macOS 14.6 oder neuer (Liquid Glass ab macOS 26)
- **Xcode** (Version 16 oder neuer, das Projekt nutzt synchronisierte Ordner)
- Optional das Zertifikat **„FlowTools Local Signing"** im Schlüsselbund. Mit gleichbleibender Signatur behält macOS erteilte Berechtigungen auch nach einem Neubau. Fehlt es, signiert das Skript ad hoc.

Zum Entwickeln `HorizonNotch.xcodeproj` in Xcode öffnen und mit ⌘R starten. Oder im Terminal:

```bash
xcodebuild -project HorizonNotch.xcodeproj -scheme HorizonNotch -configuration Debug -derivedDataPath build/dd.noindex build
```

Das App-Symbol wird mit `swift scripts/make-icon.swift` neu gezeichnet.

## Bedienung

- **Zeiger auf die Notch** öffnet die Island; die Verzögerung ist einstellbar. Ein Klick öffnet sie sofort.
- **Reiter oben links** wechseln zwischen den Seiten (Musik, Timer, Ablage, Kalender, Wetter, Rechner). Wischen auf dem Trackpad wechselt bewusst keine Seiten, damit z. B. die Datumsleiste im Kalender frei scrollen kann.
- **Dateien auf die Notch ziehen** öffnet zwei Felder: *AirDrop* oder *Ablegen*. Abgelegte Dateien zieht man wieder heraus, mit Doppelklick öffnet man sie.
- Einstellungen über das Menüleisten-Symbol oder das Zahnrad in der Island.

## Module

| Modul | Was es zeigt | Quelle |
|---|---|---|
| Musik | Cover, Titel, Fortschritt mit Scrubbing, Steuerung, Zufall, Ausgabegerät, Visualizer in Cover-Farbe, synchronisierte Songtexte | MediaRemote über Helfer (siehe unten), LRCLIB |
| Lautstärke, Helligkeit, Tastaturlicht | Eigene Anzeige statt System-HUD, ⌥⇧ für feine Schritte | Event-Tap, CoreAudio, DisplayServices, CoreBrightness |
| Akku & Laden | Lade-Animation beim Ein- und Ausstecken, Warnung bei 20/10/5 % | IOKit-Power-Notifications |
| Kamera & Mikrofon | Anzeige, solange ein Gerät benutzt wird, und welche Apps aufnehmen | CoreAudio-Prozessobjekte, CoreMediaIO |
| Timer | Countdown und Stoppuhr, Live-Anzeige neben der Notch | – |
| Ablage | Datei-Ablage und AirDrop | NSSharingService |
| Kalender | Nächste Termine, Countdown 10 Min. vor Meetings, „Beitreten" für Zoom/Teams/Meet | EventKit |
| Wetter | Aktuell, Höchst- und Tiefstwert, scrollbare Stundenleiste (24 h) | Open-Meteo, CoreLocation oder gesuchter Ort |
| Rechner | Verlauf links (Klick übernimmt ein Ergebnis), Rechnung in der Mitte, Tastenfeld mit Rechenzeichen in der Akzentfarbe rechts; bei offenem Reiter auch per Tastatur bedienbar, ⌘C oder Klick auf die Anzeige kopiert | – |
| Verbindungen | Kopfhörer verbunden/getrennt, WLAN, optional alle Bluetooth-Geräte mit AirPods-Akku und Fokus | CoreAudio, Network, CoreWLAN, IOBluetooth, Intents |
| Benachrichtigungen | Fertige Downloads (optional) | kqueue auf ~/Downloads |
| Sperrbildschirm | Kleiner Musik-Player; Klick aufs Cover zeigt es groß auf dunklem, vom Cover getöntem Hintergrund, der Songtext-Knopf blendet die Lyrics dazu ein | SkyLight (siehe unten), LRCLIB |

Die Island zeigt immer das wichtigste aktive Modul: **HUD > Benachrichtigung/Akku > Kamera & Mikrofon > Kalender > Timer > Musik**. Jedes Modul lässt sich in den Einstellungen abschalten, die Seitenreihenfolge per Ziehen ändern.

## Berechtigungen

Die App fragt nur nach, wenn eine Funktion es braucht:

| Berechtigung | Wofür | Wann gefragt |
|---|---|---|
| Bedienungshilfen | Lautstärke-, Helligkeits- und Tastaturlicht-Tasten abfangen | Beim ersten Start (Einführung) oder über das Menüleisten-Symbol |
| Kalender | Kalender-Modul | Beim Klick auf „Zugriff erlauben" |
| Standort | Wetter vor Ort und WLAN-Namen (macOS gibt SSIDs nur mit Standortfreigabe heraus) | Beim ersten Öffnen der Wetter-Seite. Alternativ unter Wetter einen Ort suchen und anklicken |
| Bluetooth | Alle Bluetooth-Geräte, AirPods-Akku | Beim Einschalten der Option |
| Fokus-Status | Fokus ein/aus | Beim Einschalten der Option |
| Downloads-Ordner | Fertige Downloads | Beim Einschalten der Option |
| Automatisierung (Musik, Spotify) | Nur im Notfall-Modus, wenn der MediaRemote-Helfer ausfällt | Beim ersten Steuerbefehl |

Bildschirmaufnahme ist **nicht** nötig. Der Visualizer ist eine Animation, die dem Wiedergabestatus folgt, und nimmt kein Audio ab. So bleibt auch keine Aufnahme-Anzeige von macOS dauerhaft sichtbar.

## Wie es funktioniert

- **Notch-Fenster:** Ein randloses, nicht aktivierendes `NSPanel` liegt über der Menüleiste auf allen Spaces, auch neben Vollbild-Apps. Die Notch-Größe kommt aus `safeAreaInsets` und `auxiliaryTopLeftArea/RightArea`. Klicks gehen überall durch, außer auf die Island selbst. Das steuern Event-Monitore, kein Timer.
- **Form:** `NotchShape` zeichnet die Kontur mit konkaven „Ohren" oben. Breite, Höhe und alle Radien werden mit Spring-Animationen bewegt.
- **Module:** Jedes Modul erfüllt das Protokoll `NotchModule` (`id`, `priority`, `isActive`, kompakte und geöffnete Ansicht). Der `NotchCoordinator` wählt das aktive Modul.
- **Now Playing:** Seit macOS 15.4 antwortet das private MediaRemote-Framework nur noch Apple-signierten Prozessen. Horizon Notch lädt deshalb eine kleine Bibliothek (`MediaBridge/HNMediaBridge.m`) in Apples eigenes `/usr/bin/perl`. Dieser Helfer meldet Änderungen als JSON über stdout und nimmt Befehle über stdin. Er beendet sich, sobald die App weg ist. Fällt er dauerhaft aus, übernimmt AppleScript für Musik und Spotify.
- **Sperrbildschirm:** Sperren und Entsperren kommen über `com.apple.screenIsLocked` bzw. `com.apple.screenIsUnlocked`. Das Player-Fenster wird mit privaten SkyLight-Funktionen (`SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSSpaceAddWindowsAndRemoveFromSpaces`) in einen eigenen Space auf Ebene 400 gelegt, über dem Sperrbildschirm. Einen öffentlichen Weg gibt es nicht.
- **Ressourcen:** Im Leerlauf ~0 % CPU. Alles hängt an System-Benachrichtigungen. Regelmäßig geprüft wird nur, wo macOS nichts meldet: das Wetter alle 30 Min. und der Fokus alle 20 s, und der Fokus nur, wenn eingeschaltet. Fortschrittsbalken ticken nur, solange die Island offen ist.

## Bekannte Einschränkungen

- **Benachrichtigungen anderer Apps** lassen sich unter macOS nicht offiziell mitlesen. Die Mitteilungs-Datenbank liegt in einem geschützten Container (nur mit Festplattenvollzugriff lesbar), ihr Format ist undokumentiert, und Banner über die Bedienungshilfen auszulesen wäre unzuverlässig. Die Island zeigt deshalb nur eigene Ereignisse (Akku, Verbindungen, Downloads, Kalender, Timer).
- **Kamera:** macOS verrät, *dass* eine Kamera läuft, aber nicht, *welche App* sie nutzt. Beim Mikrofon werden die Apps angezeigt.
- **Private Schnittstellen:** MediaRemote, DisplayServices, CoreBrightness, SkyLight und die AirPods-Akkuwerte sind undokumentiert. Ein macOS-Update kann sie ändern. Die App prüft alle Symbole zur Laufzeit und schaltet die betroffene Funktion dann still ab. Für den App Store ist sie damit nicht geeignet, und die App läuft ohne Sandbox.
- **Helligkeitstasten** funktionieren für den eingebauten Bildschirm. Externe Monitore (DDC) werden nicht gesteuert, dort bleibt das System-HUD.
- **Tastaturlicht-Tasten** gibt es nur auf Tastaturen mit eigenen Tasten dafür. Neuere MacBooks steuern das Licht über das Kontrollzentrum, dort erscheint keine Anzeige.
- **Fokus** hat keine Änderungs-Benachrichtigung und wird deshalb alle 20 s abgefragt, nur bei aktivierter Option. Ohne passende Berechtigung bleibt die Option wirkungslos.
- **WLAN-Namen** gibt es nur mit Standortfreigabe, sonst steht dort „WLAN".
- **Songtexte** kommen von LRCLIB (Community-Datenbank). Nicht jeder Titel hat synchronisierte Texte.
- **Sperrbildschirm:** Der Player soll bedienbar sein (Tasten, Lautstärke). Je nach macOS-Version nimmt der Sperrbildschirm Klicks aber selbst entgegen.
