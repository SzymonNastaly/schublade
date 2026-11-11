import { ProgressSpinner } from "./progress_spinner"
import type { Icon } from "@phosphor-icons/react"
import type { ButtonHTMLAttributes } from "react"

type ActionVariant = "primary" | "secondary" | "destructive" | "secondaryDestructive" | "plain"

interface ActionAppearance {
	variant: ActionVariant
	size?: "regular" | "compact"
	/** Fills the width below the md breakpoint, where a finger operates it. */
	stretchOnPhone?: boolean
}

const variantClasses: Record<ActionVariant, string> = {
	primary: "border border-transparent bg-primary text-on-primary hover:bg-primary-hover",
	secondary: "border border-control-border bg-control text-control-foreground hover:border-control-foreground",
	destructive: "border border-transparent bg-destructive text-on-primary hover:bg-destructive-hover",
	secondaryDestructive:
		"border border-destructive-border bg-control text-destructive-text hover:border-destructive-text",
	plain: "border border-transparent text-link hover:text-link-hover",
}

const sizeClasses = {
	regular: "h-11 px-4 text-body md:h-10",
	compact: "h-11 px-3 text-fine md:h-8.5",
}

function actionClasses({ variant, size = "regular", stretchOnPhone = false }: ActionAppearance): string {
	return `inline-flex cursor-pointer items-center justify-center gap-2 rounded-control font-bold whitespace-nowrap disabled:cursor-not-allowed disabled:opacity-55 ${variantClasses[variant]} ${sizeClasses[size]} ${stretchOnPhone ? "max-md:w-full" : ""}`
}

interface ActionButtonProperties
	extends ActionAppearance, Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className" | "style"> {
	icon?: Icon
	/** Shows a spinner and refuses further presses while the action runs. */
	pending?: boolean
}

export function ActionButton({
	variant,
	size,
	stretchOnPhone,
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
			className={actionClasses({ variant, size, stretchOnPhone })}
			{...button}
		>
			{pending ? <ProgressSpinner /> : ActionIcon && <ActionIcon size={16} />}
			{children}
		</button>
	)
}
