import Foundation

enum OPNCouchCoopPadTarget: Equatable, Hashable, Sendable {
    case instance(Int)
    case off

    static let offCode = 0

    var code: Int {
        switch self {
        case .instance(let number): number
        case .off: Self.offCode
        }
    }

    init?(code: Int) {
        if code == Self.offCode {
            self = .off
        } else if code >= OPNAppInstance.primaryNumber {
            self = .instance(code)
        } else {
            return nil
        }
    }
}

struct OPNCouchCoopControllerAssignment: Equatable, Sendable {
    static let steamDescriptorPrefix = "steam-controller-"

    let overrides: [String: OPNCouchCoopPadTarget]
    let instances: [Int]

    init(overrides: [String: OPNCouchCoopPadTarget], instances: [Int]) {
        self.overrides = overrides
        self.instances = Array(Set(instances)).sorted()
    }

    static func nativeDescriptors(vendorNames: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return vendorNames.map { name in
            let ordinal = counts[name, default: 0]
            counts[name] = ordinal + 1
            return "\(name)#\(ordinal)"
        }
    }

    static func orderedDescriptors(native: [String], steam: [String]) -> [String] {
        native + steam
    }

    static func owned(descriptors: [String],
                      overrides: [String: OPNCouchCoopPadTarget],
                      instances: [Int],
                      isActive: Bool,
                      instance: Int) -> [String] {
        guard isActive else { return descriptors }
        let resolved = OPNCouchCoopControllerAssignment(overrides: overrides, instances: instances).resolve(descriptors: descriptors)
        return descriptors.filter { resolved[$0] == .instance(instance) }
    }

    func resolve(descriptors: [String]) -> [String: OPNCouchCoopPadTarget] {
        var resolved: [String: OPNCouchCoopPadTarget] = [:]
        var held: [Int: Int] = Dictionary(uniqueKeysWithValues: instances.map { ($0, 0) })
        for descriptor in descriptors {
            switch overrides[descriptor] {
            case .off:
                resolved[descriptor] = .off
            case .instance(let number) where held[number] != nil:
                resolved[descriptor] = .instance(number)
                held[number, default: 0] += 1
            default:
                break
            }
        }
        for descriptor in descriptors where resolved[descriptor] == nil {
            if let free = instances.first(where: { held[$0] == 0 }) {
                resolved[descriptor] = .instance(free)
                held[free] = 1
            } else {
                resolved[descriptor] = .off
            }
        }
        return resolved
    }

    func target(for descriptor: String, descriptors: [String]) -> OPNCouchCoopPadTarget {
        resolve(descriptors: descriptors)[descriptor] ?? .off
    }

    func pinned(descriptors: [String]) -> [String: OPNCouchCoopPadTarget] {
        normalized(resolve(descriptors: descriptors), descriptors: descriptors)
    }

    func cycled(_ descriptor: String, descriptors: [String]) -> [String: OPNCouchCoopPadTarget] {
        guard descriptors.contains(descriptor) else { return pinned(descriptors: descriptors) }
        var resolved = resolve(descriptors: descriptors)
        let sequence = instances.map(OPNCouchCoopPadTarget.instance) + [.off]
        let current = resolved[descriptor] ?? .off
        let index = sequence.firstIndex(of: current) ?? sequence.count - 1
        let next = sequence[(index + 1) % sequence.count]
        resolved[descriptor] = next
        var explicitOff = explicitOffDescriptors
        if next == .off {
            explicitOff.insert(descriptor)
        } else {
            explicitOff.remove(descriptor)
        }
        return normalized(resolved, descriptors: descriptors, explicitOff: explicitOff)
    }

    func swapped(descriptors: [String]) -> [String: OPNCouchCoopPadTarget] {
        var resolved = resolve(descriptors: descriptors)
        guard instances.count >= 2 else { return normalized(resolved, descriptors: descriptors) }
        let first = OPNCouchCoopPadTarget.instance(instances[0])
        let second = OPNCouchCoopPadTarget.instance(instances[1])
        for (descriptor, target) in resolved {
            if target == first {
                resolved[descriptor] = second
            } else if target == second {
                resolved[descriptor] = first
            }
        }
        return normalized(resolved, descriptors: descriptors)
    }

    private var explicitOffDescriptors: Set<String> {
        Set(overrides.filter { $0.value == .off }.keys)
    }

    private func normalized(_ resolved: [String: OPNCouchCoopPadTarget],
                            descriptors: [String],
                            explicitOff: Set<String>? = nil) -> [String: OPNCouchCoopPadTarget] {
        let keptOff = explicitOff ?? explicitOffDescriptors
        var result: [String: OPNCouchCoopPadTarget] = [:]
        for descriptor in descriptors {
            switch resolved[descriptor] {
            case .instance(let number):
                result[descriptor] = .instance(number)
            case .off where keptOff.contains(descriptor):
                result[descriptor] = .off
            default:
                break
            }
        }
        return result
    }

    static func payload(from overrides: [String: OPNCouchCoopPadTarget]) -> String {
        let codes = overrides.mapValues(\.code)
        guard let data = try? JSONSerialization.data(withJSONObject: codes, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func overrides(fromPayload payload: String?) -> [String: OPNCouchCoopPadTarget] {
        guard let payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return [:] }
        return object.compactMapValues(OPNCouchCoopPadTarget.init(code:))
    }
}
