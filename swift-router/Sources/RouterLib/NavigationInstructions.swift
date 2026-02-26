import Foundation

// MARK: - Data Types

public enum TurnDirection: String {
    case start
    case straight
    case slightLeft
    case slightRight
    case left
    case right
    case sharpLeft
    case sharpRight
    case uTurn
    case arrive
}

public struct NavigationStep {
    public let instruction: String
    public let streetName: String?
    public let streetDescription: String
    public let distance: Double
    public let turnDirection: TurnDirection
    public let turnAngle: Double
    public let startLat: Double
    public let startLon: Double
}

// MARK: - Highway Type Fallback Descriptions

private let highwayDescriptions: [String: String] = [
    "footway": "footpath",
    "path": "path",
    "pedestrian": "pedestrian way",
    "steps": "steps",
    "cycleway": "cycleway",
    "residential": "road",
    "living_street": "road",
    "tertiary": "road",
    "tertiary_link": "road",
    "secondary": "road",
    "secondary_link": "road",
    "primary": "road",
    "primary_link": "road",
    "trunk": "road",
    "service": "service road",
    "track": "track",
    "unclassified": "road",
]

// MARK: - Compass Directions

private func compassDirection(_ bearingDeg: Double) -> String {
    let dirs = ["north", "northeast", "east", "southeast",
                "south", "southwest", "west", "northwest"]
    let idx = Int((bearingDeg + 22.5).truncatingRemainder(dividingBy: 360.0) / 45.0) % 8
    return dirs[idx]
}

// MARK: - Turn Classification

/// Classify turn from bearing change.
/// `angle` is the signed turn angle in degrees: negative = left, positive = right.
private func classifyTurn(_ angle: Double) -> TurnDirection {
    let absAngle = abs(angle)
    if absAngle < 15 {
        return .straight
    } else if absAngle < 45 {
        return angle < 0 ? .slightLeft : .slightRight
    } else if absAngle < 120 {
        return angle < 0 ? .left : .right
    } else if absAngle < 160 {
        return angle < 0 ? .sharpLeft : .sharpRight
    } else {
        return .uTurn
    }
}

/// Human-readable turn prefix.
private func turnPrefix(_ direction: TurnDirection) -> String {
    switch direction {
    case .start: return "Head"
    case .straight: return "Continue"
    case .slightLeft: return "Turn slight left"
    case .slightRight: return "Turn slight right"
    case .left: return "Turn left"
    case .right: return "Turn right"
    case .sharpLeft: return "Turn sharp left"
    case .sharpRight: return "Turn sharp right"
    case .uTurn: return "Make a U-turn"
    case .arrive: return "Arrive"
    }
}

// MARK: - Instruction Generation

/// Generate turn-by-turn navigation instructions from a route path.
///
/// - Parameters:
///   - path: Array of OSM node IDs forming the route
///   - graph: CompactGraph with name data (v2)
/// - Returns: Array of NavigationStep, or nil if graph has no name data
public func generateInstructions(path: [Int64], graph: CompactGraph) -> [NavigationStep]? {
    guard graph.hasNameData else { return nil }
    guard path.count >= 2 else { return nil }

    // Convert to indices
    let indices = path.map { graph.idxForOsmId($0) }

    // For each edge: compute bearing, look up name/highway, compute distance
    struct EdgeInfo {
        let bearing: Double
        let distance: Double
        let name: String?
        let highway: String?
        let effectiveName: String
        let startIdx: Int  // index into `indices`
    }

    var edges = [EdgeInfo]()
    for i in 0..<(indices.count - 1) {
        let fromIdx = indices[i]
        let toIdx = indices[i + 1]

        let lat1 = Double(graph.nodeLats[Int(fromIdx)])
        let lon1 = Double(graph.nodeLons[Int(fromIdx)])
        let lat2 = Double(graph.nodeLats[Int(toIdx)])
        let lon2 = Double(graph.nodeLons[Int(toIdx)])

        let b = bearing(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        let d = haversine(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)

        let name = graph.edgeName(from: fromIdx, to: toIdx)
        let highway = graph.edgeHighway(from: fromIdx, to: toIdx)

        // Effective name: street name if present, else fallback from highway type
        let effectiveName: String
        if let n = name, !n.isEmpty {
            effectiveName = n
        } else if let hw = highway {
            effectiveName = highwayDescriptions[hw] ?? "road"
        } else {
            effectiveName = "road"
        }

        edges.append(EdgeInfo(bearing: b, distance: d, name: name, highway: highway,
                              effectiveName: effectiveName, startIdx: i))
    }

    guard !edges.isEmpty else { return nil }

    // Group consecutive edges with the same effective name
    struct StepGroup {
        let effectiveName: String
        let streetName: String?
        let totalDistance: Double
        let entryBearing: Double
        let exitBearing: Double
        let startIdx: Int  // index into `indices`
    }

    var groups = [StepGroup]()
    var groupStart = 0
    while groupStart < edges.count {
        var groupEnd = groupStart + 1
        while groupEnd < edges.count && edges[groupEnd].effectiveName == edges[groupStart].effectiveName {
            groupEnd += 1
        }

        // Sum distances
        var totalDist = 0.0
        for j in groupStart..<groupEnd {
            totalDist += edges[j].distance
        }

        groups.append(StepGroup(
            effectiveName: edges[groupStart].effectiveName,
            streetName: edges[groupStart].name,
            totalDistance: totalDist,
            entryBearing: edges[groupStart].bearing,
            exitBearing: edges[groupEnd - 1].bearing,
            startIdx: edges[groupStart].startIdx
        ))

        groupStart = groupEnd
    }

    // Generate instructions
    var steps = [NavigationStep]()

    for (i, group) in groups.enumerated() {
        let nodeArrayIdx = group.startIdx
        let lat = Double(graph.nodeLats[Int(indices[nodeArrayIdx])])
        let lon = Double(graph.nodeLons[Int(indices[nodeArrayIdx])])

        let turnDirection: TurnDirection
        let turnAngle: Double

        if i == 0 {
            // First step: "Head <compass> on <street>"
            turnDirection = .start
            turnAngle = 0.0
            let compass = compassDirection(group.entryBearing)
            let instruction = "Head \(compass) on \(group.effectiveName)"
            steps.append(NavigationStep(
                instruction: instruction,
                streetName: group.streetName,
                streetDescription: group.effectiveName,
                distance: group.totalDistance,
                turnDirection: turnDirection,
                turnAngle: turnAngle,
                startLat: lat,
                startLon: lon
            ))
        } else {
            // Compute turn angle from previous group's exit bearing to this group's entry bearing
            let prevExit = groups[i - 1].exitBearing
            let thisEntry = group.entryBearing
            var angle = thisEntry - prevExit
            // Normalize to [-180, 180]
            while angle > 180 { angle -= 360 }
            while angle < -180 { angle += 360 }

            turnAngle = angle
            turnDirection = classifyTurn(angle)

            let prefix = turnPrefix(turnDirection)
            let instruction: String
            if turnDirection == .straight {
                instruction = "\(prefix) on \(group.effectiveName)"
            } else {
                instruction = "\(prefix) onto \(group.effectiveName)"
            }

            steps.append(NavigationStep(
                instruction: instruction,
                streetName: group.streetName,
                streetDescription: group.effectiveName,
                distance: group.totalDistance,
                turnDirection: turnDirection,
                turnAngle: turnAngle,
                startLat: lat,
                startLon: lon
            ))
        }
    }

    // Final "Arrive at destination" step
    let lastIdx = indices[indices.count - 1]
    let endLat = Double(graph.nodeLats[Int(lastIdx)])
    let endLon = Double(graph.nodeLons[Int(lastIdx)])
    steps.append(NavigationStep(
        instruction: "Arrive at destination",
        streetName: nil,
        streetDescription: "",
        distance: 0,
        turnDirection: .arrive,
        turnAngle: 0,
        startLat: endLat,
        startLon: endLon
    ))

    return steps
}
