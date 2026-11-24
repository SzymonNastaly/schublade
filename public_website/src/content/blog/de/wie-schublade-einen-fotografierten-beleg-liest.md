---
title: "Wie Schublade einen fotografierten Beleg liest"
description: "Vom schiefen Handyfoto zum durchsuchbaren Text. Wie Schublade die Textquelle wählt, Fotos aufrichtet, mit Moondream liest und gedrehte Seiten erkennt."
publishedOn: 2026-11-22
translationKey: reading-receipts
tags: ["Texterkennung", "Technik"]
---

Der Kassenbon aus der Apotheke kommt als Handyfoto bei Schublade an. Er ist leicht schief, auf Thermopapier gedruckt und liegt im Speicher auf der Seite, weil Handys die meisten Hochformatfotos so ablegen. Ein paar Minuten später steht er im Archiv als Beleg mit Titel, Datum, Absender und Betrag, und die Suche nach dem Namen der Apotheke findet ihn.

Hier geht es darum, was dazwischen passiert. Zuerst kommt der günstige Weg, weil die meisten Dokumente den teuren nie brauchen.

## Zuerst die Textebene

Viele Dokumente kommen als PDF, das seinen Text schon enthält. Die Rechnung aus dem Onlineshop, der Kontoauszug oder ein Brief aus der Textverarbeitung haben eine Textebene, also den unsichtbaren Text, den du im PDF-Viewer markieren kannst. Den zu lesen kostet nichts. Ein Bildmodell über die Seite laufen zu lassen kostet Geld und Zeit und kann sich irren.

Deshalb wählt Schublade für jede Seite eines PDFs eine von drei Textquellen, in dieser Reihenfolge.

1. **Der umgewandelte Abschnitt.** Cloudflares Umwandlung `toMarkdown()` macht aus dem PDF Markdown und behält Tabellen als Tabellen. Schublade nimmt den Abschnitt einer Seite, wenn er mindestens 40 Buchstaben oder Ziffern enthält und mindestens 90 % der Buchstaben und Ziffern aus der Textebene der Seite.
2. **Die Textebene.** PDFium, als WebAssembly übersetzt, liest die Textebene direkt aus. Schublade nimmt sie, wenn sie mindestens 40 Buchstaben oder Ziffern enthält und weniger als ein Ersatzzeichen auf zehn davon. Eine Schrift ohne brauchbare Zeichenzuordnung kommt als Ersatzzeichen heraus, also fällt so eine Seite durch.
3. **Texterkennung.** Nur eine Seite, die an beiden Prüfungen scheitert, geht an das Bildmodell.

### Wozu die 90-Prozent-Regel da ist

Meistens funktioniert die Umwandlung gut. Auf allen 27 digitalen Seiten der Testdokumente von Schublade enthielt eine vollständige Umwandlung jeden Buchstaben und jede Ziffer der Textebene. Chromium druckt aber getaggte PDFs, und bei einer weitergeleiteten E-Mail behielt `toMarkdown()` nur die drei Kopfzeilen von Seite 1, ließ die Layouttabellen darunter weg und lieferte Seite 2 leer. PDFium las beide Seiten vollständig.

Der 90-Prozent-Vergleich fängt diesen Fall ab. Enthält die Umwandlung deutlich weniger Text als die Textebene, verlässt sich Schublade auf die Textebene. So eine Seite kostet dann kein Rendern und keine bezahlte Erkennung.

Eine gescannte Seite fällt durch die ersten beiden Prüfungen, weil ihre Textebene leer oder fast leer ist. Unter 40 Buchstaben und Ziffern gilt sie als Scan. Ein Foto hat gar keine Textebene und geht direkt zur Erkennung.

## Das Foto aufrichten

Beim Foto des Kassenbons gibt es einen Haken. Ein Handy speichert die Pixel eines Hochformatfotos quer und schreibt die Drehung in ein EXIF-Feld. Fotoprogramme lesen das Feld und drehen das Bild für die Anzeige. Moondream, das Modell, mit dem Schublade Text erkennt, liest die gespeicherten Pixel und übergeht das Feld. Es sieht den Bon quer.

Das ist kein kleiner Fehler. Ein Haushaltsmitglied fotografierte einen gedruckten A4-Brief mit dem iPhone. Der Upload klappte, dann hing das Dokument sechs Minuten in "Recognizing text" und schlug fehl. Das Foto hatte 4032 mal 3024 Pixel und die Ausrichtung 6 im EXIF-Feld. In einem Lauf auf den gespeicherten Pixeln schrieb das Modell 13.096 Zeichen und hörte erst an seiner Tokengrenze auf. Dasselbe Foto, aufrecht gedreht, kam nach 4,8 Sekunden zurück und war bis auf ein paar Wörter richtig.

Seitdem geht jedes hochgeladene Bild durch Cloudflare Images, bevor das Modell es sieht. Das Images-Binding wendet die EXIF-Ausrichtung an. Es verkleinert das Bild außerdem auf höchstens 1600 Pixel an der langen Kante und schreibt ein JPEG mit Qualität 90 auf weißem Hintergrund. Der weiße Hintergrund ist wichtig. Ohne ihn kamen durchsichtige Pixel schwarz zurück, und schwarzer Text auf einem durchsichtigen PNG verschwand.

Nach dieser Änderung war das ursprüngliche Handyfoto auf einer echten Installation nach 27 Sekunden archiviert, mit einem Moondream-Aufruf von 6,9 Sekunden.

Gescannte PDF-Seiten nehmen einen anderen Weg zum selben Ziel. PDFium rendert jede Seite, die erkannt werden muss, als Graustufen-PNG mit 150 dpi.

## Die Seite mit Moondream lesen

Schublade schickt das aufrechte Bild an Moondream 3.1 auf Workers AI, über AI Gateway in deinem Konto. Es bittet das Modell, den gesamten Text genau so abzuschreiben, wie er gedruckt ist, Zeile für Zeile, und Zahlen, Daten, Beträge und IBANs zu erhalten. Die Temperatur ist 0. Den Cache des Gateways umgeht Schublade, weil eine zwischengespeicherte Antwort auf dieselben Bytes beim erneuten Versuch einen falschen Lesevorgang wiederholen würde.

Die Antwort kommt als Strom von Ereignissen, und jedes Ereignis wiederholt die ganze bisherige Antwort. Schublade liest den Strom Zeile für Zeile und behält nur das letzte Ereignis. Das letzte Ereignis enthält auch den Grund, warum das Modell aufgehört hat. Lautet er `length`, ist das Modell an seine Grenze von 2048 Ausgabetokens gestoßen, und die Seite ist nie fertig geworden. Diesen Text behält Schublade nicht. Aufrechte Testseiten brauchten höchstens 597 Tokens. Eine Seite, die 2048 erreicht, ist also fast immer eine, die das Modell nicht lesen konnte.

Hier passiert noch eine Reparatur. Moondream liefert manchmal ein Ersatzzeichen, wo ein Eurozeichen gedruckt war. Steht dieses Zeichen direkt vor oder hinter einem Betrag wie `12,49`, setzt Schublade das Eurozeichen wieder ein.

## Stößt eine Seite an die Grenze, liest Schublade sie vierfach

EXIF deckt den häufigen Fall des Handyfotos ab. Es hilft nicht bei einem Scan, der falsch herum im Einzug lag, oder bei einem Foto ohne das Feld. Solche Seiten erreichen das Modell quer oder kopfüber, und das Modell dreht sich im Kreis, bis es an die Grenze stößt.

Stößt der erste Lesevorgang einer Seite an die Tokengrenze, liest Schublade die Seite in den anderen drei Drehungen, also 90, 180 und 270 Grad, in parallelen Schritten des Workflows. Es behält den Lesevorgang mit den meisten verschiedenen Wörtern. Die Wörter zählt `Intl.Segmenter`, deshalb klappt das Zählen auch in Schriften ohne Leerzeichen zwischen den Wörtern. Ein Lesevorgang, der sich im Kreis dreht, wiederholt sich und hat deshalb wenige verschiedene Wörter, selbst wenn er lang ist.

Die gewinnende Drehung speichert Schublade am Dokument. Spätere Seiten fangen mit dieser Drehung an, weil die Seiten eines Scans meist gleich liegen. In einem Test brauchte ein zweiseitiger querer Scan fünf Lesevorgänge statt acht.

Ein Dokument scheitert mit "unreadable page" erst, wenn keine Drehung fertig wird. Es erscheint dann unter Failed documents, wo du es neu startest oder löschst.

### Warum nicht jede Seite viermal

Jede Seite in vier Drehungen zu lesen würde jede erkannte Seite viermal so teuer machen. Es schadet auch. In einer Wiederholung aufgezeichneter Lesevorgänge drehte die Regel "nimm immer den längsten von vier" 5 von 25 aufrechten Seiten falsch herum. Die Prüfung nur nach einem Fehlschlag ließ alle 25 aufrechten Seiten in Ruhe.

Die Prüfung hat eine bekannte Lücke. Eine falsche Drehung kann manchmal normal enden, mit flüssigem, erfundenem Text, und eine Prüfung, die nur nach einem Fehlschlag läuft, sieht das nicht. Das Problem ist offen, und die [Forschungsnotizen zur Texterkennung](https://github.com/SzymonNastaly/schublade/blob/main/docs/research/optical_character_recognition_with_vision_models.md) im Repository sammeln Ideen dazu.

## Vom Text zum abgelegten Beleg

Sobald jede Seite Text hat, fügt Schublade die Seiten zu einem Markdown-Dokument zusammen. Ein Sprachmodell liest es und füllt Titel, Datum, Absender, Kategorie, Person und Felder wie den Betrag aus. Der Text kommt in den Suchindex, und nach ein paar Minuten findet die Suche den Beleg.

Die Kosten folgen dem Weg. Ein PDF mit lesbarer Textebene braucht keine Erkennung. Jede erkannte Seite kostet etwa 0,0008 US-Dollar, das Einordnen etwa 0,0023 US-Dollar pro Dokument. Eine Seite, die an die Grenze stößt, kostet drei Lesevorgänge mehr, und die späteren Seiten desselben Dokuments fangen mit der Drehung an, die funktioniert hat.

Das Foto schickst du mit der [Web-App](/de/web/) vom Handy aus oder scannst es mit der [iPhone-App](/de/iphone/), sobald sie erschienen ist. In beiden Fällen liest das Archiv. Den Überblick gibt [Schublade vorgestellt](/de/blog/schublade-vorgestellt/).
