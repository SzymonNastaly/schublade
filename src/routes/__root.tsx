import { HeadContent, Scripts, createRootRoute } from "@tanstack/react-router"
import applicationStylesheet from "../styles.css?url"
import { countPendingVerificationItems } from "../utilities/server_functions"
import type { ReactNode } from "react"

export const Route = createRootRoute({
	head: () => ({
		meta: [
			{ charSet: "utf-8" },
			{ name: "viewport", content: "width=device-width, initial-scale=1" },
			{ title: "Schublade" },
		],
		links: [{ rel: "stylesheet", href: applicationStylesheet }],
	}),
	// Every page shows the number of entries in Pending verification, and invalidating the router
	// after an action counts them again.
	loader: () => countPendingVerificationItems(),
	shellComponent: RootDocument,
})

function RootDocument({ children }: { children: ReactNode }) {
	return (
		<html lang="en">
			<head>
				<HeadContent />
			</head>
			<body className="bg-kumo-base text-kumo-default antialiased">
				{children}
				<Scripts />
			</body>
		</html>
	)
}
