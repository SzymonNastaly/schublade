import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect } from "react"
import { collectorBridge } from "#collector_bridge"
import type { ApplicationPreferences } from "./collector_bridge"

const collectorStatusKey = ["collector_status"] as const
const applicationPreferencesKey = ["application_preferences"] as const

export { collectorBridge }

/** The collector's status, read again only when the collector announces a change. */
export function useCollectorStatus() {
	return useQuery({ queryKey: collectorStatusKey, queryFn: () => collectorBridge.readStatus(), staleTime: Infinity })
}

/**
 * Listens for the collector's events for the window's lifetime. Every event, a status change or a
 * received document, reads the status again; the window never polls. Once the listener stands, the
 * status is read once more, so a change announced before it stood is not missed.
 */
export function useCollectorEvents() {
	const queryClient = useQueryClient()
	useEffect(() => {
		const refresh = () => void queryClient.invalidateQueries({ queryKey: collectorStatusKey })
		let removeListener: (() => void) | undefined
		let unmounted = false
		void collectorBridge.subscribe(refresh).then((remove) => {
			if (unmounted) {
				remove()
				return
			}
			removeListener = remove
			refresh()
		})
		return () => {
			unmounted = true
			removeListener?.()
		}
	}, [queryClient])
}

/** A command to the collector; its success reads the status again at once. */
export function useCollectorCommand<TVariables>(perform: (variables: TVariables) => Promise<void>) {
	const queryClient = useQueryClient()
	return useMutation({
		mutationFn: perform,
		onSuccess: () => queryClient.invalidateQueries({ queryKey: collectorStatusKey }),
	})
}

export function useApplicationPreferences() {
	return useQuery({
		queryKey: applicationPreferencesKey,
		queryFn: () => collectorBridge.readPreferences(),
		staleTime: Infinity,
	})
}

export function useChangePreferences() {
	const queryClient = useQueryClient()
	return useMutation({
		mutationFn: (preferences: ApplicationPreferences) => collectorBridge.changePreferences(preferences),
		onSuccess: (preferences) => queryClient.setQueryData(applicationPreferencesKey, preferences),
	})
}
