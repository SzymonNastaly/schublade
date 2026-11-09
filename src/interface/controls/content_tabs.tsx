import { Tabs } from "@base-ui/react/tabs"
import { frameTabClasses, frameTabRowClasses } from "./filter_tabs"
import { ListFrame } from "./page_layout"
import type { ReactNode } from "react"

interface ContentTab {
	value: string
	label: string
	content: ReactNode
	/** Keeps expensive content, such as a drawn PDF, alive while another tab is open. */
	stayMounted?: boolean
}

/** Tabs that rest on a frame and show one panel of content at a time. */
export function ContentTabs({ tabs }: { tabs: Array<ContentTab> }) {
	return (
		<Tabs.Root defaultValue={tabs[0]?.value}>
			<Tabs.List className={frameTabRowClasses}>
				{tabs.map((tab) => (
					<Tabs.Tab key={tab.value} value={tab.value} className={frameTabClasses}>
						{tab.label}
					</Tabs.Tab>
				))}
			</Tabs.List>
			<ListFrame>
				{tabs.map((tab) => (
					<Tabs.Panel key={tab.value} value={tab.value} keepMounted={tab.stayMounted} className="data-[hidden]:hidden">
						{tab.content}
					</Tabs.Panel>
				))}
			</ListFrame>
		</Tabs.Root>
	)
}
