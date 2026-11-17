import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { collectorBridge } from "#collector_bridge"
import { collectorStatusKey, createStatusFollowing } from "./status_following"
import type { ApplicationPreferences } from "./collector_bridge"

const applicationPreferencesKey = ["application_preferences"] as const

export { collectorBridge }

const statusFollowing = createStatusFollowing(collectorBridge)

/** Follows the collector's announcements for the window's lifetime; `main.tsx` starts it once. */
export const followCollectorStatus = statusFollowing.follow

/** The collector's status, read again only when the collector announces a newer one. */
export function useCollectorStatus() {
	return useQuery(statusFollowing.statusQuery)
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
