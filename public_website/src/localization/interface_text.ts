import type { PlatformSectionName } from "../platform_presentation.ts"
import type { ScreenshotName } from "../screenshots.ts"
import type { Platform, PlatformAvailability } from "../site_configuration.ts"
import type { Locale } from "./locales.ts"

interface SectionText {
	heading: string
	paragraphs: ReadonlyArray<string>
	/** A shell command shown below the paragraphs, identical in every locale. */
	command?: string
}

interface PageMetadataText {
	title: string
	description: string
}

interface PlatformPageText<P extends Platform> extends PageMetadataText {
	linkLabel: string
	heading: string
	introduction: string
	availabilityNote: string
	landingSummary: string
	sections: Record<PlatformSectionName<P>, SectionText>
}

export interface InterfaceText {
	navigation: {
		skipToContent: string
		homeLabel: string
		primaryLabel: string
		breadcrumbLabel: string
		comparisons: string
		blog: string
		languageLabel: string
	}
	availability: Record<PlatformAvailability, string>
	landing: PageMetadataText & {
		headline: string
		subheadline: string
		deployAction: string
		platformsAction: string
		platformsHeading: string
		stepsHeading: string
		steps: ReadonlyArray<{ title: string; text: string }>
		/** Short facts under the hero's actions that say who runs the archive. */
		principles: ReadonlyArray<string>
		ownershipHeading: string
		ownershipLead: string
		ownershipItems: ReadonlyArray<{ title: string; text: string }>
		ownershipCosts: string
		sourceAction: string
		licenseAction: string
	}
	platformPages: { [P in Platform]: PlatformPageText<P> }
	platformPage: {
		deployAction: string
		appStoreAction: string
		deployArchiveAction: string
		relatedPostsHeading: string
		comparisonsHeading: string
	}
	screenshotDescriptions: Record<ScreenshotName, string>
	comparisonIndex: PageMetadataText & { heading: string; introduction: string; empty: string }
	comparison: {
		aspectColumn: string
		schubladeColumn: string
		sourcesHeading: string
		checkedOn: (date: string) => string
	}
	blogIndex: PageMetadataText & { heading: string; introduction: string; empty: string; feedLabel: string }
	blogPost: {
		readingTime: (minutes: number) => string
		updatedOn: (date: string) => string
		tagsLabel: string
		/** The link to this locale's version of a post, written in this locale. */
		readInThisLanguage: string
		morePostsHeading: string
	}
	breadcrumbHome: string
	footer: {
		summary: string
		productHeading: string
		resourcesHeading: string
		informationHeading: string
		sourceCode: string
		feed: string
	}
	notFound: { title: string; heading: string; text: string; homeAction: string }
}

const english: InterfaceText = {
	navigation: {
		skipToContent: "Skip to content",
		homeLabel: "Schublade home",
		primaryLabel: "Main",
		breadcrumbLabel: "Breadcrumb",
		comparisons: "Compare",
		blog: "Blog",
		languageLabel: "Language",
	},
	availability: { available: "Available now", coming_soon: "Coming soon" },
	landing: {
		title: "Schublade: a self-hosted archive for your paperwork",
		description:
			"Schublade reads, names, and files your letters, invoices, and receipts on your own Cloudflare account. Scan, upload, or forward mail, then search everything.",
		headline: "Your paperwork, read, filed, and easy to find.",
		subheadline:
			"Schublade is open-source software that you run on your own Cloudflare account. Send it a letter, an invoice, or a photo of a receipt. It names and files the document, and you find it again with a search.",
		deployAction: "Deploy it",
		platformsAction: "Web, iPhone, and Mac",
		platformsHeading: "One archive, three ways to use it",
		stepsHeading: "How it works",
		steps: [
			{
				title: "Send",
				text: "Upload in the browser, forward an email, scan with your iPhone, or let your Mac collect a folder.",
			},
			{
				title: "It reads and files",
				text: "Schublade reads every page and gives the document a title, a date, a sender, a category, and a person. It also picks out amounts and IBANs.",
			},
			{
				title: "Find",
				text: "Search by keyword or by meaning, across languages. Each file is kept once, however often it arrives.",
			},
		],
		principles: ["Open source (AGPL-3.0)", "Runs on your own Cloudflare account", "Your documents never reach us"],
		ownershipHeading: "Open source. Self-hosted. Bring your own everything.",
		ownershipLead:
			"Schublade is software, not a service. There is no Schublade account and no Schublade server. You deploy the archive to your own Cloudflare account, and every app talks only to that archive. Your documents never reach us.",
		ownershipItems: [
			{
				title: "Your Cloudflare account",
				text: "The Worker, the database, the file storage, and the search index are created on your account, and Cloudflare bills you directly.",
			},
			{
				title: "Your AI",
				text: "Workers AI on your account reads and classifies each document. You need no third-party model provider and no API key.",
			},
			{
				title: "Your address and sign-in",
				text: "The archive answers at your address, behind Cloudflare Access, for the email addresses you allow.",
			},
			{
				title: "Your copy of the code",
				text: "The source code is on GitHub under the AGPL-3.0. Read it, change it, and deploy your own version.",
			},
		],
		ownershipCosts:
			"You need a Cloudflare account on the Workers Paid plan. Classifying a document costs about 0.0023 USD, and reading a scanned page or a photo about 0.0008 USD. A PDF with a readable text layer skips text recognition.",
		sourceAction: "Source code on GitHub",
		licenseAction: "AGPL-3.0 license",
	},
	platformPages: {
		web: {
			title: "Schublade for the web: your document archive in the browser",
			description:
				"Deploy Schublade on your own Cloudflare account. Upload files, forward email, or post from a script, then find any document with search across languages.",
			linkLabel: "Schublade for the web",
			heading: "Your archive in the browser",
			introduction:
				"The web app is the archive itself. You deploy it to your own Cloudflare account, and everyone in your household signs in to the same documents.",
			availabilityNote: "Open source. You deploy it yourself, from the source code on GitHub.",
			landingSummary: "The full archive in your browser. Upload files, forward email, or post them from a script.",
			sections: {
				arrival: {
					heading: "Four ways in",
					paragraphs: [
						"Upload in the browser: up to 20 files at once, 25 MB each and 50 MB in total. Schublade accepts PDF, JPEG, PNG, and WebP. On a phone, add Schublade to your home screen and use the camera.",
						"Forward mail from an allowed address to the address you set up. Schublade archives the attachments and prints a message without one to a PDF.",
						"Issue a token in Settings and post files from a scanner or a script. Any app that sends a multipart form works, such as an Apple Shortcut.",
						"A collector watches your folders, asks the archive which files it lacks, and sends only those.",
					],
				},
				reading: {
					heading: "It reads every page",
					paragraphs: [
						"Schublade gives each document a title, a date, a sender, a category, and a person, and it extracts fields such as amounts and IBANs.",
						"A PDF with a readable text layer is read from that layer. Scans and photos are read by a vision model on Workers AI. A page that comes out sideways is read in all four rotations, and Schublade keeps the best reading.",
					],
				},
				search: {
					heading: "Search across languages",
					paragraphs: [
						"Search combines keywords with meaning, so a search finds a document even when its words differ from yours. Filter the archive by sender, category, or tag, and rename or merge them when your filing changes.",
					],
				},
				identity: {
					heading: "Each file is kept once",
					paragraphs: [
						"Schublade names every file by the SHA-256 of its bytes. Send the same file again, by any route, and you get the document that already holds it. A renamed or moved copy is the same file. Another scan of the same letter is a new one.",
						"After you delete a document, Schublade remembers its file, so a collector never sends it back.",
					],
				},
				access: {
					heading: "Sign-in and AI clients",
					paragraphs: [
						"Cloudflare Access handles sign-in. One deployment serves one household, and everyone who can sign in sees every document.",
						"Add your archive as a connector in Claude or another MCP client. A consent page lets you allow the whole archive or only the categories, senders, and tags you choose. The client gets four read-only tools.",
					],
				},
				requirements: {
					heading: "What you need",
					paragraphs: [
						"A Cloudflare account on the Workers Paid plan with Cloudflare Zero Trust enabled. The Zero Trust free plan covers 50 users. On your computer you need Node.js 24.22 or later and pnpm.",
						"One command creates every resource on your account, deploys the Worker behind Cloudflare Access, and can set up a custom domain and an email address.",
					],
					command:
						"pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json",
				},
			},
		},
		iphone: {
			title: "Schublade for iPhone: scan paper straight into your archive",
			description:
				"Scan a letter with your iPhone and it lands in your Schublade archive. Share files from any app, and read and search your documents offline.",
			linkLabel: "Schublade for iPhone",
			heading: "Scan paper where it arrives",
			introduction:
				"Paper reaches you on the kitchen table, not at a desk. The iPhone app turns a letter into an archived document in one step and carries your whole archive with you.",
			availabilityNote:
				"Free on the App Store. The app connects to an archive you deployed yourself, and it has no account or server of its own.",
			landingSummary: "Scan paper with the camera, share files from any app, and read your archive offline.",
			sections: {
				scan: {
					heading: "Scan a letter in one step",
					paragraphs: [
						"Scan opens the system's document camera. Save sends all pages as one PDF. A finished scan needs no name, no folder, and no second confirmation.",
						"The scan appears under Arriving while the archive reads it, and turns into a document with a title moments later.",
					],
				},
				shortcuts: {
					heading: "Start a scan without opening the app",
					paragraphs: [
						"Start scanning from the Home Screen icon, a Control Center or Lock Screen control, the Action button, or Siri.",
					],
				},
				share: {
					heading: "Send from any app",
					paragraphs: [
						"Schublade sits in the share sheet of Mail, Files, Safari, Photos, and every app that shares files. You can also import from Photos and Files.",
						"A scan taken without a network reaches the archive later, without you opening the app again.",
					],
				},
				library: {
					heading: "Your archive, also offline",
					paragraphs: [
						"The app keeps a copy of your archive's records on the phone. Browse by category, sender, or person, and search titles, details, and text, also without a network.",
					],
				},
				details: {
					heading: "Read the original and its details",
					paragraphs: [
						"Open a document to see the original page with its date, amount, due date, and IBAN below it. Tap a fact to copy it, to pay a bill for example.",
						"Editing, deleting, and retrying stay in the browser.",
					],
				},
			},
		},
		mac: {
			title: "Schublade for Mac: a native library for your archive",
			description:
				"A native Mac app for your Schublade archive. Read and search every document offline, and let it collect the folders where your PDFs and scans land.",
			linkLabel: "Schublade for Mac",
			heading: "Your archive as a Mac library",
			introduction:
				"The Mac app is a native window onto your archive, with a sidebar, a list, a reader, and an inspector. It also collects the folders where your paperwork lands.",
			availabilityNote: "The app works with your archive today. There is no public download yet.",
			landingSummary: "A native library with a reader and an inspector. It collects the folders you choose.",
			sections: {
				library: {
					heading: "Find a document and read it",
					paragraphs: [
						"Browse by person, category, tag, or sender. Walk the list with the arrow keys and the reader follows. Press Space for Quick Look.",
						"The inspector shows the date, amount, due date, and IBAN, ready to copy. Drag a document into Mail or the Finder.",
					],
				},
				search: {
					heading: "Search as you type",
					paragraphs: [
						"Search answers on every keystroke from a copy of your archive on the Mac, also offline. Matches in the text show the sentence around the word you typed.",
					],
				},
				collection: {
					heading: "It collects your folders",
					paragraphs: [
						"Choose folders such as Downloads or the one your scanner writes to. Schublade watches them, asks the archive which files it lacks, and sends only those.",
						"When a folder already holds files, Schublade asks before it sends them. After that, every new PDF, JPEG, PNG, or WebP file in the folder is sent on its own.",
					],
				},
				menuBar: {
					heading: "Quiet in the menu bar",
					paragraphs: [
						"A drawer in the menu bar shows uploads in progress and the five newest documents. Schublade speaks up only when a folder needs a decision or the archive refuses its token.",
					],
				},
			},
		},
	},
	platformPage: {
		deployAction: "Deploy it",
		appStoreAction: "Download on the App Store",
		deployArchiveAction: "Deploy your archive",
		relatedPostsHeading: "From the blog",
		comparisonsHeading: "Compare Schublade",
	},
	screenshotDescriptions: {
		iphone_library_arriving:
			"The iPhone library: a three-page scan arriving at the top while its text is recognized, and documents grouped by month below.",
		iphone_search_category: "The iPhone library narrowed to the Invoice category, with the search field at the bottom.",
		iphone_document_details:
			"An invoice on the iPhone with its details sheet: date, amount, due date, IBAN, and invoice number.",
		iphone_share_sheet: "The Schublade share sheet on the iPhone, sending one document to the archive.",
		iphone_scan_shortcuts:
			"The iPhone settings listing the ways to start a scan: Home Screen, Control Center, Action button, and Siri.",
		mac_library_reader:
			"The Mac library: a sidebar with people, categories, tags, and folders, a list of documents, an electricity statement in the reader, and its details in the inspector.",
		mac_text_search:
			"A search on the Mac for an insurance word, with the match highlighted in the document's extracted text.",
		web_document_reading:
			"A bank statement in the web app: its title and summary, the original PDF, and the details Schublade read, such as the date, amount, and IBAN.",
		web_archive_filter:
			"The archive in the browser with the Category filter open, listing each category with its number of documents.",
		web_phone_archive:
			"The archive in a phone's browser: documents with their sender, date, and amount, and the Upload button at the bottom.",
	},
	comparisonIndex: {
		title: "Schublade compared with other document archives",
		description:
			"How Schublade differs from other ways to keep household paperwork: where each one runs, how it reads documents, and what it costs to operate.",
		heading: "Schublade compared",
		introduction:
			"Each comparison lists what we checked about the other product, the sources, and the day we checked them.",
		empty: "Comparisons are on their way.",
	},
	comparison: {
		aspectColumn: "Aspect",
		schubladeColumn: "Schublade",
		sourcesHeading: "Sources",
		checkedOn: (date) => `Checked on ${date}.`,
	},
	blogIndex: {
		title: "Schublade blog: paperwork, scanning, and self-hosting",
		description:
			"Articles about keeping household paperwork in order: scanning and text recognition, searching documents, and running your own archive on Cloudflare.",
		heading: "Blog",
		introduction: "Notes on paperwork, scanning, and running your own document archive.",
		empty: "The first posts are on their way.",
		feedLabel: "RSS feed",
	},
	blogPost: {
		readingTime: (minutes) => `${minutes} min read`,
		updatedOn: (date) => `Updated ${date}`,
		tagsLabel: "Tags",
		readInThisLanguage: "Read this article in English",
		morePostsHeading: "More from the blog",
	},
	breadcrumbHome: "Home",
	footer: {
		summary:
			"An open-source document archive that you host on your own Cloudflare account. We never see your documents.",
		productHeading: "Product",
		resourcesHeading: "Resources",
		informationHeading: "Help and legal",
		sourceCode: "Source code",
		feed: "RSS feed",
	},
	notFound: {
		title: "Page not found",
		heading: "This page is not in the drawer.",
		text: "The address may be mistyped, or the page has moved.",
		homeAction: "Go to the home page",
	},
}

const german: InterfaceText = {
	navigation: {
		skipToContent: "Zum Inhalt springen",
		homeLabel: "Schublade Startseite",
		primaryLabel: "Hauptmenü",
		breadcrumbLabel: "Navigationspfad",
		comparisons: "Vergleiche",
		blog: "Blog",
		languageLabel: "Sprache",
	},
	availability: { available: "Jetzt verfügbar", coming_soon: "Bald verfügbar" },
	landing: {
		title: "Schublade: dein selbst gehostetes Archiv für Papierkram",
		description:
			"Schublade liest, benennt und sortiert Briefe, Rechnungen und Belege auf deinem eigenen Cloudflare-Konto. Scannen, hochladen oder mailen, dann alles finden.",
		headline: "Dein Papierkram, gelesen, abgelegt und schnell gefunden.",
		subheadline:
			"Schublade ist Open-Source-Software, die du auf deinem eigenen Cloudflare-Konto betreibst. Schick Schublade einen Brief, eine Rechnung oder ein Foto vom Kassenbon. Schublade benennt und ordnet das Dokument ein, und du findest es mit einer Suche wieder.",
		deployAction: "Selbst einrichten",
		platformsAction: "Web, iPhone und Mac",
		platformsHeading: "Ein Archiv, drei Wege dorthin",
		stepsHeading: "So funktioniert es",
		steps: [
			{
				title: "Schicken",
				text: "Lade Dateien im Browser hoch, leite eine E-Mail weiter, scanne mit dem iPhone oder lass deinen Mac einen Ordner einsammeln.",
			},
			{
				title: "Lesen und ablegen",
				text: "Schublade liest jede Seite und gibt dem Dokument Titel, Datum, Absender, Kategorie und Person. Beträge und IBANs zieht es gleich mit heraus.",
			},
			{
				title: "Finden",
				text: "Such nach Stichwort oder Bedeutung, auch über Sprachen hinweg. Jede Datei liegt nur einmal im Archiv, egal wie oft sie ankommt.",
			},
		],
		principles: [
			"Open Source (AGPL-3.0)",
			"Läuft auf deinem eigenen Cloudflare-Konto",
			"Deine Dokumente erreichen uns nie",
		],
		ownershipHeading: "Open Source. Selbst gehostet. Alles bringst du selbst mit.",
		ownershipLead:
			"Schublade ist Software, kein Dienst. Es gibt kein Schublade-Konto und keinen Schublade-Server. Du richtest das Archiv auf deinem eigenen Cloudflare-Konto ein, und jede App spricht nur mit diesem Archiv. Deine Dokumente erreichen uns nie.",
		ownershipItems: [
			{
				title: "Dein Cloudflare-Konto",
				text: "Worker, Datenbank, Dateispeicher und Suchindex entstehen auf deinem Konto, und Cloudflare rechnet direkt mit dir ab.",
			},
			{
				title: "Deine KI",
				text: "Workers AI auf deinem Konto liest jedes Dokument und ordnet es ein. Du brauchst keinen fremden KI-Anbieter und keinen API-Schlüssel.",
			},
			{
				title: "Deine Adresse und Anmeldung",
				text: "Das Archiv antwortet unter deiner Adresse, hinter Cloudflare Access, für die E-Mail-Adressen, die du erlaubst.",
			},
			{
				title: "Deine Kopie des Codes",
				text: "Der Quellcode liegt unter der AGPL-3.0 auf GitHub. Lies ihn, ändere ihn und richte deine eigene Version ein.",
			},
		],
		ownershipCosts:
			"Du brauchst ein Cloudflare-Konto mit dem Workers-Paid-Tarif. Das Einordnen eines Dokuments kostet etwa 0,0023 USD, das Lesen einer gescannten Seite oder eines Fotos etwa 0,0008 USD. Ein PDF mit lesbarer Textebene braucht keine Texterkennung.",
		sourceAction: "Quellcode auf GitHub",
		licenseAction: "Lizenz AGPL-3.0",
	},
	platformPages: {
		web: {
			title: "Schublade im Browser: dein Dokumentenarchiv im Web",
			description:
				"Richte Schublade auf deinem eigenen Cloudflare-Konto ein. Lade Dateien hoch, leite E-Mails weiter oder schick sie per Skript und finde jedes Dokument wieder.",
			linkLabel: "Schublade im Browser",
			heading: "Dein Archiv im Browser",
			introduction:
				"Die Web-App ist das Archiv selbst. Du richtest sie auf deinem eigenen Cloudflare-Konto ein, und alle in deinem Haushalt melden sich bei denselben Dokumenten an.",
			availabilityNote: "Open Source. Du richtest es selbst ein, mit dem Quellcode von GitHub.",
			landingSummary:
				"Das ganze Archiv im Browser. Lade Dateien hoch, leite E-Mails weiter oder schick sie per Skript.",
			sections: {
				arrival: {
					heading: "Vier Wege ins Archiv",
					paragraphs: [
						"Im Browser hochladen: bis zu 20 Dateien auf einmal, je 25 MB und zusammen 50 MB. Schublade nimmt PDF, JPEG, PNG und WebP. Auf dem Handy legst du Schublade auf den Home-Bildschirm und nutzt die Kamera.",
						"Leite Post von einer erlaubten Adresse an die Adresse weiter, die du eingerichtet hast. Schublade archiviert die Anhänge und druckt eine Nachricht ohne Anhang als PDF.",
						"Erstell in den Einstellungen ein Token und schick Dateien von einem Scanner oder einem Skript. Jede App, die ein Multipart-Formular senden kann, funktioniert, zum Beispiel ein Apple-Kurzbefehl.",
						"Ein Sammler beobachtet deine Ordner, fragt das Archiv, welche Dateien ihm fehlen, und schickt nur diese.",
					],
				},
				reading: {
					heading: "Schublade liest jede Seite",
					paragraphs: [
						"Jedes Dokument bekommt Titel, Datum, Absender, Kategorie und Person, dazu Felder wie Beträge und IBANs.",
						"Ein PDF mit lesbarer Textebene wird aus dieser Ebene gelesen. Scans und Fotos liest ein Bildmodell auf Workers AI. Liegt eine Seite quer, liest Schublade sie in allen vier Drehungen und behält die beste Lesung.",
					],
				},
				search: {
					heading: "Suche über Sprachen hinweg",
					paragraphs: [
						"Die Suche verbindet Stichworte mit Bedeutung. So findest du einen Kontoauszug auch dann, wenn darin andere Worte stehen als in deiner Suche. Filtere nach Absender, Kategorie oder Schlagwort und benenne sie um oder führe sie zusammen, wenn sich deine Ablage ändert.",
					],
				},
				identity: {
					heading: "Jede Datei liegt nur einmal da",
					paragraphs: [
						"Schublade erkennt jede Datei an der SHA-256-Prüfsumme ihrer Bytes. Schickst du dieselbe Datei noch einmal, auf welchem Weg auch immer, bekommst du das Dokument, das sie schon enthält. Eine umbenannte oder verschobene Kopie ist dieselbe Datei. Ein neuer Scan desselben Briefs ist eine neue.",
						"Löschst du ein Dokument, merkt sich Schublade die Datei. Ein Sammler schickt sie dann nie wieder.",
					],
				},
				access: {
					heading: "Anmeldung und KI-Clients",
					paragraphs: [
						"Die Anmeldung übernimmt Cloudflare Access. Eine Installation ist für einen Haushalt, und alle, die sich anmelden dürfen, sehen alle Dokumente.",
						"Verbinde dein Archiv als Connector mit Claude oder einem anderen MCP-Client. Auf einer Zustimmungsseite erlaubst du das ganze Archiv oder nur die Kategorien, Absender und Schlagworte, die du auswählst. Der Client bekommt vier Werkzeuge, die nur lesen.",
					],
				},
				requirements: {
					heading: "Was du brauchst",
					paragraphs: [
						"Ein Cloudflare-Konto mit dem Workers-Paid-Tarif und aktiviertem Cloudflare Zero Trust. Der kostenlose Zero-Trust-Tarif reicht für 50 Personen. Auf deinem Rechner brauchst du Node.js 24.22 oder neuer und pnpm.",
						"Ein Befehl legt alle Ressourcen auf deinem Konto an, stellt den Worker hinter Cloudflare Access bereit und richtet auf Wunsch eine eigene Domain und eine E-Mail-Adresse ein.",
					],
					command:
						"pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json",
				},
			},
		},
		iphone: {
			title: "Schublade fürs iPhone: Papier direkt ins Archiv scannen",
			description:
				"Scanne einen Brief mit dem iPhone, und er landet in deinem Schublade-Archiv. Teile Dateien aus jeder App und lies und durchsuche deine Dokumente offline.",
			linkLabel: "Schublade fürs iPhone",
			heading: "Scanne Papier dort, wo es ankommt",
			introduction:
				"Post landet auf dem Küchentisch, nicht am Schreibtisch. Die iPhone-App macht aus einem Brief in einem Schritt ein archiviertes Dokument und hat dein ganzes Archiv dabei.",
			availabilityNote:
				"Kostenlos im App Store. Die App verbindet sich mit einem Archiv, das du selbst eingerichtet hast, und hat kein eigenes Konto und keinen eigenen Server.",
			landingSummary: "Scanne Papier mit der Kamera, teile Dateien aus jeder App und lies dein Archiv auch offline.",
			sections: {
				scan: {
					heading: "Einen Brief in einem Schritt scannen",
					paragraphs: [
						"Scannen öffnet die Dokumentenkamera des Systems. Sichern schickt alle Seiten als ein PDF. Ein fertiger Scan braucht keinen Namen, keinen Ordner und keine zweite Bestätigung.",
						"Der Scan erscheint unter „Arriving“, während das Archiv ihn liest, und wird kurz darauf zu einem Dokument mit Titel.",
					],
				},
				shortcuts: {
					heading: "Scannen, ohne die App zu öffnen",
					paragraphs: [
						"Starte einen Scan vom Symbol auf dem Home-Bildschirm, mit einem Steuerelement im Kontrollzentrum oder auf dem Sperrbildschirm, mit der Aktionstaste oder mit Siri.",
					],
				},
				share: {
					heading: "Aus jeder App senden",
					paragraphs: [
						"Schublade steht im Teilen-Menü von Mail, Dateien, Safari, Fotos und jeder App, die Dateien teilt. Du kannst auch aus Fotos und Dateien importieren.",
						"Ein Scan ohne Netz erreicht das Archiv später, ohne dass du die App noch einmal öffnen musst.",
					],
				},
				library: {
					heading: "Dein Archiv, auch offline",
					paragraphs: [
						"Die App hält eine Kopie der Einträge deines Archivs auf dem iPhone. Stöbere nach Kategorie, Absender oder Person und durchsuche Titel, Details und Text, auch ohne Netz.",
					],
				},
				details: {
					heading: "Original und Details lesen",
					paragraphs: [
						"Öffne ein Dokument, und du siehst die Originalseite, darunter Datum, Betrag, Fälligkeit und IBAN. Tipp auf eine Angabe, um sie zu kopieren, etwa um eine Rechnung zu bezahlen.",
						"Bearbeiten, Löschen und erneutes Verarbeiten bleiben im Browser.",
					],
				},
			},
		},
		mac: {
			title: "Schublade für den Mac: eine native Bibliothek für dein Archiv",
			description:
				"Eine native Mac-App für dein Schublade-Archiv. Lies und durchsuche jedes Dokument offline und lass sie die Ordner einsammeln, in denen PDFs und Scans landen.",
			linkLabel: "Schublade für den Mac",
			heading: "Dein Archiv als Mac-Bibliothek",
			introduction:
				"Die Mac-App ist ein natives Fenster auf dein Archiv, mit Seitenleiste, Liste, Leseansicht und Informationen. Außerdem sammelt sie die Ordner ein, in denen dein Papierkram landet.",
			availabilityNote: "Die App funktioniert schon mit deinem Archiv. Einen öffentlichen Download gibt es noch nicht.",
			landingSummary:
				"Eine native Bibliothek mit Leseansicht und Informationen. Sie sammelt die Ordner ein, die du auswählst.",
			sections: {
				library: {
					heading: "Ein Dokument finden und lesen",
					paragraphs: [
						"Stöbere nach Person, Kategorie, Schlagwort oder Absender. Geh mit den Pfeiltasten durch die Liste, und die Leseansicht folgt. Die Leertaste öffnet die Übersicht.",
						"Die Informationen zeigen Datum, Betrag, Fälligkeit und IBAN, bereit zum Kopieren. Zieh ein Dokument in Mail oder in den Finder.",
					],
				},
				search: {
					heading: "Suche beim Tippen",
					paragraphs: [
						"Die Suche antwortet bei jedem Tastendruck aus einer Kopie deines Archivs auf dem Mac, auch offline. Treffer im Text zeigen den Satz rund um dein Suchwort.",
					],
				},
				collection: {
					heading: "Schublade sammelt deine Ordner ein",
					paragraphs: [
						"Wähle Ordner wie Downloads oder den, in den dein Scanner schreibt. Schublade beobachtet sie, fragt das Archiv, welche Dateien ihm fehlen, und schickt nur diese.",
						"Liegen in einem Ordner schon Dateien, fragt Schublade, bevor es sie schickt. Danach geht jede neue PDF-, JPEG-, PNG- oder WebP-Datei im Ordner von allein ins Archiv.",
					],
				},
				menuBar: {
					heading: "Leise in der Menüleiste",
					paragraphs: [
						"Eine Schublade in der Menüleiste zeigt laufende Uploads und die fünf neuesten Dokumente. Schublade meldet sich nur, wenn ein Ordner eine Entscheidung braucht oder das Archiv sein Token ablehnt.",
					],
				},
			},
		},
	},
	platformPage: {
		deployAction: "Selbst einrichten",
		appStoreAction: "Laden im App Store",
		deployArchiveAction: "Archiv einrichten",
		relatedPostsHeading: "Aus dem Blog",
		comparisonsHeading: "Schublade im Vergleich",
	},
	screenshotDescriptions: {
		iphone_library_arriving:
			"Die iPhone-Bibliothek: oben ein dreiseitiger Scan, dessen Text gerade erkannt wird, darunter die Dokumente nach Monat.",
		iphone_search_category: "Die iPhone-Bibliothek, eingegrenzt auf die Kategorie Rechnung, mit dem Suchfeld unten.",
		iphone_document_details:
			"Eine Rechnung auf dem iPhone mit ihren Details: Datum, Betrag, Fälligkeit, IBAN und Rechnungsnummer.",
		iphone_share_sheet: "Das Teilen-Fenster von Schublade auf dem iPhone, das ein Dokument ans Archiv schickt.",
		iphone_scan_shortcuts:
			"Die iPhone-Einstellungen mit den Wegen, einen Scan zu starten: Home-Bildschirm, Kontrollzentrum, Aktionstaste und Siri.",
		mac_library_reader:
			"Die Mac-Bibliothek: Seitenleiste mit Personen, Kategorien, Schlagworten und Ordnern, eine Dokumentliste, eine Stromabrechnung in der Leseansicht und ihre Details daneben.",
		mac_text_search:
			"Eine Suche auf dem Mac nach einem Versicherungswort, mit dem Treffer markiert im erkannten Text des Dokuments.",
		web_document_reading:
			"Ein Kontoauszug in der Web-App: Titel und Zusammenfassung, das Original-PDF und die Angaben, die Schublade gelesen hat, etwa Datum, Betrag und IBAN.",
		web_archive_filter:
			"Das Archiv im Browser mit geöffnetem Kategorie-Filter, der jede Kategorie mit der Zahl ihrer Dokumente zeigt.",
		web_phone_archive:
			"Das Archiv im Browser eines Handys: Dokumente mit Absender, Datum und Betrag, unten die Schaltfläche zum Hochladen.",
	},
	comparisonIndex: {
		title: "Schublade im Vergleich mit anderen Dokumentenarchiven",
		description:
			"Worin sich Schublade von anderen Wegen unterscheidet, Papierkram aufzubewahren: wo es läuft, wie es Dokumente liest und was der Betrieb kostet.",
		heading: "Schublade im Vergleich",
		introduction:
			"Jeder Vergleich nennt, was wir über das andere Produkt geprüft haben, die Quellen und den Tag der Prüfung.",
		empty: "Die Vergleiche folgen bald.",
	},
	comparison: {
		aspectColumn: "Punkt",
		schubladeColumn: "Schublade",
		sourcesHeading: "Quellen",
		checkedOn: (date) => `Geprüft am ${date}.`,
	},
	blogIndex: {
		title: "Schublade-Blog: Papierkram, Scannen und eigenes Hosting",
		description:
			"Artikel rund um Ordnung im Papierkram: Scannen und Texterkennung, Dokumente durchsuchen und dein eigenes Archiv auf Cloudflare betreiben.",
		heading: "Blog",
		introduction: "Über Papierkram, Scannen und dein eigenes Dokumentenarchiv.",
		empty: "Die ersten Artikel folgen bald.",
		feedLabel: "RSS-Feed",
	},
	blogPost: {
		readingTime: (minutes) => `${minutes} Min. Lesezeit`,
		updatedOn: (date) => `Aktualisiert am ${date}`,
		tagsLabel: "Schlagworte",
		readInThisLanguage: "Diesen Artikel auf Deutsch lesen",
		morePostsHeading: "Mehr aus dem Blog",
	},
	breadcrumbHome: "Start",
	footer: {
		summary:
			"Ein Open-Source-Dokumentenarchiv, das du auf deinem eigenen Cloudflare-Konto betreibst. Deine Dokumente sehen wir nie.",
		productHeading: "Produkt",
		resourcesHeading: "Mehr",
		informationHeading: "Hilfe und Rechtliches",
		sourceCode: "Quellcode",
		feed: "RSS-Feed",
	},
	notFound: {
		title: "Seite nicht gefunden",
		heading: "Diese Seite liegt nicht in der Schublade.",
		text: "Vielleicht hat sich ein Tippfehler in die Adresse geschlichen, oder die Seite ist umgezogen.",
		homeAction: "Zur Startseite",
	},
}

export const INTERFACE_TEXT: Record<Locale, InterfaceText> = { en: english, de: german }
