import { WarningCircleIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { collectorBridge } from "../collector_queries"
import { ActionButton } from "../controls/action_button"
import { startFailureWording } from "../status_sentences"
import type { CollectorStartFailure } from "../collector_status"

/** Shown instead of every other screen when the collector could not start; the app stays open to say so. */
export function StartFailureScreen({ failure }: { failure: CollectorStartFailure }) {
	const wording = startFailureWording(failure)
	const quit = useMutation({ mutationFn: () => collectorBridge.quitApplication() })
	return (
		<main className="mx-auto flex w-full max-w-[560px] flex-col gap-4 p-6">
			<h1 className="flex items-center gap-2 font-heading text-section-title font-bold text-heading">
				<WarningCircleIcon size={24} className="shrink-0 text-failure-text" />
				Schublade Collector could not start
			</h1>
			<p>{wording.explanation}</p>
			<p>{wording.remedy}</p>
			{wording.detail !== null && <p className="text-fine text-caption select-text">{wording.detail}</p>}
			<div>
				<ActionButton variant="primary" pending={quit.isPending} onClick={() => quit.mutate()}>
					Quit Schublade Collector
				</ActionButton>
			</div>
		</main>
	)
}
