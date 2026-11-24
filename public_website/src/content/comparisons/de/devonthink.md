---
title: "Schublade vs DEVONthink: Haushaltsarchiv oder Mac-Datenbank"
description: "Schublade oder DEVONthink für deinen Papierkram? Betrieb, Texterkennung, Ablage, E-Mail, iPhone- und Mac-Apps, Teilen im Haushalt und Preis im Vergleich."
competitor: "DEVONthink"
competitorUrl: "https://www.devontechnologies.com/apps/devonthink"
verifiedOn: 2026-11-24
summary: "Nimm Schublade, wenn dein Haushalt ein gemeinsames Archiv will, das Papierkram selbst einordnet und das alle im Browser erreichen. Nimm DEVONthink, wenn du am Mac arbeitest, deine Dokumente in einer lokalen Datenbank auch offline haben willst und Anmerkungen, Skripte und einen Einmalkauf schätzt."
aspects:
  - aspect: "Wo es läuft"
    schublade: "Ein Cloudflare Worker in deinem eigenen Cloudflare-Konto, bedient in jedem Browser."
    competitor: "Eine Mac-App ab macOS Ventura. Die Server-Edition ergänzt eine Weboberfläche für andere Geräte."
  - aspect: "Wer es pflegt"
    schublade: "Cloudflare betreibt die Plattform. Neue Versionen spielst du mit einem Befehl ein."
    competitor: "Du installierst und aktualisierst die App auf jedem Mac. Die Synchronisierung läuft über einen Ort, den du wählst."
  - aspect: "Texterkennung"
    schublade: "Nutzt die Textebene eines PDFs, wenn sie lesbar ist. Scans und Fotos liest das Bildmodell Moondream 3.1 auf Workers AI."
    competitor: "Scanner-Anbindung und Texterkennung gehören zu den Editionen Pro und Server."
  - aspect: "Automatische Einordnung"
    schublade: "Ein Sprachmodell setzt Titel, Datum, Absender, Kategorie und Haushaltsmitglied und liest Beträge und IBANs aus."
    competitor: "See Also und Classify schlagen in jeder Edition verwandte Dokumente und Gruppen vor. Pro ergänzt Tags und Zusammenfassungen durch ein generatives Modell."
  - aspect: "Suche"
    schublade: "Stichwort- und Bedeutungssuche über Sprachen hinweg, mit Cloudflare AI Search."
    competitor: "Durchsucht deine Datenbanken auf dem Mac. Pro ergänzt eine unterstützte Suche mit einem generativen Modell."
  - aspect: "E-Mail-Eingang"
    schublade: "Du leitest Mails von einer erlaubten Adresse an die Adresse deines Archivs weiter. Eine Mail ohne Anhang druckt Schublade als PDF."
    competitor: "Archiviert Mails aus Apple Mail und Microsoft Outlook auf dem Mac oder importiert Postfachdateien. Nur in Pro und Server."
  - aspect: "iPhone und iPad"
    schublade: "iPhone-App mit Dokumentenscanner, Teilen-Menü und Offline-Kopie, bald verfügbar. Die Web-App läuft schon heute auf dem Handy."
    competitor: "DEVONthink To Go für iPhone und iPad, mit Kamera-Scanner und Texterkennung. In Pro- und Server-Lizenzen enthalten."
  - aspect: "App für den Mac"
    schublade: "Mac-App mit Leseansicht, Offline-Kopie und einem Sammler für ausgewählte Ordner, bald verfügbar."
    competitor: "Native Mac-App, heute verfügbar in Version 4.4.2."
  - aspect: "Teilen im Haushalt"
    schublade: "Ein Haushalt pro Installation. Wer sich anmelden darf, sieht jedes Dokument."
    competitor: "Eine Lizenz gilt für zwei Macs. Die Server-Edition gibt anderen Zugriff im Browser, mit fein einstellbaren Rechten."
  - aspect: "Wo die Daten liegen"
    schublade: "In deinem Cloudflare-Konto, mit Dateien in R2 und Datensätzen in D1. Texterkennung und Einordnung laufen auf Workers AI im selben Konto."
    competitor: "Die Datenbanken bleiben auf deinem Mac. Sync-Daten in iCloud, Dropbox oder WebDAV lassen sich verschlüsseln."
  - aspect: "Zugriff für KI-Assistenten (MCP)"
    schublade: "Eingebauter MCP-Zugang mit vier Werkzeugen, die nur lesen. Auf der Freigabeseite beschränkst du ihn auf bestimmte Kategorien, Absender und Tags."
    competitor: "Seit Version 4.3 verbindet es sich mit KI-Apps, die MCP unterstützen, etwa Claude oder Codex. Pro arbeitet mit Online-Modellen und mit lokalen über Ollama oder LM Studio."
  - aspect: "Kosten"
    schublade: "Cloudflare Workers Paid, mindestens 5 USD im Monat (Preisseite von Cloudflare, gelesen am 24.11.2026), dazu etwa 0,0023 USD pro Dokument und 0,0008 USD pro erkannter Seite."
    competitor: "Einmalkauf mit einem Jahr Updates: Standard 99 USD, Pro 199 USD, Server 499 USD (Preisseite von DEVONthink, gelesen am 24.11.2026). Weitere Update-Jahre kosten extra."
sources:
  - title: "DEVONthink: Produktseite"
    url: "https://www.devontechnologies.com/apps/devonthink"
  - title: "DEVONthink: Preise"
    url: "https://www.devontechnologies.com/apps/devonthink/pricing"
  - title: "DEVONthink: Editionen"
    url: "https://www.devontechnologies.com/apps/devonthink/editions"
  - title: "DEVONthink: Versionshinweise"
    url: "https://www.devontechnologies.com/apps/devonthink/releases"
  - title: "DEVONthink To Go"
    url: "https://www.devontechnologies.com/apps/devonthinktogo"
  - title: "DEVONtechnologies-Blog: Scan in DEVONthink To Go"
    url: "https://www.devontechnologies.com/blog/20260609-scan-in-devonthink-to-go"
  - title: "DEVONtechnologies-Blog: DEVONthink sync"
    url: "https://www.devontechnologies.com/blog/20220628-devonthink-sync"
  - title: "DEVONtechnologies-Community-Blog: Discovering DEVONthink 4, Handling Email"
    url: "https://discourse.devontechnologies.com/t/discovering-devonthink-4-handling-email/84726"
  - title: "DEVONthink-3.8.2-Hilfe: The File Menu"
    url: "https://download.devontechnologies.com/download/devonthink/3.8.2/DEVONthink.help/Contents/Resources/pgs/menus-file.html"
  - title: "Cloudflare Workers: Preise"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## Verschiedene Werkzeuge, ähnliche Aufgaben

DEVONthink ist eine Dokumenten- und Wissensdatenbank für den Mac. Es hält deine Dokumente in Datenbanken auf dem Mac und gibt dir Werkzeuge, um sie zu kommentieren, zu verknüpfen, zu verschlagworten und per Skript zu bearbeiten. Es ist ein Allzweckwerkzeug, und Papierkram ist eine Sache, die du darin ablegen kannst.

Schublade macht genau eine Sache. Es ist ein Archiv für die Briefe, Rechnungen und Belege eines Haushalts und läuft als ein Cloudflare Worker in deinem eigenen Cloudflare-Konto. Ein Sprachmodell auf Workers AI liest jedes Dokument und gibt ihm Titel, Datum, Absender, Kategorie und das Haushaltsmitglied, zu dem es gehört. Alle im Haushalt melden sich im Browser an und sehen dasselbe Archiv.

## Für wen sich was eignet

Schublade passt zu einem Haushalt, in dem mehr als eine Person mit Papier zu tun hat und niemand sortieren will. Du leitest eine Mail weiter, fotografierst einen Brief oder schickst eine Datei mit einem Token, und ein paar Minuten später ist das Dokument abgelegt und auffindbar. Die Suche findet Stichwörter und Bedeutungen und arbeitet über Sprachen hinweg. Mehr dazu auf der Seite zur [Web-App](/de/web/).

DEVONthink passt zu dir, wenn du am Mac arbeitest und Dokumente selbst ordnen willst, mit Unterstützung. See Also und Classify schlagen vor, wohin ein Dokument gehört, dazu kommen intelligente Gruppen und Regeln. Mit der Pro-Edition kann ein generatives Modell verschlagworten und zusammenfassen. Außerdem ist DEVONthink ein Recherchewerkzeug, mit Anmerkungen, Newsfeeds, Leseliste und Skripten.

## Wo DEVONthink klar vorne liegt

- **Offline und lokal.** DEVONthink hält seine Datenbanken auf deinem Mac. Schublade braucht eine Netzverbindung und ein Cloudflare-Konto mit dem Workers-Paid-Tarif.
- **Apps, die du heute installieren kannst.** DEVONthink für den Mac und DEVONthink To Go für iPhone und iPad gibt es jetzt. Die [iPhone-App](/de/iphone/) und die [Mac-App](/de/mac/) von Schublade funktionieren, sind aber noch nicht veröffentlicht.
- **Tiefe.** Anmerkungen, Skripte, Regeln und die Wahl zwischen Online- und lokalen KI-Modellen gehen weit über Schublade hinaus. Schublade kennt keine Anmerkungen, und die Angaben eines Dokuments änderst du im Browser.
- **Preismodell.** DEVONthink kaufst du einmal und bekommst ein Jahr Updates. Schublade kostet einen monatlichen Cloudflare-Tarif plus einen kleinen Betrag pro Dokument.
- **Reife.** DEVONthink ist ein kommerzielles Produkt in der vierten Hauptversion. Schublade ist ein junges Open-Source-Projekt.

## Was Schublade anders macht

Schublade ordnet jedes Dokument ein, ohne Regeln und ohne Training. Die Felder, die es ausliest, etwa Beträge und IBANs, stehen neben dem Original, und du kannst sie im Browser korrigieren.

Schublade empfängt Mails selbst. Du leitest eine Nachricht von jedem Gerät an eine Adresse auf deiner Cloudflare-Domain weiter. DEVONthink archiviert Mails aus Apple Mail oder Outlook auf deinem Mac, der Import läuft also über den Mac.

Schublade ist für einen Haushalt gebaut. Eine Installation bedient einen Haushalt, und Cloudflare Access regelt, wer sich anmelden darf. Alle sehen alle Dokumente, und kein Dokument gehört nur einer Person. Bei DEVONthink hat jeder Mac seine eigenen Datenbanken. Wer sie mit einer anderen Person teilen will, braucht Sync oder die Server-Edition.

Beide verbinden sich über MCP mit KI-Assistenten. Der Zugang von Schublade gibt Claude oder einem anderen Client vier Werkzeuge, die nur lesen. Auf der Freigabeseite beschränkst du eine Verbindung auf die Kategorien, Absender und Tags, die du auswählst.

## Von DEVONthink zu Schublade umziehen

1. Wähle in DEVONthink die Dokumente aus und nimm den Exportbefehl für Dateien und Ordner (**File > Export > Files and Folders**). DEVONthink schreibt sie im Originalformat und behält deine Gruppen als Finder-Ordner.
2. Richte Schublade mit `pnpm run provision` in deinem Cloudflare-Konto ein.
3. Schick die exportierten Dateien. Lade sie im Browser hoch, 20 Dateien auf einmal, oder erstelle unter **Settings** einen Token und schick sie per Skript an `/api/documents/ingest`. Sobald die Mac-App erscheint, kann ihr Sammler den Exportordner beobachten und nur die Dateien schicken, die im Archiv fehlen.

Schublade nimmt PDF, JPEG, PNG und WebP an. Alles andere bleibt in DEVONthink. Gruppen, Tags und Anmerkungen kommen nicht mit, weil Schublade jedes Dokument neu einordnet. Schublade erkennt eine Datei am SHA-256 ihrer Bytes. Einen abgebrochenen Upload kannst du deshalb wiederholen, ohne Duplikate zu erzeugen.
