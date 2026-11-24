---
title: "Schublade vs Google Drive für den Papierkram im Haushalt"
description: "Liegt dein Papierkram in Google Drive? Vergleich mit Schublade: Ablage, Texterkennung, Suche, E-Mail-Eingang, Apps, Teilen, Speicherort und Kosten."
competitor: "Google Drive"
competitorUrl: "https://drive.google.com/"
verifiedOn: 2026-11-24
summary: "Nimm Schublade, wenn dein Papierkram von selbst benannt und abgelegt werden soll, in einem Archiv in deinem eigenen Cloudflare-Konto, das der Haushalt nach Bedeutung durchsucht. Nimm Google Drive, wenn du kostenlosen Speicher ohne Einrichtung willst, heute Apps für jedes Gerät brauchst und jede Art von Datei ablegst."
aspects:
  - aspect: "Wo es läuft"
    schublade: "Ein Cloudflare Worker in deinem eigenen Cloudflare-Konto, bedient in jedem Browser."
    competitor: "Ein Dienst von Google, bedient über drive.google.com und die Apps von Google."
  - aspect: "Wer es pflegt"
    schublade: "Cloudflare betreibt die Plattform. Du richtest Schublade einmal ein und spielst neue Versionen mit einem Befehl ein."
    competitor: "Google. Du legst ein Konto an und fängst an."
  - aspect: "Texterkennung"
    schublade: "Schublade liest jeden Scan und jedes Foto beim Eingang. Eine lesbare PDF-Textebene bleibt, wie sie ist, andere Seiten liest das Bildmodell Moondream 3.1."
    competitor: "Die iPhone-App speichert Scans als durchsuchbare PDFs. Ein PDF oder Bild bis 2 MB lässt sich in ein Google-Dokument mit seinem Text umwandeln."
  - aspect: "Ablage"
    schublade: "Ein Sprachmodell setzt Titel, Datum, Absender, Kategorie und Haushaltsmitglied und liest Beträge und IBANs aus."
    competitor: "Ordner und Dateinamen wählst du selbst. Der Scanner der iPhone-App schlägt einen Titel vor."
  - aspect: "Suche"
    schublade: "Stichwort- und Bedeutungssuche über Sprachen hinweg, dazu Filter für Absender, Kategorie und Tag."
    competitor: "Suche nach Namen und Text mit Filtern für Typ, Personen und Datum. Mit Gemini fragst du in natürlicher Sprache."
  - aspect: "E-Mail-Eingang"
    schublade: "Du leitest Mails von einer erlaubten Adresse an die Adresse deines Archivs weiter. Eine Mail ohne Anhang druckt Schublade als PDF."
    competitor: "In Gmail legst du jeden Anhang einzeln von Hand in Drive ab (Add to Drive)."
  - aspect: "App fürs Handy"
    schublade: "iPhone-App mit Dokumentenscanner, Teilen-Menü und Offline-Kopie, bald verfügbar. Die Web-App läuft schon heute auf dem Handy."
    competitor: "Google-Drive-App fürs iPhone mit eingebautem Dokumentenscanner, heute verfügbar."
  - aspect: "App für den Mac"
    schublade: "Mac-App mit Leseansicht, Offline-Kopie und einem Sammler für ausgewählte Ordner, bald verfügbar."
    competitor: "Drive for desktop zeigt Drive im Finder und streamt oder spiegelt deine Dateien."
  - aspect: "Teilen im Haushalt"
    schublade: "Ein Haushalt pro Installation. Wer sich anmelden darf, sieht jedes Dokument."
    competitor: "Dateien und Ordner teilst du als Betrachter, Kommentator oder Bearbeiter. Bezahlten Speicher teilst du mit bis zu fünf weiteren Personen."
  - aspect: "Wo die Daten liegen"
    schublade: "In deinem Cloudflare-Konto, mit Dateien in R2 und Datensätzen in D1. Texterkennung und Einordnung laufen auf Workers AI im selben Konto."
    competitor: "Auf den Servern von Google, in deinem Google-Konto."
  - aspect: "Zugriff für KI-Assistenten (MCP)"
    schublade: "Eingebauter MCP-Zugang mit vier Werkzeugen, die nur lesen. Auf der Freigabeseite beschränkst du ihn auf bestimmte Kategorien, Absender und Tags."
    competitor: "Ein Drive-MCP-Server im Workspace Developer Preview Program von Google. Er braucht ein Google-Cloud-Projekt und einen OAuth-Client, und seine Werkzeuge können auch Dateien anlegen."
  - aspect: "Kosten"
    schublade: "Cloudflare Workers Paid, mindestens 5 USD im Monat (Preisseite von Cloudflare, gelesen am 24.11.2026), dazu etwa 0,0023 USD pro Dokument und 0,0008 USD pro erkannter Seite."
    competitor: "15 GB kostenlos. Google One Basic mit 100 GB kostet 1,99 EUR im Monat (Tarifseite von Google One, gelesen am 24.11.2026)."
sources:
  - title: "Google One: Tarife"
    url: "https://one.google.com/about/plans"
  - title: "Google-Drive-Hilfe: Convert PDF and photo files to text"
    url: "https://support.google.com/drive/answer/176692"
  - title: "Google-Drive-Hilfe: Search for files in Google Drive"
    url: "https://support.google.com/drive/answer/2375114"
  - title: "Google-Drive-Hilfe: Scan documents with Google Drive (iPhone und iPad)"
    url: "https://support.google.com/drive/answer/3145835?hl=en&co=GENIE.Platform%3DiOS"
  - title: "Google-Drive-Hilfe: Get updates and summaries on your files with Gemini in Drive"
    url: "https://support.google.com/drive/answer/16686465?hl=en"
  - title: "Google-Drive-Hilfe: Collaborate with Gemini in Google Drive"
    url: "https://support.google.com/drive/answer/14356148?hl=en"
  - title: "Google-Drive-Hilfe: Use Drive for desktop on macOS"
    url: "https://support.google.com/drive/answer/12178485?hl=en"
  - title: "Google-Drive-Hilfe: Share and manage access to files and folders"
    url: "https://support.google.com/drive/answer/2494822?hl=en"
  - title: "Gmail-Hilfe: Open and download attachments"
    url: "https://support.google.com/mail/answer/30719?hl=en&co=GENIE.Platform%3DDesktop"
  - title: "Google for Developers: Configure the Drive MCP server"
    url: "https://developers.google.com/workspace/drive/api/guides/configure-mcp-server"
  - title: "Cloudflare Workers: Preise"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## Ein Ordner voller Dateien oder ein Archiv, das selbst ablegt

Papierkram in einer Cloud abzulegen ist einfach. Du scannst einen Brief mit dem Handy, gibst ihm einen Namen und schiebst ihn in einen Ordner. Das klappt, bis du den einen Steuerbescheid von vor drei Jahren suchst und nicht mehr weißt, wie du die Datei genannt hast.

Google Drive ist allgemeiner Dateispeicher. Es nimmt jede Datei auf, synchronisiert sie auf deine Geräte und lässt dich Dateien und Ordner mit anderen teilen. Ordnung hältst du selbst. Die Drive-App auf dem iPhone scannt Papier zu durchsuchbaren PDFs, Namen und Ordner wählst du.

Schublade ist ein Archiv nur für Papierkram. Es läuft als ein Cloudflare Worker in deinem eigenen Cloudflare-Konto. Ein Sprachmodell auf Workers AI liest jedes Dokument und gibt ihm Titel, Datum, Absender, Kategorie und das Haushaltsmitglied, zu dem es gehört. Dazu liest es Felder wie Beträge und IBANs aus. Du benennst nie eine Datei und suchst nie einen Ordner aus.

## Für wen sich was eignet

Schublade passt zu einem Haushalt, der Rechnungen, Verträge und Kontoauszüge ohne Aufwand abgelegt haben und nach Bedeutung wiederfinden will. Die Suche findet Stichwörter und Bedeutungen, auch über Sprachen hinweg. Eine Rechnung leitest du per Mail weiter, und Schublade legt sie ab. Mehr dazu auf der Seite zur [Web-App](/de/web/).

Google Drive passt zu dir, wenn du Speicher ohne Einrichtung willst, für jede Art von Datei. Die Apps laufen heute schon auf Handy und Computer. Zahlst du ohnehin für Google-Speicher, kostet dich der Papierkram dort nichts extra.

## Wo Google Drive klar vorne liegt

- **Keine Einrichtung und ein kostenloser Einstieg.** Jedes Google-Konto bekommt 15 GB Speicher. Schublade braucht ein Cloudflare-Konto mit dem Workers-Paid-Tarif, eine Einrichtung über die Kommandozeile und kostet pro Dokument.
- **Apps heute.** Drive hat eine iPhone-App mit Scanner und Drive for desktop für den Mac. Die [iPhone-App](/de/iphone/) und die [Mac-App](/de/mac/) von Schublade funktionieren, sind aber noch nicht veröffentlicht.
- **Jede Datei.** Drive speichert Dokumente, Bilder, Audio und Video. Schublade nimmt PDF, JPEG, PNG und WebP an.
- **Teilen mit Rechten.** In Drive teilst du einzelne Dateien oder Ordner zum Ansehen, Kommentieren oder Bearbeiten. Schublade bedient einen Haushalt pro Installation, und alle, die sich anmelden, sehen alles.
- **Reife.** Schublade ist ein junges Open-Source-Projekt.

## Was Schublade anders macht

Schublade liest jede Seite beim Eingang. Ein PDF mit lesbarer Textebene behält diesen Text. Ein Scan oder Foto geht an ein Bildmodell, das auch quer fotografierte Seiten liest. In Drive macht der Scanner durchsuchbare PDFs, ein hochgeladenes Bild in Text umzuwandeln ist dagegen ein eigener Schritt und geht nur bis 2 MB.

Deine Dateien bleiben in deinem eigenen Cloudflare-Konto. Texterkennung und Einordnung laufen auf Workers AI in diesem Konto. Kein anderer KI-Anbieter sieht deine Dokumente, und du brauchst keinen API-Schlüssel.

Der E-Mail-Eingang ist eingebaut. Du leitest eine Mail von einer erlaubten Adresse an eine Adresse auf deiner Cloudflare-Domain weiter, und Schublade archiviert die Anhänge. In Gmail legst du jeden Anhang mit einem Klick einzeln in Drive ab.

Schublade hat einen eingebauten MCP-Zugang für Claude und andere MCP-Clients. Seine vier Werkzeuge lesen nur, und auf der Freigabeseite beschränkst du eine Verbindung auf die Kategorien, Absender und Tags, die du auswählst. Google bietet einen Drive-MCP-Server als Developer Preview an. Er braucht ein Google-Cloud-Projekt und einen OAuth-Client, und seine Werkzeuge können auch Dateien anlegen und kopieren.

## Von Google Drive zu Schublade umziehen

1. Richte Schublade mit `pnpm run provision` in deinem Cloudflare-Konto ein.
2. Hol deinen Papierkram auf den Computer. Drive for desktop kann deine Drive-Dateien (My Drive) spiegeln und hält dann eine vollständige Kopie deiner Dateien in einem Ordner auf dem Mac.
3. Schick die Dateien an Schublade. Lade sie im Browser hoch, 20 Dateien auf einmal, oder erstelle unter **Settings** einen Token und schick sie per Skript an `/api/documents/ingest`. Sobald die Mac-App erscheint, kann ihr Sammler den gespiegelten Ordner beobachten und nur die Dateien schicken, die im Archiv fehlen.

Deine Ordner kommen nicht mit, und Schublade gibt jedem Dokument einen eigenen Titel. Dateien außer PDF, JPEG, PNG und WebP bleiben in Drive. Schublade erkennt eine Datei am SHA-256 ihrer Bytes. Ein Dokument, das in zwei Drive-Ordnern liegt, wird im Archiv also ein Dokument, und einen abgebrochenen Upload kannst du gefahrlos wiederholen.
