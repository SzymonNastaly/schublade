---
title: "Support"
description: "Help with the Schublade apps: what you need, how to connect your archive, which token to issue, and how to scan without opening the app. Write to us by email."
updatedOn: 2026-11-24
---

Write to [schublade@szymonnastaly.com](mailto:schublade@szymonnastaly.com) with questions, problems, or ideas. Say which device and which version of the app you use. The version is at the bottom of Settings in the app. You can also report a problem on [GitHub](https://github.com/SzymonNastaly/schublade/issues).

## What does Schublade need?

The apps work with a Schublade archive that you run yourself. You deploy the archive once on your own Cloudflare account, and it then reads, files, and indexes every document you send it. The [deployment guide](https://github.com/SzymonNastaly/schublade#deploy) lists the steps, and [Schublade for the web](/web/) explains what the archive does. The apps have no account of their own and no server of their developer behind them.

## How do I connect the iPhone app?

1. Open your archive in the browser and go to **Settings**.
2. Under **API tokens**, choose **Schublade app: reads and adds documents** and issue the token. The archive shows the token only once, so copy it now.
3. Open Schublade on your iPhone. On **Connect Your Archive**, enter your archive's address and paste the token.

The app checks the token with your archive before it stores it. It then copies your archive's records to the phone, so the library opens and searches without a connection.

## Which token do I need?

The archive issues two kinds of token.

- **Adds documents.** For a scanner, a script, a Shortcut, or the folder collector on a Mac. It can send documents, but it cannot read a title, a text, or an original from your archive.
- **Reads and adds documents.** For the Schublade app. It sends documents and also reads your archive, which the app needs to show your library.

Settings starts with the first kind, so that reading is never the default. Revoke a token in Settings when you no longer need it. If the archive refuses the app's token, issue a new one and enter it under **Settings**, **Replace Token** in the app.

## How do I scan without opening the app?

- **Home Screen.** Touch and hold the Schublade icon, then choose **Scan Document**.
- **Control Center and Lock Screen.** Add the **Scan Document** control.
- **Action Button.** In the Settings app, choose **Action Button**, then **Shortcut**, then **Scan Document**.
- **Siri.** Say "Scan with Schublade".

## Which files can I send?

PDF, JPEG, PNG, and WebP, up to 25 MB per file. The app turns a HEIC photo into a JPEG before it sends it. You can share files to Schublade from any app through the share sheet, or pick them from Photos or Files.

## Why does a new document take a moment to appear?

Your archive reads each document before it files it. That takes seconds for a PDF with a text layer and longer for a photo. Search finds the document about one to two minutes later, once the archive has indexed it. If the archive cannot read a file, the document appears under **Failed documents** in the browser, where you can retry or delete it.

## How do I delete my data?

Delete a document in your archive in the browser. Deleting the app removes its copy of your archive and its token from the phone. Your archive and everything in it belong to you, so only you can delete them. The [privacy policy](/privacy/) has the details.
