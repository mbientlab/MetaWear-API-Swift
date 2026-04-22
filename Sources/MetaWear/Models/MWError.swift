public enum MWError: Error, Sendable {
    case bluetoothUnsupported
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case operationFailed(String)
    case invalidState(String)
    case timeout
}
