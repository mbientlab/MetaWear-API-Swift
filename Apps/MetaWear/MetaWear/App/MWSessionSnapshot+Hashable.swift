import MetaWearPersistence

extension MWSessionSnapshot: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: MWSessionSnapshot, rhs: MWSessionSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}
