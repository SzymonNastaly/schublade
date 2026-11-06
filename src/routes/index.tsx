import { Empty, LayerCard, Table, Text } from "@cloudflare/kumo"
import { UsersThreeIcon } from "@phosphor-icons/react"
import { createFileRoute } from "@tanstack/react-router"
import { listHouseholdMembers } from "../utilities/server_functions"

export const Route = createFileRoute("/")({
	loader: () => listHouseholdMembers(),
	component: HouseholdMembersOverview,
})

function HouseholdMembersOverview() {
	const members = Route.useLoaderData()
	return (
		<main className="mx-auto flex max-w-3xl flex-col gap-6 px-6 py-12">
			<Text variant="heading1" as="h1">
				Schublade
			</Text>
			<LayerCard>
				<LayerCard.Secondary>Household members</LayerCard.Secondary>
				<LayerCard.Primary>
					{members.length === 0 ? (
						<Empty
							icon={<UsersThreeIcon size={32} />}
							title="No household members"
							description="Run `pnpm run provision` to record the members of the household."
						/>
					) : (
						<Table>
							<Table.Header>
								<Table.Row>
									<Table.Head>Name</Table.Head>
									<Table.Head>Spellings on letters</Table.Head>
								</Table.Row>
							</Table.Header>
							<Table.Body>
								{members.map((member) => (
									<Table.Row key={member.id}>
										<Table.Cell>{member.displayName}</Table.Cell>
										<Table.Cell>{member.addresseeNames.join(", ")}</Table.Cell>
									</Table.Row>
								))}
							</Table.Body>
						</Table>
					)}
				</LayerCard.Primary>
			</LayerCard>
		</main>
	)
}
