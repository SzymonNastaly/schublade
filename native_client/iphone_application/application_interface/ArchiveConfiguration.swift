import ApplicationBindings

/// The fields of a configured connection by name.
struct ArchiveConfiguration {
	let origin: String
	let host: String
	let condition: ConnectionCondition
	let restricted: Bool
}

extension ArchiveConnection {
	/// Nil while no archive is connected.
	var configuration: ArchiveConfiguration? {
		guard case let .configured(origin, host, condition, _, restricted) = self else {
			return nil
		}
		return ArchiveConfiguration(origin: origin, host: host, condition: condition, restricted: restricted)
	}
}
