---
title: "Eine Datei, ein Dokument. Wie Schublade Duplikate vermeidet"
description: "Schublade erkennt jede Datei am SHA-256 ihrer Bytes. Was passiert, wenn du eine Datei doppelt hochlädst, löschst oder der Mac-Sammler einen Ordner schickt."
publishedOn: 2026-11-23
translationKey: content-identity
tags: ["Technik", "Duplikate"]
---

In einem Haushaltsarchiv sammeln sich Duplikate ganz von allein. Dieselbe Rechnung kommt als Mail-Anhang und liegt noch einmal im Download-Ordner. Ein PDF wandert vom Schreibtisch in den Scan-Ordner. Jemand lädt einen Kontoauszug hoch, den jemand anderes letzte Woche schon weitergeleitet hat. Ein naives Archiv legt jede Kopie als neues Dokument ab, und die Liste füllt sich mit Zwillingen.

Schublade führt zu jeder Datei genau ein Dokument, egal auf welchem Weg sie kommt. Hier liest du, woran Schublade erkennt, dass zwei Dateien gleich sind, was beim zweiten Upload und nach dem Löschen passiert und wie der Sammler auf dem Mac mit derselben Regel nur schickt, was dem Archiv fehlt.

## Eine Datei ist ihre Bytes

Schublade berechnet für jede Datei, die ankommt, den SHA-256-Hash. SHA-256 macht aus beliebigen Bytes einen Fingerabdruck aus 64 Zeichen. Zwei Dateien mit denselben Bytes haben denselben Fingerabdruck, und zwei Dateien, die sich in einem einzigen Byte unterscheiden, bekommen verschiedene.

So eine Bytefolge nennt Schublade einen Inhalt. Eine Tabelle in der Datenbank führt jeden Inhalt, den das Archiv je bekommen hat, und das Dokument, das ihn hält. Jedes Dokument speichert den Hash des Originals, das es zeigt.

Es zählen nur die Bytes. Dateiname, Ordner und Datum spielen keine Rolle. Daraus folgt zweierlei.

- Eine umbenannte oder verschobene Kopie ist dieselbe Datei. `Rechnung.pdf` im Download-Ordner und `stromrechnung_oktober.pdf` unter Dokumente sind ein Dokument, wenn ihre Bytes übereinstimmen.
- Ein zweiter Scan desselben Briefs ist eine neue Datei. Ein Scanner erzeugt nie zweimal dieselben Bytes, also werden zwei Scans einer Seite zwei Dokumente. Schublade rät nicht, ob zwei verschiedene Dateien dasselbe Papier zeigen.

## Der zweite Upload

Jeder Weg ins Archiv läuft über dieselbe Regel, ob Browser, Token aus einem Skript oder Kurzbefehl, Mail-Anhang oder Mac-Sammler. Bevor Schublade irgendetwas schreibt, berechnet es den Hash und schlägt ihn nach. Hält schon ein Dokument diese Bytes, antwortet der Upload mit `already_archived` und diesem Dokument, und die Upload-Anzeige sagt dir, dass die Datei schon im Archiv liegt. Nichts wird neu eingeordnet, nichts neu abgerechnet.

Zwei Uploads derselben neuen Datei können im selben Moment ankommen, etwa von zwei Handys. Schublade schreibt die neue Dokumentzeile und den Anspruch auf den Inhalt in einem Datenbank-Batch, den D1 als eine Transaktion ausführt, und liest den Anspruch danach zurück. Der Upload, der verloren hat, entfernt seine eigene Zeile und antwortet mit dem Dokument des Gewinners. Am Ende hat das Archiv in jedem Fall ein Dokument.

Eine E-Mail ohne brauchbaren Anhang druckt Schublade als PDF. Der Druckschritt berechnet den Hash dieses PDFs und meldet ihn nach derselben Regel an.

## Nach dem Löschen

Wenn du ein Dokument löschst, hat das Archiv zwei Möglichkeiten. Es kann die Datei vergessen, oder es merkt sich, dass du sie gelöscht hast.

Schublade merkt es sich. Der Inhalt bleibt in seiner Tabelle, nur ohne Dokument. Was dann passiert, hängt davon ab, wer die Bytes noch einmal schickt.

- **Du selbst.** Lädst du die Datei im Browser neu hoch, leitest sie erneut weiter oder schickst sie mit einem Token, archiviert Schublade sie wieder. Du hast dich entschieden, sie zu schicken, also kommt sie zurück.
- **Der Sammler.** Ein Programm, das Ordner beobachtet, soll ein gelöschtes Dokument nie zurückbringen, nur weil die Datei noch in einem Ordner liegt. Die Upload-Route des Sammlers antwortet bei einem gelöschten Inhalt mit `409`, bevor sie die Datei liest, und die Abfrage antwortet mit `deleted`.

Die iPhone-App zählt als Person. Ein Scan oder eine geteilte Datei läuft über dieselbe Route wie ein Upload im Browser, weil du dich entschieden hast, den Brief zu schicken, als du ihn gescannt hast.

## Wie der Sammler auf dem Mac das nutzt

Der Sammler in der [Mac-App](/de/mac/) beobachtet Ordner, die du auswählst. Er muss wissen, welche Dateien das Archiv schon hat, und er soll dafür kein PDF mit 20 MB hochladen. Mit dem Hash kann er vorher fragen.

1. Der Sammler liest eine Datei einmal und berechnet ihren SHA-256.
2. Er schickt bis zu 1000 Hashes in einer Anfrage an `POST /api/v1/contents/lookup`. Das Archiv antwortet für jeden mit `absent`, mit `present` und der Kennung des Dokuments oder mit `deleted`.
3. Er lädt nur die Dateien hoch, deren Antwort `absent` lautet, eine Datei pro Anfrage an `PUT /api/v1/contents/<hash>`. Das Archiv antwortet `202` für ein neues Dokument und `200` für eines, das es schon hat. Passen die Bytes nicht zum Hash in der Adresse, antwortet es `422`.

Weil alles am Hash hängt, brauchen die kniffligen Fälle keine Sonderbehandlung.

- **Dieselbe Datei in zwei Ordnern** ist ein Inhalt. Der Sammler schickt sie einmal.
- **Umbenennen oder Verschieben** innerhalb der beobachteten Ordner ändert den Pfad, nicht den Inhalt. Nichts wird neu geschickt.
- **Eine Datei, die du bearbeitest,** wird ein neuer Inhalt. Der Sammler fragt nach und schickt sie. Die alte Fassung bleibt im Archiv.
- **Eine Datei, die du auf dem Mac löschst,** bleibt im Archiv. Der Sammler kennt keine Anfrage, die löscht.
- **Eine verlorene Zustandsdatenbank** kostet einen neuen Durchlauf. Der Sammler liest jede Datei neu, die Abfrage antwortet für alles, was das Archiv schon hat, mit `present`, und nichts wird doppelt geschickt.

Fügst du einen Ordner hinzu, sieht der Sammler ihn zuerst durch. Er liest jede Datei, fragt nach und zeigt dir, wie viele dem Archiv fehlen. Erst dann fragt er, ob er diesen Bestand schicken soll. Du kannst ablehnen. Diese Dateien gehen dann nie raus, neue Dateien im Ordner aber schon.

Der Sammler nutzt ein Token der Stufe `ingest`. Damit kann er Dokumente hinzufügen und Hashes nachschlagen. Titel, Text oder Original lesen kann er damit nicht.

## Ältere Archive

Die Inhaltserkennung kam, nachdem die ersten Dokumente schon archiviert waren. Ein Archiv von davor berechnet die Hashes seiner älteren Dokumente im Hintergrund, 25 alle 15 Minuten. Bis jedes Dokument seinen Hash hat, antworten Abfrage und Upload des Sammlers mit `503` und einem `Retry-After`-Header. Sonst würde die Abfrage ein altes Dokument als `absent` melden, und der Sammler würde es ein zweites Mal archivieren.

## Was die Regel nicht erkennt

Die Regel ist exakt, und genau da liegt ihre Grenze. Zwei Scans eines Briefs, ein PDF und ein Foto desselben Belegs oder eine Rechnung, die der Absender zweimal mit neuem Zeitstempel im Inneren schickt, sind verschiedene Bytes und werden verschiedene Dokumente. Schublade legt jedes ab und ordnet jedes ein. Sie auseinanderzuhalten bleibt deine Sache, im Archiv.

Wie du mit dem Sammeln anfängst, steht auf der [Seite zur Mac-App](/de/mac/). Die Mac-App kommt bald. Tokens und Skripte funktionieren heute schon mit der [Web-App](/de/web/). Einen Überblick über alle Wege ins Archiv gibt [Schublade vorgestellt](/de/blog/schublade-vorgestellt/).
