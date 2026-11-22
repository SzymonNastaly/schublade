/// The running count of one skip reason's words while the confirmation merges reasons that read
/// alike, with the noun it counts in.
struct SkippedTotal {
	let noun: String
	var count: UInt64
}
