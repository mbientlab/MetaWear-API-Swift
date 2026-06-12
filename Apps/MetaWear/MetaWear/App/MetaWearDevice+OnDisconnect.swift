import MetaWear

extension MetaWearDevice {
    /// Actor-isolated setter for the SDK's `onUnexpectedDisconnect` property.
    /// The property itself can't be assigned from outside the actor, but an
    /// extension method runs on the actor and can mutate it freely.
    func setOnUnexpectedDisconnect(_ handler: (@Sendable (Error) -> Void)?) {
        onUnexpectedDisconnect = handler
    }
}
