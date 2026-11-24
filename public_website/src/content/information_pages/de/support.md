---
title: "Support"
description: "Hilfe zu den Schublade-Apps: was du brauchst, wie du dein Archiv verbindest, welches Token du ausstellst und wie du ohne die App scannst. Schreib uns."
updatedOn: 2026-11-24
---

Schreib an [schublade@szymonnastaly.com](mailto:schublade@szymonnastaly.com), wenn du Fragen, Probleme oder Ideen hast. Nenn dabei dein Gerät und die Version der App. Die Version steht ganz unten in den Einstellungen der App. Ein Problem kannst du auch auf [GitHub](https://github.com/SzymonNastaly/schublade/issues) melden.

## Was braucht Schublade?

Die Apps arbeiten mit einem Schublade-Archiv, das du selbst betreibst. Du richtest das Archiv einmal in deinem eigenen Cloudflare-Konto ein. Danach liest, ordnet und indexiert es jedes Dokument, das du ihm schickst. Die [Anleitung zur Einrichtung](https://github.com/SzymonNastaly/schublade#deploy) nennt die Schritte, und [Schublade im Browser](/de/web/) erklärt, was das Archiv kann. Die Apps haben kein eigenes Konto, und hinter ihnen steht kein Server ihres Entwicklers.

## Wie verbinde ich die iPhone-App?

1. Öffne dein Archiv im Browser und geh zu **Settings**.
2. Wähl unter **API tokens** den Eintrag **Schublade app: reads and adds documents** und stell das Token aus. Das Archiv zeigt das Token nur einmal, also kopier es gleich.
3. Öffne Schublade auf deinem iPhone. Gib unter **Connect Your Archive** die Adresse deines Archivs ein und füge das Token ein.

Die App prüft das Token bei deinem Archiv, bevor sie es speichert. Danach kopiert sie die Einträge deines Archivs aufs Telefon. So öffnet und durchsucht sie deine Bibliothek auch ohne Verbindung.

## Welches Token brauche ich?

Das Archiv stellt zwei Arten von Token aus.

- **Adds documents.** Für einen Scanner, ein Skript, einen Kurzbefehl oder den Ordner-Sammler auf dem Mac. Damit lassen sich Dokumente senden, aber weder Titel noch Text noch Originale aus deinem Archiv lesen.
- **Reads and adds documents.** Für die Schublade-App. Damit lassen sich Dokumente senden und dein Archiv lesen. Das braucht die App, um deine Bibliothek zu zeigen.

Die Einstellungen beginnen mit der ersten Art, damit Lesen nie die Voreinstellung ist. Widerrufe ein Token in den Einstellungen, wenn du es nicht mehr brauchst. Lehnt das Archiv das Token der App ab, stell ein neues aus und trag es in der App unter **Settings**, **Replace Token** ein.

## Wie scanne ich, ohne die App zu öffnen?

- **Home-Bildschirm.** Halte das Schublade-Symbol gedrückt und wähl **Scan Document**.
- **Kontrollzentrum und Sperrbildschirm.** Füg das Steuerelement **Scan Document** hinzu.
- **Aktionstaste.** Wähl in der Einstellungen-App **Aktionstaste**, dann **Kurzbefehl**, dann **Scan Document**.
- **Siri.** Sag „Scan with Schublade“.

## Welche Dateien kann ich senden?

PDF, JPEG, PNG und WebP, bis 25 MB pro Datei. Ein HEIC-Foto wandelt die App vor dem Senden in ein JPEG um. Über das Teilen-Menü schickst du Dateien aus jeder App an Schublade, oder du wählst sie in Fotos oder Dateien aus.

## Warum erscheint ein neues Dokument nicht sofort?

Dein Archiv liest jedes Dokument, bevor es es ablegt. Bei einem PDF mit Textebene dauert das Sekunden, bei einem Foto länger. Die Suche findet das Dokument etwa ein bis zwei Minuten später, sobald das Archiv es indexiert hat. Kann das Archiv eine Datei nicht lesen, erscheint das Dokument im Browser unter **Failed documents**. Dort kannst du es erneut versuchen oder löschen.

## Wie lösche ich meine Daten?

Ein Dokument löschst du in deinem Archiv im Browser. Wenn du die App löschst, verschwinden ihre Kopie deines Archivs und ihr Token vom Telefon. Dein Archiv und alles darin gehören dir, also kannst nur du sie löschen. Details stehen in der [Datenschutzerklärung](/de/privacy/).
