import { HeadContent, Scripts, createRootRoute } from "@tanstack/react-router"
import applicationStylesheet from "../styles.css?url"
import { ApplicationShell } from "../interface/application_shell"
import { PhoneNavigationBar } from "../interface/phone_navigation_bar"
import { DocumentUploadsProvider, UploadTray } from "../interface/upload_tray"
import { retrieveFailedDocumentCount } from "../utilities/server_functions"
import type { ReactNode } from "react"

export const Route = createRootRoute({
	head: () => ({
		meta: [
			{ charSet: "utf-8" },
			// viewport-fit=cover makes env(safe-area-inset-bottom) report the home indicator.
			{ name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover" },
			{ name: "theme-color", content: "#2c68c4" },
			{ name: "apple-mobile-web-app-capable", content: "yes" },
			{ name: "apple-mobile-web-app-title", content: "Schublade" },
			{ title: "Schublade" },
		],
		links: [
			{ rel: "stylesheet", href: applicationStylesheet },
			// Access protects the manifest, and a browser sends no cookie for it without this attribute.
			{ rel: "manifest", href: "/manifest.webmanifest", crossOrigin: "use-credentials" },
			{ rel: "icon", href: "/application_icon.svg", type: "image/svg+xml" },
			{ rel: "apple-touch-icon", href: "/apple_touch_icon.png" },
		],
	}),
	// Every page shows the number of failed documents, and invalidating the router after an action
	// counts them again.
	loader: () => retrieveFailedDocumentCount(),
	shellComponent: RootDocument,
})

function RootDocument({ children }: { children: ReactNode }) {
	return (
		<html lang="en">
			<head>
				<HeadContent />
			</head>
			{/* The padding keeps a page clear of the navigation bar and, in landscape, of the sensor housing. */}
			<body className="bg-page-background pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)] font-body text-body leading-normal text-foreground antialiased max-md:pb-[calc(3.875rem+env(safe-area-inset-bottom))]">
				<DocumentUploadsProvider>
					<ApplicationShell>{children}</ApplicationShell>
					<UploadTray />
					<PhoneNavigationBar />
				</DocumentUploadsProvider>
				<Scripts />
			</body>
		</html>
	)
}
