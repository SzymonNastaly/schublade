import { renderToStaticMarkup } from "react-dom/server"
import type { ConsentDescription } from "@cloudflare/workers-oauth-provider"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { SelectionList } from "./grant_selection"

const consentStyles = `
:root { color-scheme: light dark; font-family: system-ui, sans-serif; line-height: 1.5; }
body { margin: 0 auto; max-width: 36rem; padding: 2rem 1rem; }
h1 { font-size: 1.5rem; line-height: 1.25; margin: 0 0 1rem; }
fieldset { border: 0; margin: 1.25rem 0; padding: 0; }
legend { font-weight: 600; padding: 0; }
label { display: flex; gap: 0.5rem; min-height: 2.75rem; align-items: center; overflow-wrap: anywhere; }
input { flex: none; width: 1.25rem; height: 1.25rem; }
.warning { border-left: 3px solid #d97706; padding-left: 0.75rem; }
.actions { display: flex; gap: 0.75rem; margin-top: 1.5rem; }
button { font: inherit; font-weight: 600; min-height: 2.75rem; padding: 0 1.25rem; border-radius: 0.5rem; border: 1px solid currentColor; background: transparent; color: inherit; }
button[value="approve"] { background: #2563eb; border-color: #2563eb; color: #fff; }
form:has(input[value="everything"]:checked) .restrictions { display: none; }
`

const selectionGroups: Array<{
	list: SelectionList
	title: string
	options: (facets: ArchiveFacets) => Array<FacetOption>
}> = [
	{ list: "allowedCategories", title: "Only these categories", options: (facets) => facets.categories },
	{ list: "allowedSenders", title: "Only these senders", options: (facets) => facets.senders },
	{ list: "allowedTags", title: "Only documents with one of these tags", options: (facets) => facets.tags },
	{ list: "deniedTags", title: "Never documents with one of these tags", options: (facets) => facets.tags },
]

function SelectionGroup({ list, title, options }: { list: SelectionList; title: string; options: Array<FacetOption> }) {
	if (options.length === 0) return null
	return (
		<fieldset>
			<legend>{title}</legend>
			{options.map((option) => (
				<label key={option.id}>
					<input type="checkbox" name={list} value={option.id} />
					{option.name} ({option.documentCount})
				</label>
			))}
		</fieldset>
	)
}

interface ConsentPageProperties {
	consent: ConsentDescription
	handle: string
	facets: ArchiveFacets
}

function ConsentPage({ consent, handle, facets }: ConsentPageProperties) {
	const title = `Allow ${consent.clientName} to read your archive?`
	return (
		<html lang="en">
			<head>
				<meta charSet="utf-8" />
				<meta name="viewport" content="width=device-width, initial-scale=1" />
				<title>{title}</title>
				<style dangerouslySetInnerHTML={{ __html: consentStyles }} />
			</head>
			<body>
				<h1>{title}</h1>
				<p>
					{consent.clientDomain === undefined ? (
						"This client registered itself, so Schublade cannot verify its name."
					) : (
						<>
							Published by <strong>{consent.clientDomain}</strong>.
						</>
					)}{" "}
					Access goes to <strong>{consent.redirectHost}</strong>.
				</p>
				{consent.redirectIsLoopback && (
					<p className="warning">
						Access goes to a program on this computer. Continue only if you just started connecting from it.
					</p>
				)}
				<form method="post">
					<input type="hidden" name="handle" value={handle} />
					<fieldset>
						<legend>What may it read?</legend>
						<label>
							<input type="radio" name="access" value="everything" required />
							Every archived document
						</label>
						<label>
							<input type="radio" name="access" value="selected" required />
							Only the documents I select
						</label>
					</fieldset>
					<div className="restrictions">
						<p>A document must match every list you use.</p>
						{selectionGroups.map(({ list, title: groupTitle, options }) => (
							<SelectionGroup key={list} list={list} title={groupTitle} options={options(facets)} />
						))}
					</div>
					<div className="actions">
						<button type="submit" name="decision" value="approve">
							Allow
						</button>
						<button type="submit" name="decision" value="deny" formNoValidate>
							Deny
						</button>
					</div>
				</form>
			</body>
		</html>
	)
}

/** The page is static HTML with no script. React escapes the client's self-chosen name and every record name. */
export function renderConsentPage(properties: ConsentPageProperties): string {
	return `<!doctype html>${renderToStaticMarkup(<ConsentPage {...properties} />)}`
}
