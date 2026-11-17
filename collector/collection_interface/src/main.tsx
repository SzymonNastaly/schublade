import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { Application } from "./application"
import "./styles.css"

const queryClient = new QueryClient({
	defaultOptions: { queries: { refetchOnWindowFocus: false, retry: false } },
})

const container = document.getElementById("application")
if (container === null) throw new Error("index.html lacks the #application element")

createRoot(container).render(
	<StrictMode>
		<QueryClientProvider client={queryClient}>
			<Application />
		</QueryClientProvider>
	</StrictMode>,
)
