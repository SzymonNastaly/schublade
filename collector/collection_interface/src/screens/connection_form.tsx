import { PlugsConnectedIcon } from "@phosphor-icons/react"
import { useState } from "react"
import { collectorBridge, useCollectorCommand } from "../collector_queries"
import { ActionButton } from "../controls/action_button"
import { FailureMessage, TextField } from "../controls/form_fields"
import { failureSentence } from "../failure_sentence"

interface ConnectionFormProperties {
	initialAddress: string
	submitLabel: string
}

/** The archive address and the API token, tried against the archive before either is stored. */
export function ConnectionForm({ initialAddress, submitLabel }: ConnectionFormProperties) {
	const [address, setAddress] = useState(initialAddress)
	const [token, setToken] = useState("")
	// The token stays out of the mutation's variables, which the mutation cache keeps after it ends.
	const connection = useCollectorCommand(() => collectorBridge.connectArchive(address.trim(), token.trim()))
	return (
		<form
			className="flex flex-col gap-3"
			onSubmit={(event) => {
				event.preventDefault()
				connection.mutate(undefined, { onSuccess: () => setToken("") })
			}}
		>
			<TextField
				label="Archive address"
				placeholder="https://archive.example.org"
				autoComplete="url"
				spellCheck={false}
				value={address}
				onChange={(event) => setAddress(event.target.value)}
				required
			/>
			<TextField
				label="API token"
				hint="In Schublade, open Settings and issue a token with the permission Ingest documents."
				type="password"
				autoComplete="off"
				spellCheck={false}
				value={token}
				onChange={(event) => setToken(event.target.value)}
				required
			/>
			{connection.isError && <FailureMessage>{failureSentence(connection.error, undefined)}</FailureMessage>}
			<div>
				<ActionButton
					type="submit"
					variant="primary"
					icon={PlugsConnectedIcon}
					pending={connection.isPending}
					disabled={address.trim() === "" || token.trim() === ""}
				>
					{connection.isPending ? "Checking the token" : submitLabel}
				</ActionButton>
			</div>
		</form>
	)
}
