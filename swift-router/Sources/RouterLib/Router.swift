import Foundation

// MARK: - Edge Key

/// Canonical undirected edge key (smaller ID first).
public struct EdgeKey: Hashable {
    public let a: Int64
    public let b: Int64

    public init(_ n1: Int64, _ n2: Int64) {
        if n1 <= n2 {
            a = n1; b = n2
        } else {
            a = n2; b = n1
        }
    }
}

// MARK: - Route Result

public struct RouteResult {
    public let path: [Int64]
    public let edges: [EdgeKey]
    public let distance: Double
    public let shortestDistance: Double
    public let novelty: Double
    public let overhead: Double
    public let instructions: [NavigationStep]?
}

// MARK: - Min-Heap

private struct HeapEntry: Comparable {
    var fScore: Float
    var gScore: Float
    var counter: Int
    var nodeIdx: Int32

    static func < (lhs: HeapEntry, rhs: HeapEntry) -> Bool {
        if lhs.fScore != rhs.fScore { return lhs.fScore < rhs.fScore }
        if lhs.gScore != rhs.gScore { return lhs.gScore < rhs.gScore }
        return lhs.counter < rhs.counter
    }
}

private struct MinHeap {
    private var storage: [HeapEntry] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ entry: HeapEntry) {
        storage.append(entry)
        siftUp(storage.count - 1)
    }

    mutating func pop() -> HeapEntry {
        let top = storage[0]
        let last = storage.count - 1
        if last > 0 {
            storage[0] = storage[last]
            storage.removeLast()
            siftDown(0)
        } else {
            storage.removeLast()
        }
        return top
    }

    private mutating func siftUp(_ i: Int) {
        var pos = i
        while pos > 0 {
            let parent = (pos - 1) / 2
            if storage[pos] < storage[parent] {
                storage.swapAt(pos, parent)
                pos = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ i: Int) {
        var pos = i
        let n = storage.count
        while true {
            var smallest = pos
            let left = 2 * pos + 1
            let right = 2 * pos + 2
            if left < n && storage[left] < storage[smallest] { smallest = left }
            if right < n && storage[right] < storage[smallest] { smallest = right }
            if smallest == pos { break }
            storage.swapAt(pos, smallest)
            pos = smallest
        }
    }
}

// MARK: - A* Heuristic

@inline(__always)
private func heuristicIdx(_ graph: CompactGraph, _ idx: Int32, _ targetLat: Double, _ targetLon: Double) -> Float {
    Float(haversine(lat1: Double(graph.nodeLats[Int(idx)]),
                    lon1: Double(graph.nodeLons[Int(idx)]),
                    lat2: targetLat, lon2: targetLon))
}

// MARK: - Path Reconstruction

private func reconstructPath(_ cameFrom: UnsafeMutablePointer<Int32>,
                              srcIdx: Int32, tgtIdx: Int32) -> [Int32] {
    var path = [Int32]()
    var cur = tgtIdx
    while cur != -1 {
        path.append(cur)
        if cur == srcIdx { break }
        cur = cameFrom[Int(cur)]
    }
    path.reverse()
    return path
}

private func pathDistance(_ graph: CompactGraph, _ pathIndices: [Int32]) -> Double {
    var total = 0.0
    for i in 0..<(pathIndices.count - 1) {
        let u = pathIndices[i]
        let v = pathIndices[i + 1]
        let (targets, weights) = graph.neighbors(u)
        for j in targets.startIndex..<targets.endIndex {
            if targets[j] == v {
                total += Double(weights[j])
                break
            }
        }
    }
    return total
}

private func pathToEdges(_ path: [Int64]) -> [EdgeKey] {
    var edges = [EdgeKey]()
    edges.reserveCapacity(path.count - 1)
    for i in 0..<(path.count - 1) {
        edges.append(EdgeKey(path[i], path[i + 1]))
    }
    return edges
}

private func computeNovelty(_ edges: [EdgeKey], _ walkedEdges: Set<EdgeKey>) -> Double {
    if edges.isEmpty { return 1.0 }
    var novel = 0
    for e in edges {
        if !walkedEdges.contains(e) { novel += 1 }
    }
    return Double(novel) / Double(edges.count)
}

// MARK: - Shortest Path

/// A* shortest path between two OSM node IDs.
/// Returns (path of OSM IDs, distance in meters) or nil.
public func shortestPath(_ graph: CompactGraph, source: Int64, target: Int64)
    -> (path: [Int64], distance: Double)? {

    if source == target { return ([source], 0.0) }

    let srcIdx = graph.idxForOsmId(source)
    let tgtIdx = graph.idxForOsmId(target)
    let targetLat = Double(graph.nodeLats[Int(tgtIdx)])
    let targetLon = Double(graph.nodeLons[Int(tgtIdx)])
    let numNodes = graph.numNodes

    let cameFrom = UnsafeMutablePointer<Int32>.allocate(capacity: numNodes)
    cameFrom.initialize(repeating: -1, count: numNodes)
    defer { cameFrom.deallocate() }

    let gScore = UnsafeMutablePointer<Float>.allocate(capacity: numNodes)
    gScore.initialize(repeating: .infinity, count: numNodes)
    defer { gScore.deallocate() }

    gScore[Int(srcIdx)] = 0.0

    var counter = 0
    var openSet = MinHeap()
    openSet.push(HeapEntry(fScore: 0.0, gScore: 0.0, counter: 0, nodeIdx: srcIdx))

    while !openSet.isEmpty {
        let entry = openSet.pop()
        let current = entry.nodeIdx
        let g = entry.gScore

        if current == tgtIdx {
            let pathIndices = reconstructPath(cameFrom, srcIdx: srcIdx, tgtIdx: tgtIdx)
            let pathOsm = pathIndices.map { graph.nodeIds[Int($0)] }
            cameFrom.deinitialize(count: numNodes)
            gScore.deinitialize(count: numNodes)
            return (pathOsm, Double(g))
        }

        if g > gScore[Int(current)] { continue }

        let (targets, weights) = graph.neighbors(current)
        for j in targets.startIndex..<targets.endIndex {
            let neighbor = targets[j]
            let newG = g + weights[j]

            if newG < gScore[Int(neighbor)] {
                gScore[Int(neighbor)] = newG
                cameFrom[Int(neighbor)] = current
                let h = heuristicIdx(graph, neighbor, targetLat, targetLon)
                counter += 1
                openSet.push(HeapEntry(fScore: newG + h, gScore: newG,
                                       counter: counter, nodeIdx: neighbor))
            }
        }
    }

    cameFrom.deinitialize(count: numNodes)
    gScore.deinitialize(count: numNodes)
    return nil
}

// MARK: - Penalized A*

private func penalizedAstar(_ graph: CompactGraph, source: Int64, target: Int64,
                             walkedEdges: Set<EdgeKey>, penaltyFactor: Float)
    -> (path: [Int64], distance: Double)? {

    if source == target { return ([source], 0.0) }

    let srcIdx = graph.idxForOsmId(source)
    let tgtIdx = graph.idxForOsmId(target)
    let targetLat = Double(graph.nodeLats[Int(tgtIdx)])
    let targetLon = Double(graph.nodeLons[Int(tgtIdx)])
    let numNodes = graph.numNodes

    let cameFrom = UnsafeMutablePointer<Int32>.allocate(capacity: numNodes)
    cameFrom.initialize(repeating: -1, count: numNodes)
    defer { cameFrom.deallocate() }

    let gScore = UnsafeMutablePointer<Float>.allocate(capacity: numNodes)
    gScore.initialize(repeating: .infinity, count: numNodes)
    defer { gScore.deallocate() }

    gScore[Int(srcIdx)] = 0.0

    var counter = 0
    var openSet = MinHeap()
    openSet.push(HeapEntry(fScore: 0.0, gScore: 0.0, counter: 0, nodeIdx: srcIdx))

    while !openSet.isEmpty {
        let entry = openSet.pop()
        let current = entry.nodeIdx
        let g = entry.gScore

        if current == tgtIdx {
            let pathIndices = reconstructPath(cameFrom, srcIdx: srcIdx, tgtIdx: tgtIdx)
            let pathOsm = pathIndices.map { graph.nodeIds[Int($0)] }
            let actualDist = pathDistance(graph, pathIndices)
            cameFrom.deinitialize(count: numNodes)
            gScore.deinitialize(count: numNodes)
            return (pathOsm, actualDist)
        }

        if g > gScore[Int(current)] { continue }

        let currentOsm = graph.nodeIds[Int(current)]
        let (targets, weights) = graph.neighbors(current)
        for j in targets.startIndex..<targets.endIndex {
            let neighbor = targets[j]
            let edgeWeight = weights[j]

            let neighborOsm = graph.nodeIds[Int(neighbor)]
            let ek = EdgeKey(currentOsm, neighborOsm)

            var effectiveWeight = edgeWeight
            if walkedEdges.contains(ek) {
                effectiveWeight *= penaltyFactor
            }

            let newG = g + effectiveWeight
            if newG < gScore[Int(neighbor)] {
                gScore[Int(neighbor)] = newG
                cameFrom[Int(neighbor)] = current
                let h = heuristicIdx(graph, neighbor, targetLat, targetLon)
                counter += 1
                openSet.push(HeapEntry(fScore: newG + h, gScore: newG,
                                       counter: counter, nodeIdx: neighbor))
            }
        }
    }

    cameFrom.deinitialize(count: numNodes)
    gScore.deinitialize(count: numNodes)
    return nil
}

// MARK: - Novelty Route

private func buildResult(path: [Int64], distance: Double, baseDistance: Double,
                          walkedEdges: Set<EdgeKey>, graph: CompactGraph? = nil) -> RouteResult {
    let edges = pathToEdges(path)
    let novelty = computeNovelty(edges, walkedEdges)
    let overhead = baseDistance > 0 ? (distance - baseDistance) / baseDistance : 0
    let instructions: [NavigationStep]?
    if let g = graph, g.hasNameData {
        instructions = generateInstructions(path: path, graph: g)
    } else {
        instructions = nil
    }
    return RouteResult(path: path, edges: edges, distance: distance,
                       shortestDistance: baseDistance, novelty: novelty,
                       overhead: overhead, instructions: instructions)
}

/// Find a route maximizing novel (unwalked) edges.
public func noveltyRoute(_ graph: CompactGraph, source: Int64, target: Int64,
                          walkedEdges: Set<EdgeKey>,
                          minNovelty: Double = 0.3, maxOverhead: Double = 0.25)
    -> RouteResult? {

    // Phase 1: baseline shortest path
    guard let base = shortestPath(graph, source: source, target: target) else {
        return nil
    }

    let baseEdges = pathToEdges(base.path)
    let baseNovel = computeNovelty(baseEdges, walkedEdges)

    // Short-circuit only if baseline meets novelty AND the budget is small.
    // When the user asks for significant extra time (maxOverhead > 0.3),
    // proceed to the via-waypoint phase to produce a longer route.
    if baseNovel >= minNovelty && maxOverhead < 0.3 {
        return buildResult(path: base.path, distance: base.distance,
                           baseDistance: base.distance, walkedEdges: walkedEdges, graph: graph)
    }

    // Phase 2: iterative penalty search — find upper bound where novelty is met
    var bestResult: RouteResult? = buildResult(path: base.path, distance: base.distance,
                                               baseDistance: base.distance, walkedEdges: walkedEdges, graph: graph)
    var bestOverhead: Double = 0
    var bestMeetsNovelty = baseNovel >= minNovelty

    var loPenalty: Float = 1.0
    var hiPenalty: Float = 10.0

    // Skip penalty-based search when there are no walked edges (penalty has no effect)
    if walkedEdges.isEmpty {
        // Jump straight to Phase 5 (via-waypoint lengthening)
    } else {

    for _ in 0..<5 {
        guard let r = penalizedAstar(graph, source: source, target: target,
                                     walkedEdges: walkedEdges, penaltyFactor: hiPenalty) else {
            hiPenalty = (loPenalty + hiPenalty) / 2
            continue
        }
        let edges = pathToEdges(r.path)
        let novelty = computeNovelty(edges, walkedEdges)
        if novelty >= minNovelty { break }
        hiPenalty *= 2
        if hiPenalty > 100 { break }
    }

    // Phase 3: binary search — among routes meeting novelty, prefer those
    // that use the most of the time budget (highest overhead within limit)
    for _ in 0..<10 {
        let midPenalty = (loPenalty + hiPenalty) / 2
        guard let r = penalizedAstar(graph, source: source, target: target,
                                     walkedEdges: walkedEdges, penaltyFactor: midPenalty) else {
            hiPenalty = midPenalty
            continue
        }

        let edges = pathToEdges(r.path)
        let novelty = computeNovelty(edges, walkedEdges)
        let overhead = base.distance > 0 ? (r.distance - base.distance) / base.distance : 0
        let meetsNovelty = novelty >= minNovelty

        // Keep this result if it's better than what we have:
        // 1. First result meeting novelty beats any that don't
        // 2. Among results meeting novelty, prefer highest overhead (use the budget)
        // 3. Among results not meeting novelty, prefer highest novelty
        let dominated: Bool
        if meetsNovelty && overhead <= maxOverhead {
            dominated = bestMeetsNovelty && overhead <= bestOverhead
        } else if !meetsNovelty && overhead <= maxOverhead {
            dominated = bestMeetsNovelty || overhead <= bestOverhead
        } else {
            dominated = true // over budget
        }

        if !dominated {
            bestOverhead = overhead
            bestMeetsNovelty = meetsNovelty
            bestResult = buildResult(path: r.path, distance: r.distance,
                                     baseDistance: base.distance, walkedEdges: walkedEdges, graph: graph)
        }

        if novelty < minNovelty {
            loPenalty = midPenalty
        } else if overhead > maxOverhead {
            hiPenalty = midPenalty
        } else {
            loPenalty = midPenalty
        }
    }

    // Phase 4: fallback fixed penalties
    if bestResult == nil || !bestMeetsNovelty {
        for penalty: Float in [1.5, 2.0, 3.0, 5.0, 8.0] {
            guard let r = penalizedAstar(graph, source: source, target: target,
                                         walkedEdges: walkedEdges, penaltyFactor: penalty) else {
                continue
            }
            let edges = pathToEdges(r.path)
            let novelty = computeNovelty(edges, walkedEdges)
            let overhead = base.distance > 0 ? (r.distance - base.distance) / base.distance : 0
            let meetsNovelty = novelty >= minNovelty

            if overhead <= maxOverhead {
                let dominated: Bool
                if meetsNovelty {
                    dominated = bestMeetsNovelty && overhead <= bestOverhead
                } else {
                    dominated = bestMeetsNovelty || overhead <= bestOverhead
                }
                if !dominated {
                    bestOverhead = overhead
                    bestMeetsNovelty = meetsNovelty
                    bestResult = buildResult(path: r.path, distance: r.distance,
                                             baseDistance: base.distance, walkedEdges: walkedEdges)
                }
            }
        }
    }

    } // end if !walkedEdges.isEmpty

    // Phase 5: via-waypoint lengthening
    // If the best route is far shorter than the budget allows, route via an
    // intermediate waypoint offset perpendicular to the start→end line.
    // Try multiple offset scales since road distance >> straight-line distance.
    let bestDist = bestResult?.distance ?? base.distance
    let targetDist = base.distance * (1 + maxOverhead)

    if bestDist < targetDist * 0.85 {
        let srcIdx = graph.idxForOsmId(source)
        let tgtIdx = graph.idxForOsmId(target)
        let sLat = Double(graph.nodeLats[Int(srcIdx)])
        let sLon = Double(graph.nodeLons[Int(srcIdx)])
        let eLat = Double(graph.nodeLats[Int(tgtIdx)])
        let eLon = Double(graph.nodeLons[Int(tgtIdx)])

        let midLat = (sLat + eLat) / 2
        let midLon = (sLon + eLon) / 2
        let cosLat = cos(midLat * .pi / 180)

        // Direction vector (equirectangular)
        let dx = (eLon - sLon) * cosLat
        let dy = eLat - sLat
        let dirLen = sqrt(dx * dx + dy * dy)

        if dirLen > 0 {
            // Perpendicular unit vector
            let px = -dy / dirLen
            let py = dx / dirLen

            // Ideal straight-line offset from triangle geometry.
            // Road routing adds ~40% over straight-line, so we try several
            // scales from small to large to find one that fits the budget.
            let d = base.distance
            let D = targetDist
            let hIdeal = D > d ? sqrt(D * D - d * d) / 2 : d * 0.3

            let scales: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.15]
            let signs: [Double] = [1.0, -1.0]

            print("[Route] Via-waypoint: baseline=\(Int(d))m target=\(Int(D))m hIdeal=\(Int(hIdeal))m bestSoFar=\(Int(bestDist))m")

            for scale in scales {
                let h = hIdeal * scale
                let hDeg = h / 111320.0

                for sign in signs {
                    let wpLat = midLat + sign * px * hDeg
                    let wpLon = midLon + sign * py * hDeg / cosLat

                    let wpSnap = graph.findNearestNode(lat: wpLat, lon: wpLon)
                    let wpId = graph.nodeIds[Int(wpSnap.index)]

                    if wpId == source || wpId == target { continue }

                    guard let leg1 = shortestPath(graph, source: source, target: wpId),
                          let leg2 = shortestPath(graph, source: wpId, target: target)
                    else { continue }

                    let combinedDist = leg1.distance + leg2.distance
                    let combinedOverhead = d > 0 ? (combinedDist - d) / d : 0

                    print("[Route]   scale=\(scale) sign=\(Int(sign)) dist=\(Int(combinedDist))m overhead=\(String(format: "%.0f", combinedOverhead * 100))%")

                    if combinedOverhead <= maxOverhead && combinedOverhead > bestOverhead {
                        let combinedPath = leg1.path + leg2.path.dropFirst()
                        bestResult = buildResult(path: combinedPath, distance: combinedDist,
                                                 baseDistance: d, walkedEdges: walkedEdges,
                                                 graph: graph)
                        bestOverhead = combinedOverhead
                    }
                }
            }

            print("[Route] Via-waypoint result: \(bestOverhead > 0 ? "\(Int(bestResult?.distance ?? 0))m" : "none fit budget")")
        }
    }

    // Phase 6: worst-case fallback
    if bestResult == nil {
        bestResult = buildResult(path: base.path, distance: base.distance,
                                 baseDistance: base.distance, walkedEdges: walkedEdges, graph: graph)
    }

    return bestResult
}
