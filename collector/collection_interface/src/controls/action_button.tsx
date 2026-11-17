import { ProgressSpinner } from "./progress_spinner"
import type { Icon } from "@phosphor-icons/react"
import type { ButtonHTMLAttributes } from "react"

type ActionVariant = "primary" | "secondary" | "secondaryDestructive" | "plain"

const variantClasses: Record<ActionVariant, string> = {
	primary: "border border-transparent bg-primary text-on-primary hover:bg-primary-hover",
	secondary: "border border-control-border bg-control text-control-foreground hover:border-control-foreground",
	secondaryDestructive:
		"border border-destructive-border bg-control text-destructive-text hover:border-destructive-text",
	plain: "border border-transparent text-link hover:text-link-hover",
}

const sizeClasses = {
	regular: "h-9 px-4 text-body",
	compact: "h-7.5 px-3 text-fine",
}

interface ActionButtonProperties extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className" | "style"> {
	variant: ActionVariant
	size?: keyof typeof sizeClasses
	icon?: Icon
	/** Shows a spinner and refuses further presses while the action runs. */
	pending?: boolean
}

export function ActionButton({
	variant,
	size = "regular",
	icon: ActionIcon,
	pending = false,
	disabled,
	type = "button",
	children,
	...button
}: ActionButtonProperties) {
	return (
		<button
			type={type}
			disabled={disabled === true || pending}
			className={`inline-flex cursor-pointer items-center justify-center gap-2 rounded-control font-bold whitespace-nowrap disabled:cursor-not-allowed disabled:opacity-55 ${variantClasses[variant]} ${sizeClasses[size]}`}
			{...button}
		>
			{pending ? <ProgressSpinner /> : ActionIcon && <ActionIcon size={16} />}
			{children}
		</button>
	)
}
