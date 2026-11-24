---
title: "Schublade vs Paperless-ngx: zwei selbst gehostete Archive"
description: "Schublade oder Paperless-ngx? Betrieb, Wartung, Texterkennung, Einordnung, E-Mail-Eingang, Apps, Teilen und Kosten im Vergleich, Stand November 2026."
competitor: "Paperless-ngx"
competitorUrl: "https://docs.paperless-ngx.com/"
verifiedOn: 2026-11-24
summary: "Nimm Schublade, wenn dein Haushaltsarchiv in deinem eigenen Cloudflare-Konto laufen soll, ohne Server zum Pflegen und mit einem Sprachmodell, das jedes Dokument einordnet. Nimm Paperless-ngx, wenn alles auf deiner eigenen Hardware laufen soll, du Rechte pro Person brauchst oder Office-Dateien archivierst."
aspects:
  - aspect: "Wo es läuft und wo die Dateien liegen"
    schublade: "Ein Cloudflare Worker in deinem eigenen Cloudflare-Konto. Dateien liegen dort in R2, Datensätze in D1."
    competitor: "Auf deinem eigenen Server, meist mit Docker Compose. Die Dateien liegen als normale Dateien auf dessen Festplatte."
  - aspect: "Wer den Server pflegt"
    schublade: "Cloudflare betreibt die Plattform. Neue Versionen spielst du mit einem Befehl ein."
    competitor: "Du selbst. Webserver, Task-Prozessor, ein Redis-kompatibler Broker und eine Datenbank wie PostgreSQL."
  - aspect: "Texterkennung"
    schublade: "Nutzt die Textebene eines PDFs, wenn sie lesbar ist. Scans und Fotos liest das Bildmodell Moondream 3.1 auf Workers AI."
    competitor: "Tesseract, das mehr als 100 Sprachen erkennt. Texterkennung über Azure AI Document Intelligence lässt sich zuschalten."
  - aspect: "Automatische Einordnung"
    schublade: "Ein Sprachmodell setzt Titel, Datum, Absender, Kategorie und Haushaltsmitglied und liest Beträge und IBANs aus. Kein Training nötig."
    competitor: "Ein Modell, das auf deinen eigenen Dokumenten lernt, vergibt Tags, Korrespondenten und Dokumenttypen. Vorschläge eines Sprachmodells über eine OpenAI-kompatible API oder Ollama lassen sich zuschalten."
  - aspect: "Suche"
    schublade: "Stichwort- und Bedeutungssuche über Sprachen hinweg, mit Cloudflare AI Search."
    competitor: "Volltextsuche mit Autovervollständigung, markierten Treffern und der Suche nach ähnlichen Dokumenten."
  - aspect: "E-Mail-Eingang"
    schublade: "Du leitest Mails von einer erlaubten Adresse an die Adresse deines Archivs weiter. Eine Mail ohne Anhang druckt Schublade als PDF."
    competitor: "Holt Mails aus Postfächern, die du einrichtest. Regeln pro Postfach legen fest, was übernommen wird und was danach mit der Mail passiert."
  - aspect: "App fürs Handy"
    schublade: "iPhone-App mit Dokumentenscanner und Teilen-Menü, bald verfügbar. Schon heute lässt sich die Web-App auf den Home-Bildschirm legen und nutzt die Kamera."
    competitor: "Keine offizielle App. Das Projekt-Wiki listet Community-Apps für iOS und Android, die das Team nicht offiziell unterstützt."
  - aspect: "App für den Mac"
    schublade: "Mac-App mit Leseansicht, Offline-Kopie und einem Sammler für ausgewählte Ordner, bald verfügbar."
    competitor: "Keine offizielle App. Das Wiki listet Community-Programme für macOS."
  - aspect: "Teilen im Haushalt"
    schublade: "Ein Haushalt pro Installation. Wer sich anmelden darf, sieht jedes Dokument."
    competitor: "Benutzer, Gruppen und Rechte pro Dokument, dazu öffentliche Freigabelinks mit Ablaufdatum."
  - aspect: "Dateitypen"
    schublade: "PDF, JPEG, PNG und WebP."
    competitor: "PDF, Bilder, Text und Office-Dokumente. Office-Dateien und E-Mails brauchen das optionale Apache Tika."
  - aspect: "Zugriff für KI-Assistenten (MCP)"
    schublade: "Eingebauter MCP-Zugang mit vier Werkzeugen, die nur lesen. Auf der Freigabeseite beschränkst du ihn auf bestimmte Kategorien, Absender und Tags."
    competitor: "Kein eingebauter MCP-Server. Das Wiki listet Community-Server. Ein eingebauter Dokumenten-Chat arbeitet mit einem Sprachmodell, das du einrichtest."
  - aspect: "Kosten"
    schublade: "Cloudflare Workers Paid, mindestens 5 USD im Monat (Preisseite von Cloudflare, gelesen am 24.11.2026), dazu etwa 0,0023 USD pro Dokument und 0,0008 USD pro erkannter Seite."
    competitor: "Kostenlos und quelloffen unter GPL-3.0. Du zahlst für die Hardware oder das Hosting."
sources:
  - title: "Paperless-ngx-Dokumentation: Startseite (docs/index.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/index.md"
  - title: "Paperless-ngx-Dokumentation: Installation (docs/setup.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/setup.md"
  - title: "Paperless-ngx-Dokumentation: Nutzung (docs/usage.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/usage.md"
  - title: "Paperless-ngx-Dokumentation: Verwaltung, Dokument-Exporter (docs/administration.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/administration.md"
  - title: "Paperless-ngx-Wiki: Related Projects"
    url: "https://github.com/paperless-ngx/paperless-ngx/wiki/Related-Projects"
  - title: "Paperless-ngx auf GitHub"
    url: "https://github.com/paperless-ngx/paperless-ngx"
  - title: "Cloudflare Workers: Preise"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## Gleiches Ziel, anderer Weg

Paperless-ngx und Schublade machen aus Briefen, Rechnungen und Belegen ein durchsuchbares Archiv, das du selbst betreibst. Paperless-ngx war das Vorbild für Schublade. Der Unterschied liegt darin, wo die Arbeit passiert und wer sich darum kümmert.

Paperless-ngx ist ein ausgereiftes Projekt, das eine Community trägt, mit mehr als 48.000 Sternen auf GitHub. Du betreibst es auf einem Rechner, den du kontrollierst, meist mit Docker Compose. Neben Webserver und Task-Prozessor braucht es einen Redis-kompatiblen Broker, und die Dokumentation empfiehlt PostgreSQL als Datenbank. Deine Dokumente verlassen diesen Rechner nur, wenn du ausdrücklich einen externen Dienst einschaltest.

Schublade läuft als ein einziger Cloudflare Worker in deinem eigenen Cloudflare-Konto. Es gibt keinen Rechner, den du aktualisieren musst. Ein Sprachmodell auf Workers AI liest jedes Dokument und gibt ihm Titel, Datum, Absender, Kategorie und das Haushaltsmitglied, zu dem es gehört. Dateien und Modelle bleiben in deinem Konto. Einen API-Schlüssel bei einem anderen KI-Anbieter brauchst du nicht.

## Für wen sich was eignet

Schublade passt zu einem Haushalt, der seinen Papierkram abgelegt haben will, ohne einen Server zu pflegen oder einem Modell etwas beizubringen. Du leitest eine Mail weiter, lädst ein Foto hoch oder schickst eine Datei mit einem Token, und das Dokument erscheint mit ausgefüllten Feldern. Die Suche findet Stichwörter und Bedeutungen und arbeitet über Sprachen hinweg. Mehr dazu auf der Seite zur [Web-App](/de/web/).

Paperless-ngx passt zu dir, wenn du schon einen Heimserver betreibst und alles in der Hand haben willst. Es läuft vollständig auf deiner eigenen Hardware. Mit seinem Rechtesystem hat jede Person ihre eigenen Dokumente. Workflows legen fest, was mit jeder Datei passiert. Mit dem optionalen Apache Tika übernimmt es auch Word- und Excel-Dateien, die Schublade nicht annimmt.

## Wo Paperless-ngx klar vorne liegt

- **Rechte.** Paperless-ngx kennt Benutzer, Gruppen und Rechte auf jedem Dokument. Schublade bedient einen Haushalt pro Installation, und alle, die sich anmelden, sehen alles.
- **Reife.** Paperless-ngx folgt auf Paperless und Paperless-ng und hat eine große Community. Schublade ist ein junges Projekt.
- **Kein Cloud-Konto.** Paperless-ngx braucht keinen Cloud-Dienst. Schublade braucht ein Cloudflare-Konto mit dem Workers-Paid-Tarif, und Cloudflare berechnet Texterkennung und Einordnung pro Nutzung.
- **Dateitypen.** Schublade nimmt nur PDF, JPEG, PNG und WebP an.
- **Apps heute.** Keines der beiden Projekte hat heute eine offizielle App im Store. Für Paperless-ngx gibt es eine Liste von Community-Apps. Die [iPhone-App](/de/iphone/) und die [Mac-App](/de/mac/) von Schublade funktionieren, sind aber noch nicht veröffentlicht.

## Was Schublade anders macht

Schublade hält jeden Dateiinhalt genau einmal. Jede Datei bekommt als Namen den SHA-256 ihrer Bytes. Schickst du dieselben Bytes noch einmal, bekommst du das vorhandene Dokument zurück. Paperless-ngx behält Duplikate standardmäßig und zeigt sie in einem eigenen Tab. Mit einer Einstellung lehnt es sie stattdessen ab.

Für den E-Mail-Eingang braucht Schublade kein Postfach. Du leitest eine Mail an eine Adresse auf deiner Cloudflare-Domain weiter. Schublade prüft, ob der Absender erlaubt ist und DMARC bestanden hat, und druckt eine Mail ohne Anhang als PDF. Paperless-ngx verbindet sich mit deinen bestehenden Postfächern und wendet deine Regeln an.

Schublade hat einen eingebauten MCP-Zugang. Claude oder ein anderer MCP-Client bekommt vier Werkzeuge, die suchen, auflisten und lesen, aber nichts ändern. Auf der Freigabeseite beschränkst du eine Verbindung auf die Kategorien, Absender und Tags, die du auswählst. Paperless-ngx bringt einen Dokumenten-Chat mit einem Modell deiner Wahl mit, MCP-Server gibt es dort von der Community.

## Von Paperless-ngx zu Schublade umziehen

1. Exportiere deine Originale mit dem Dokument-Exporter von Paperless-ngx. Mit der Option `--no-archive` bekommst du nur die Originaldateien, ohne die PDF/A-Kopien.
2. Richte Schublade mit `pnpm run provision` in deinem Cloudflare-Konto ein.
3. Schick die exportierten Dateien an Schublade. Lade sie im Browser hoch, 20 Dateien auf einmal, oder erstelle unter **Settings** einen Token und schick sie per Skript an `/api/documents/ingest`. Sobald die Mac-App erscheint, kann ihr Sammler den Exportordner beobachten und nur die Dateien schicken, die im Archiv fehlen.

Schublade ordnet jedes Dokument beim Eingang neu ein. Tags, Korrespondenten und eigene Felder aus Paperless-ngx kommen nicht mit. Dateien außer PDF, JPEG, PNG und WebP bleiben zurück. Weil Schublade Dateien an ihren Bytes erkennt, kannst du den Upload nach einer Unterbrechung einfach wiederholen. Was schon angekommen ist, meldet das Archiv als bereits vorhanden.
