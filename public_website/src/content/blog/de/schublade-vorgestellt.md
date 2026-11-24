---
title: "Schublade vorgestellt, dein selbst gehostetes Dokumentenarchiv"
description: "Schublade legt Rechnungen, Belege und Briefe deines Haushalts in deinem eigenen Cloudflare-Konto ab. Was es kann, für wen es passt und was es kostet."
publishedOn: 2026-11-20
translationKey: introducing-schublade
tags: ["Ankündigung", "Selbst hosten"]
---

Jeder Haushalt hat eine Schublade, in der die Post landet, mit Rechnungen, Kontoauszügen, dem Steuerbescheid und dem Mietvertrag. Schublade ist diese Schublade, nur digital, und sie steht in einem Cloudflare-Konto, das dir gehört. Du lädst ein PDF hoch, leitest eine E-Mail weiter oder fotografierst einen Brief. Schublade liest das Dokument, gibt ihm einen Titel, ein Datum, einen Absender, eine Kategorie und eine Person und macht seinen Text durchsuchbar. Du vergibst keine Schlagwörter und suchst keinen Ordner aus.

Hier erfährst du, was Schublade heute kann, auf welchen drei Wegen du es nutzt, für wen es gedacht ist und was der Betrieb kostet.

## Was mit einem Dokument passiert

Jedes Dokument durchläuft dieselben Schritte, egal wie es ankommt.

1. Schublade speichert die Originaldatei in R2, dem Objektspeicher von Cloudflare, in deinem Konto.
2. Es holt den Text jeder Seite. Ein PDF mit lesbarer Textebene liefert seinen Text direkt. Eine gescannte Seite oder ein Foto geht an Moondream 3.1, ein Bildmodell auf Workers AI, das den Text abschreibt.
3. Ein Sprachmodell auf Workers AI ordnet das Dokument ein. Es schreibt einen Titel und bestimmt Datum, Absender, Kategorie und das Haushaltsmitglied, um das es geht. Außerdem liest es Felder wie Beträge und IBANs aus.
4. Der Text kommt in einen AI-Search-Index, der Stichwortsuche und semantische Suche verbindet. Du kannst auf Deutsch suchen und einen englischen Brief finden.

Die Standardkategorien heißen Invoice, Receipt, Contract, Insurance, Tax Notice, Bank Statement, Medical und Official Identification, also Rechnung, Beleg, Vertrag, Versicherung, Steuerbescheid, Kontoauszug, Medizinisches und Ausweisdokument. Als Person kann das Modell nur ein Mitglied deines Haushalts nennen oder den Haushalt als Ganzes. Es kann also niemanden erfinden.

Kann Schublade eine Datei nicht öffnen oder eine Seite nicht lesen, landet das Dokument unter Failed documents. Dort startest du es neu oder löschst es.

## Vier Wege ins Archiv

Schublade nimmt PDF, JPEG, PNG und WebP an. Ein Upload fasst bis zu 20 Dateien, 25 MB pro Datei und 50 MB insgesamt.

- **Im Browser.** Zieh die Dateien ins Archiv. Auf dem Handy legst du Schublade auf den Home-Bildschirm und nimmst die Kamera.
- **Per E-Mail.** Leite eine Nachricht von einer freigegebenen Adresse an die Adresse weiter, die du eingerichtet hast. Schublade archiviert die Anhänge. Eine Mail ohne Anhang druckt es als PDF und archiviert sie so.
- **Mit Scanner, Skript oder Kurzbefehl.** Erstelle unter Settings ein Token und schick die Dateien ans Archiv. Jedes Programm, das ein Multipart-Formular senden kann, funktioniert.
- **Aus einem Ordner auf dem Mac.** Die Mac-App beobachtet Ordner, die du auswählst, und schickt nur die Dateien, die dem Archiv noch fehlen.

Schublade führt zu jeder Datei genau ein Dokument. Schickst du dieselben Bytes zweimal, auf welchem Weg auch immer, antwortet der zweite Upload mit dem Dokument, das sie schon enthält. Wie das funktioniert, steht in [Eine Datei, ein Dokument](/de/blog/eine-datei-ein-dokument/).

## Drei Apps

### Die Web-App

Die [Web-App](/de/web/) gibt es jetzt. Du richtest sie mit einem Befehl in deinem eigenen Cloudflare-Konto ein, und sie ist das vollständige Archiv. Sie listet Dokumente und filtert nach Absender, Kategorie, Person und Schlagwort. Sie sucht, zeigt das Original neben dem erkannten Text und den Details und lässt dich diese Details korrigieren. Fehlgeschlagene Dokumente startest du dort neu, Absender und Kategorien benennst du um oder führst sie zusammen, und Tokens stellst du dort aus. Offene Browserfenster zeigen ein neues Dokument, sobald es da ist.

### Die iPhone-App

Die [iPhone-App](/de/iphone/) kommt bald. Sie funktioniert schon, ist aber noch nicht im App Store. Sie ersetzt eine eigene Scanner-App. Du tippst auf Scan, die Dokumentenkamera des Systems findet die Seite und richtet sie gerade, und Save schickt alle Seiten als ein PDF ans Archiv. Du benennst den Scan nicht und wählst keinen Ordner, das erledigt das Archiv. Schublade taucht außerdem im Teilen-Menü von Mail, Dateien, Safari und Fotos auf. Uploads laufen im Hintergrund weiter. Ein Scan aus dem Keller ohne Netz kommt also später an.

Die App hält eine Kopie der Archivdaten auf dem iPhone. Du blätterst, suchst und liest darin, auch offline.

### Die Mac-App

Auch die [Mac-App](/de/mac/) kommt bald. Sie hat zwei Teile. Der Sammler beobachtet Ordner wie Downloads oder den Ausgabeordner deines Scanners. Fügst du einen Ordner hinzu, zählt er, was darin liegt und was dem Archiv fehlt, und fragt, bevor er den Bestand schickt. Danach schickt er neue Dateien von selbst. Die Bibliothek ist ein natives Fenster mit Liste, Leseansicht und Inspektor. Sie arbeitet auf einer lokalen Kopie, also antwortet die Suche bei jedem Tastendruck, auch im Zug.

Bearbeiten, Löschen und die Verwaltung der Tokens bleiben bei beiden nativen Apps im Browser.

## Für wen Schublade gedacht ist

Schublade passt zu einem Haushalt, der seinen Papierkram an einem Ort und durchsuchbar haben will und bereit ist, ihn im eigenen Cloudflare-Konto zu betreiben. Eine Installation gehört zu einem Haushalt. Wer sich anmelden kann, sieht alle Dokumente. Die Anmeldung läuft über Cloudflare Access, und der Worker lehnt jede Browseranfrage ohne gültige Anmeldung ab.

Es passt zu dir, wenn du Kontoauszüge und Arztbriefe nicht bei einem fremden Dokumentendienst ablegen willst. Dateien, Datenbank, Suchindex und Modellaufrufe bleiben in deinem Konto. Einen API-Schlüssel eines anderen KI-Anbieters brauchst du nicht.

Es passt nicht zu einem Team, das innerhalb eines Archivs getrennte Rechte pro Person braucht. Es passt auch nicht, wenn du eine App installieren und dann vergessen willst. Jemand im Haushalt muss Schublade einrichten und das Cloudflare-Konto pflegen.

Du kannst auch einen KI-Assistenten wie Claude anbinden. Trag die `/mcp`-Adresse deines Archivs als Connector ein. Auf einer Zustimmungsseite gibst du das ganze Archiv frei oder nur ausgewählte Kategorien, Absender und Schlagwörter. Der Assistent bekommt vier Werkzeuge, mit denen er Dokumente sucht, auflistet und liest, aber nichts ändert.

## Was es kostet

Schublade braucht den Tarif Workers Paid. Cloudflare berechnet dafür [mindestens 5 US-Dollar im Monat pro Konto](https://developers.cloudflare.com/workers/platform/pricing/). Workers Free ist ein Ziel. Heute braucht das Rendern einer gescannten Seite aber mehr Rechenzeit als die 10 ms, die der kostenlose Tarif erlaubt. Für die Anmeldung brauchst du Cloudflare Zero Trust, dessen kostenloser Tarif 50 Nutzer abdeckt.

Die Modellaufrufe zahlst du nach Verbrauch. Das Einordnen eines Dokuments kostet etwa 0,0023 US-Dollar. Jede Seite, deren Text erkannt werden muss, kostet etwa 0,0008 US-Dollar dazu. Ein PDF mit lesbarer Textebene braucht keine Texterkennung.

Ein Rechenbeispiel. Bei 100 Dokumenten im Monat, davon die Hälfte einseitige Fotos, kommst du auf etwa 0,23 US-Dollar fürs Einordnen und 0,04 US-Dollar für die Erkennung. Das ist deutlich unter einem Dollar zusätzlich zum Tarif. Die Zahl ist aus den Preisen pro Dokument gerechnet, nicht von einer echten Rechnung abgelesen. Speicher und Suche rechnet Cloudflare nach seinen eigenen Preisen für R2 und AI Search ab, und die Summe hängt davon ab, wie viel du aufbewahrst.

## Wo du anfängst

Der Quellcode liegt auf [GitHub](https://github.com/SzymonNastaly/schublade). Die [Seite zur Web-App](/de/web/) führt dich durch die Einrichtung. Warum Schublade in deinem eigenen Konto läuft, steht in [Warum dein Dokumentenarchiv in deinem eigenen Konto laufen sollte](/de/blog/dokumentenarchiv-im-eigenen-konto/). Wie es einen zerknitterten Kassenbon liest, steht in [Wie Schublade einen fotografierten Beleg liest](/de/blog/wie-schublade-einen-fotografierten-beleg-liest/).
