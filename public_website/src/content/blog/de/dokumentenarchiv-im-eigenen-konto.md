---
title: "Warum dein Dokumentenarchiv in deinem eigenen Konto laufen sollte"
description: "Kontoauszüge, Verträge und Arztbriefe verraten viel über einen Haushalt. Warum Schublade in deinem eigenen Cloudflare-Konto läuft und was dich das kostet."
publishedOn: 2026-11-21
translationKey: own-account
tags: ["Selbst hosten", "Datenschutz"]
---

Der Papierkram eines Haushalts ist ein ziemlich genaues Protokoll seines Lebens. Kontoauszüge zeigen, wohin das Geld geht. Gehaltsabrechnungen zeigen, was reinkommt. Versicherungsschreiben, Arztrechnungen, der Mietvertrag und der Steuerbescheid ergänzen den Rest. Wer diese Schublade verwaltet, weiß sehr viel über dich.

Schublade ist so gebaut, dass du sie verwaltest. Es läuft als ein Cloudflare Worker in einem Cloudflare-Konto, das dir gehört, und jeder Teil bleibt dort. Hier liest du, was das praktisch bedeutet und wo dich diese Entscheidung etwas kostet.

## Was in deinem Konto bleibt

Jede Aufgabe in Schublade läuft auf einem Cloudflare-Dienst in deinem Konto.

| Was                                       | Wo es liegt                   |
| ----------------------------------------- | ----------------------------- |
| Originaldateien und erkannter Text        | R2                            |
| Datensätze wie Titel und Absender         | D1                            |
| Der Suchindex                             | AI Search                     |
| Lesen von Scans und Fotos                 | Images und Moondream 3.1 auf Workers AI |
| Einordnen der Dokumente                   | DeepSeek V4.1 Flash auf Workers AI, über AI Gateway |
| Anmeldung                                 | Cloudflare Access             |

Die Modelle laufen auf Workers AI unter deinem Konto. Du brauchst keinen API-Schlüssel eines anderen KI-Anbieters, und Schublade schickt deine Dokumente an keinen Dienst außerhalb deines Cloudflare-Kontos. Es gibt keinen Schublade-Server eines Dritten, der deine Dateien sieht, weil es so einen Server nicht gibt. Du spielst den Code selbst ein, und den Quellcode kannst du auf [GitHub](https://github.com/SzymonNastaly/schublade) lesen.

Damit bleibt ein Unternehmen im Spiel, nämlich Cloudflare als Betreiber der Infrastruktur. Cloudflare vertraust du so, wie du jedem Hoster vertraust. Einem zusätzlichen Dokumentendienst obendrauf musst du nicht vertrauen.

## Wer was sieht

Eine Installation gehört zu einem Haushalt. Wer sich anmelden kann, sieht alle Dokumente. Die Anmeldung läuft über Cloudflare Access. Beim Einrichten legst du fest, welche E-Mail-Adressen sich anmelden dürfen.

Der Worker ist im Zweifel zu. Fehlt die Access-Konfiguration, lehnt er jede Browseranfrage mit 403 ab. Es gibt keinen Demo-Nutzer und keine Ersatzidentität.

Alles, was kein Mensch im Browser ist, braucht ein Token, und jedes Token darf nur so viel wie nötig.

- Ein Token der Stufe `ingest` ist für einen Scanner, ein Skript oder den Sammler auf dem Mac. Es darf Dokumente hinzufügen. Titel, Text oder Original lesen darf es nicht.
- Ein Token der Stufe `read` ist für die iPhone- und die Mac-App. Es darf das Archiv lesen und Dokumente hinzufügen.

Unter Settings stellst du beide aus, und voreingestellt ist `ingest`. Lesen ist nie die Voreinstellung.

Ein KI-Assistent, den du über MCP anbindest, bekommt vier Werkzeuge, die nur lesen. Auf der Zustimmungsseite entscheidest du, ob er das ganze Archiv sieht oder nur einige Kategorien, Absender und Schlagwörter. Unter Settings trennst du ihn später wieder.

E-Mails kommen nur von Adressen an, die du freigibst, und nur wenn Cloudflares eigene Prüfung für die Domain des Absenders `dmarc=pass` meldet. Bevor Schublade eine Mail als PDF druckt, entfernt es Skripte, Frames und Weiterleitungen aus dem HTML.

## Was es kostet

Schublade selbst hat kein Abo. Du zahlst Cloudflare für das, was deine Installation verbraucht.

- Den Tarif Workers Paid, den Cloudflare mit [mindestens 5 US-Dollar im Monat pro Konto](https://developers.cloudflare.com/workers/platform/pricing/) berechnet.
- Etwa 0,0023 US-Dollar fürs Einordnen eines Dokuments.
- Etwa 0,0008 US-Dollar für jede Seite, deren Text erkannt werden muss. Ein PDF mit lesbarer Textebene überspringt diesen Schritt.
- Speicher in R2 und Anfragen an AI Search, abgerechnet nach Cloudflares Preisen für diese Produkte.

Für die meisten Haushalte bleiben die Modellkosten klein. Fünfzig einseitige Fotos im Monat kosten nach den Preisen oben etwa 0,12 US-Dollar fürs Einordnen und 0,04 US-Dollar fürs Lesen. Das ist gerechnet, nicht von einer echten Rechnung abgelesen.

## Die Nachteile

Das eigene Konto hat echte Nachteile. Du solltest sie kennen, bevor du anfängst.

### Du brauchst einen bezahlten Tarif

Schublade läuft heute nicht mit Workers Free. Das Rendern einer gescannten Seite braucht mehr Rechenzeit als die 10 ms, die der kostenlose Tarif erlaubt. Workers Free ist ein Ziel, aber auf einem echten kostenlosen Konto noch nicht getestet. Bis dahin sind die 5 US-Dollar Mindestbetrag die Untergrenze dessen, was Schublade dich kostet.

### Du hängst an Cloudflare

Jeder Teil von Schublade nutzt ein Cloudflare-Produkt. D1, R2, Workflows, AI Search, Workers AI, Images, Browser Run, Email Routing, Durable Objects und Access müssen in deinem Konto verfügbar sein. Schublade läuft weder bei einem anderen Cloud-Anbieter noch auf einem Server zu Hause. Wenn du Cloudflare verlässt, verlässt du auch Schublade.

### Du bist der Betreiber

Jemand im Haushalt richtet Schublade im Terminal mit Node.js und pnpm ein. Das Einrichtungsskript legt Datenbank, Speicher, Suchindex und Anmelderegeln an, und du kannst es gefahrlos erneut ausführen. Spätere Codeänderungen spielst du mit `pnpm run deploy` ein. Niemand sonst passt für dich auf deine Installation auf.

### Ein Haushalt, ein Archiv

Wer sich anmeldet, sieht alle Dokumente. Innerhalb eines Archivs gibt es keine Rechte pro Person. Für eine Familie oder eine WG, die ihren Papierkram gemeinsam ablegt, ist das so gewollt. Für eine Gruppe, die Dokumente voreinander verbergen muss, passt es nicht. Zwei Haushalte brauchen zwei Installationen.

### Die Suche ist nicht sofort aktuell

AI Search nimmt ein neues Dokument erst nach dem Archivieren in den Index auf. Auf der Entwicklungsinstanz dauerte das 73 bis 145 Sekunden, als 12 Uploads gleichzeitig ankamen. Einen Brief, den du gerade archiviert hast, findet die Textsuche vielleicht noch nicht. Die Liste und die Filter zeigen ihn sofort.

## Wann ein gehosteter Dienst besser passt

Wenn bei dir zu Hause niemand ein Terminal anfassen will, bist du mit einem gehosteten Dokumentendienst besser bedient. Wenn du ein Archiv für mehrere Haushalte mit getrennten Rechten brauchst, ist Schublade das falsche Werkzeug.

Wenn dir ein Cloudflare-Konto recht ist und dein Papierkram darin bleiben soll, bekommst du mit Schublade ein durchsuchbares Archiv, ohne die Schublade jemand anderem zu geben. Was Schublade kann, steht in [Schublade vorgestellt](/de/blog/schublade-vorgestellt/). Wie du es einrichtest, steht auf der [Seite zur Web-App](/de/web/).
