/** The archive's drawer, as its header draws it. */
export function DrawerEmblem({ className }: { className: string }) {
	return (
		<svg aria-hidden viewBox="0 0 72 64" fill="none" className={className}>
			<g stroke="#0b2447" strokeLinejoin="round">
				<path d="M6 34 L14 24 H52 L60 34 Z" fill="#c46f10" strokeWidth="2.4" />
				<path d="M21 36 L24 8 L50 11 L47 36 Z" fill="#ffffff" strokeWidth="2.2" />
				<path d="M13 36 L12 16 L34 13.5 L38 36 Z" fill="#fff3cf" strokeWidth="2.2" />
				<rect x="6" y="34" width="54" height="24" rx="3" fill="#ffb53d" strokeWidth="2.4" />
				<rect x="23" y="43" width="20" height="7" rx="3.5" fill="#fff3cf" strokeWidth="2" />
			</g>
		</svg>
	)
}
