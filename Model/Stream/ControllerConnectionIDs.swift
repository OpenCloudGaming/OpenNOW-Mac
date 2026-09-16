import Foundation

/// IDs survive reordering, never a disconnect; vendor/product labels are deliberately not keys.
struct ControllerConnectionIDs {
    private var connections: [ObjectIdentifier: InputDeviceID] = [:]

    mutating func update(_ identifiers: [ObjectIdentifier]) -> [ObjectIdentifier: InputDeviceID] {
        let current = Set(identifiers)
        connections = connections.filter { current.contains($0.key) }
        for identifier in identifiers where connections[identifier] == nil {
            connections[identifier] = InputDeviceID("native-\(UUID().uuidString)")
        }
        return connections
    }
}
