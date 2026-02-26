import Foundation
import RouterLib

// MARK: - Test Route Definitions

struct TestRoute {
    let name: String
    let startLat: Double
    let startLon: Double
    let endLat: Double
    let endLon: Double
    let approxKm: Double
}

let testRoutes: [TestRoute] = [
    // ~1km routes
    TestRoute(name: "Ferry Building to Embarcadero Center",
              startLat: 37.7955, startLon: -122.3937, endLat: 37.7946, endLon: -122.4010, approxKm: 1.0),
    TestRoute(name: "Castro to Dolores Park",
              startLat: 37.7609, startLon: -122.4350, endLat: 37.7596, endLon: -122.4269, approxKm: 1.0),
    TestRoute(name: "North Beach to Chinatown",
              startLat: 37.8005, startLon: -122.4102, endLat: 37.7941, endLon: -122.4068, approxKm: 1.0),

    // ~2km routes
    TestRoute(name: "Union Square to Civic Center",
              startLat: 37.7879, startLon: -122.4074, endLat: 37.7793, endLon: -122.4193, approxKm: 2.0),
    TestRoute(name: "Marina to Fisherman's Wharf",
              startLat: 37.8010, startLon: -122.4370, endLat: 37.8080, endLon: -122.4177, approxKm: 2.0),
    TestRoute(name: "Mission to Potrero Hill",
              startLat: 37.7599, startLon: -122.4148, endLat: 37.7614, endLon: -122.3929, approxKm: 2.0),

    // ~3km routes
    TestRoute(name: "UCSF to Twin Peaks",
              startLat: 37.7631, startLon: -122.4586, endLat: 37.7544, endLon: -122.4477, approxKm: 3.0),
    TestRoute(name: "Haight to SoMa",
              startLat: 37.7692, startLon: -122.4481, endLat: 37.7785, endLon: -122.4055, approxKm: 3.0),
    TestRoute(name: "Noe Valley to Mission Bay",
              startLat: 37.7502, startLon: -122.4337, endLat: 37.7706, endLon: -122.3930, approxKm: 3.5),

    // ~4-5km routes
    TestRoute(name: "Golden Gate Park East to Ferry Building",
              startLat: 37.7694, startLon: -122.4530, endLat: 37.7955, endLon: -122.3937, approxKm: 5.0),
    TestRoute(name: "Sunset District to Haight-Ashbury",
              startLat: 37.7535, startLon: -122.4900, endLat: 37.7692, endLon: -122.4481, approxKm: 4.0),
    TestRoute(name: "Presidio to Marina",
              startLat: 37.7989, startLon: -122.4662, endLat: 37.8010, endLon: -122.4370, approxKm: 4.0),

    // ~5-6km routes
    TestRoute(name: "Richmond to North Beach",
              startLat: 37.7800, startLon: -122.4650, endLat: 37.8005, endLon: -122.4102, approxKm: 5.5),
    TestRoute(name: "Bayview to Mission",
              startLat: 37.7340, startLon: -122.3920, endLat: 37.7599, endLon: -122.4148, approxKm: 5.0),
    TestRoute(name: "Glen Park to Castro",
              startLat: 37.7340, startLon: -122.4330, endLat: 37.7609, endLon: -122.4350, approxKm: 5.0),

    // ~7-8km routes
    TestRoute(name: "Ocean Beach to Embarcadero",
              startLat: 37.7604, startLon: -122.5097, endLat: 37.7946, endLon: -122.4010, approxKm: 8.0),
    TestRoute(name: "Presidio to Mission Dolores",
              startLat: 37.7989, startLon: -122.4662, endLat: 37.7596, endLon: -122.4269, approxKm: 7.0),

    // ~9-10km routes
    TestRoute(name: "Golden Gate Bridge to Dogpatch",
              startLat: 37.8078, startLon: -122.4750, endLat: 37.7578, endLon: -122.3870, approxKm: 10.0),
    TestRoute(name: "Lands End to AT&T Park",
              startLat: 37.7867, startLon: -122.5054, endLat: 37.7786, endLon: -122.3893, approxKm: 10.0),
    TestRoute(name: "Outer Sunset to Embarcadero",
              startLat: 37.7535, startLon: -122.5050, endLat: 37.7946, endLon: -122.4010, approxKm: 10.0),
]

// MARK: - Result Storage

struct RouteTestResult {
    let name: String
    let approxKm: Double
    var srcSnapM: Double = 0
    var tgtSnapM: Double = 0
    var snapMaxM: Double = 0
    var shortestPathFound = false
    var shortestDistM: Double? = nil
    var shortestEdges: Int = 0
    var shortestTimeS: Double = 0
    var srcNode: Int64 = 0
    var tgtNode: Int64 = 0
    var shortestPath: [Int64]? = nil

    // Phase 2
    var noveltyFreshNovelty: Double? = nil
    var noveltyFreshOverhead: Double? = nil
    var noveltyFreshTimeS: Double = 0
    var noveltyFreshOk: Bool? = nil

    // Phase 3
    var noveltyWalkedDistM: Double? = nil
    var noveltyWalkedNovelty: Double? = nil
    var noveltyWalkedOverhead: Double? = nil
    var noveltyWalkedTimeS: Double = 0
    var noveltyWalkedChanged: Bool? = nil
    var noveltyWalkedMeetsNovelty: Bool? = nil
    var noveltyWalkedMeetsOverhead: Bool? = nil
    var noveltyWalkedMeetsBoth: Bool? = nil
    var noveltyWalkedOk: Bool? = nil
    var noveltyWalkedEdges: Int = 0

    // Phase 4
    var novelty2ndNovelty: Double? = nil
    var novelty2ndOverhead: Double? = nil
    var novelty2ndChanged: Bool? = nil
    var novelty2ndMeetsBoth: Bool? = nil
    var novelty2ndTimeS: Double = 0
}

// MARK: - Helpers

func col(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

func fmtDist(_ d: Double?) -> String {
    guard let d = d else { return "N/A" }
    return String(format: "%.0f", d)
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    print("Usage: RouterCLI <path-to-walk_graph.bin>")
    exit(1)
}

let graphPath = CommandLine.arguments[1]
let graphURL = URL(fileURLWithPath: graphPath)

print(String(repeating: "=", count: 80))
print("SWIFT NOVELTY-WEIGHTED PEDESTRIAN ROUTER - RELIABILITY TEST SUITE")
print(String(repeating: "=", count: 80))

// Load graph
print("\nLoading graph...")
let loadStart = CFAbsoluteTimeGetCurrent()
let graph = try CompactGraph(contentsOf: graphURL)
let graphLoadTime = CFAbsoluteTimeGetCurrent() - loadStart
print("Graph loaded in \(String(format: "%.1f", graphLoadTime))s: \(graph.numberOfNodes()) nodes, \(graph.numberOfEdges()) edges")
print("  Format version: \(graph.version), name data: \(graph.hasNameData ? "yes" : "no")\n")

// Quick targeted test: 314 Los Palmos Dr → 635 Portola Dr (Mollie Stone's)
if CommandLine.arguments.count >= 3 && CommandLine.arguments[2] == "--test-portola" {
    let sLat = 37.7425, sLon = -122.4555
    let eLat = 37.7440, eLon = -122.4625
    let (srcIdx, srcSnap) = graph.findNearestNode(lat: sLat, lon: sLon)
    let (tgtIdx, tgtSnap) = graph.findNearestNode(lat: eLat, lon: eLon)
    print("Start snap: \(String(format: "%.0f", srcSnap))m, End snap: \(String(format: "%.0f", tgtSnap))m")
    let srcId = graph.nodeIds[Int(srcIdx)]
    let tgtId = graph.nodeIds[Int(tgtIdx)]
    if let sp = shortestPath(graph, source: srcId, target: tgtId) {
        let timeMin = sp.distance / 1.4 / 60
        print("Shortest: \(Int(sp.distance))m = \(String(format: "%.1f", timeMin)) min")
        for extra: Double in [5, 10, 15, 20, 30] {
            let maxOH = (extra * 60 * 1.4) / sp.distance
            print("\n--- Extra \(Int(extra)) min (maxOverhead=\(String(format: "%.0f", maxOH * 100))%, target=\(Int(sp.distance * (1 + maxOH)))m) ---")
            let nr = noveltyRoute(graph, source: srcId, target: tgtId,
                                  walkedEdges: Set<EdgeKey>(), minNovelty: 0.15, maxOverhead: maxOH)
            if let nr = nr {
                print("Result: \(Int(nr.distance))m = \(String(format: "%.1f", nr.distance / 1.4 / 60)) min, overhead=\(String(format: "%.0f", nr.overhead * 100))%")
            } else { print("No route found") }
        }
    } else { print("No shortest path!") }
    exit(0)
}

var results = [RouteTestResult]()

// ===== PHASE 1: Shortest path reliability =====
print(String(repeating: "=", count: 80))
print("PHASE 1: SHORTEST PATH RELIABILITY")
print(String(repeating: "=", count: 80))
print("\(col("#", 3)) \(col("Route", 45)) \(col("Snap(m)", 10)) \(col("Dist(m)", 10)) \(col("Edges", 7)) \(col("Time(s)", 8)) OK")
print(String(repeating: "-", count: 95))

for (i, route) in testRoutes.enumerated() {
    let t0 = CFAbsoluteTimeGetCurrent()

    let (srcIdx, srcSnap) = graph.findNearestNode(lat: route.startLat, lon: route.startLon)
    let (tgtIdx, tgtSnap) = graph.findNearestNode(lat: route.endLat, lon: route.endLon)
    let snapDist = max(srcSnap, tgtSnap)

    let srcNode = graph.nodeIds[Int(srcIdx)]
    let tgtNode = graph.nodeIds[Int(tgtIdx)]

    let spResult = shortestPath(graph, source: srcNode, target: tgtNode)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0

    var r = RouteTestResult(name: route.name, approxKm: route.approxKm)
    r.srcSnapM = srcSnap
    r.tgtSnapM = tgtSnap
    r.snapMaxM = snapDist
    r.srcNode = srcNode
    r.tgtNode = tgtNode

    if let sp = spResult {
        r.shortestPathFound = true
        r.shortestDistM = sp.distance
        r.shortestEdges = sp.path.count - 1
        r.shortestPath = sp.path
    }
    r.shortestTimeS = elapsed

    let status = r.shortestPathFound ? "OK" : "FAIL"
    let distStr = fmtDist(r.shortestDistM)
    let edgesStr = r.shortestPathFound ? "\(r.shortestEdges)" : "N/A"

    print("\(col("\(i+1)", 3)) \(col(route.name, 45)) \(col(String(format: "%.0f", snapDist), 10)) \(col(distStr, 10)) \(col(edgesStr, 7)) \(col(String(format: "%.2f", elapsed), 8)) \(status)")

    results.append(r)
}

// ===== NAVIGATION INSTRUCTIONS SAMPLE =====
if graph.hasNameData {
    print("\n" + String(repeating: "=", count: 80))
    print("NAVIGATION INSTRUCTIONS (sample routes)")
    print(String(repeating: "=", count: 80))

    // Show instructions for first 3 routes that have shortest paths
    var shown = 0
    for r in results where r.shortestPathFound && shown < 3 {
        guard let path = r.shortestPath else { continue }
        if let steps = generateInstructions(path: path, graph: graph) {
            print("\n  Route: \(r.name)")
            print("  Turn-by-turn directions:")
            for (j, step) in steps.enumerated() {
                if step.turnDirection == .arrive {
                    print("    \(j+1). \(step.instruction)")
                } else {
                    print("    \(j+1). \(step.instruction)  (\(String(format: "%.0f", step.distance))m)")
                }
            }
        } else {
            print("\n  Route: \(r.name) — no instructions available")
        }
        shown += 1
    }
    if shown == 0 {
        print("  No routes with instructions available.")
    }
} else {
    print("\n  (v1 graph — no navigation instructions available)")
}

// ===== PHASE 2: Novelty routing (fresh history) =====
print("\n" + String(repeating: "=", count: 80))
print("PHASE 2: NOVELTY ROUTING (NO HISTORY - SHOULD MATCH SHORTEST)")
print(String(repeating: "=", count: 80))
print("\(col("#", 3)) \(col("Route", 45)) \(col("Novel%", 8)) \(col("Overhead%", 10)) \(col("Time(s)", 8)) Match")
print(String(repeating: "-", count: 85))

let emptyWalked = Set<EdgeKey>()

for i in 0..<results.count {
    if !results[i].shortestPathFound {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 45)) SKIP (no shortest path)")
        continue
    }

    let t0 = CFAbsoluteTimeGetCurrent()
    let nr = noveltyRoute(graph, source: results[i].srcNode, target: results[i].tgtNode,
                          walkedEdges: emptyWalked)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0

    if let nr = nr {
        let matchesShortest = abs(nr.distance - results[i].shortestDistM!) < 1.0
        results[i].noveltyFreshNovelty = nr.novelty * 100
        results[i].noveltyFreshOverhead = nr.overhead * 100
        results[i].noveltyFreshTimeS = elapsed
        results[i].noveltyFreshOk = matchesShortest

        let matchStr = matchesShortest ? "YES" : "NO"
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 45)) \(col(String(format: "%.1f", nr.novelty * 100), 8)) \(col(String(format: "%.1f", nr.overhead * 100), 10)) \(col(String(format: "%.2f", elapsed), 8)) \(matchStr)")
    } else {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 45)) FAIL")
    }
}

// ===== PHASE 3: Record all shortest paths, then re-route =====
print("\n" + String(repeating: "=", count: 80))
print("PHASE 3: NOVELTY ROUTING AFTER RECORDING SHORTEST PATHS")
print(String(repeating: "=", count: 80))

// Record all shortest paths as walked
var walked = Set<EdgeKey>()
var recordedCount = 0
for r in results {
    if r.shortestPathFound, let path = r.shortestPath {
        for j in 0..<(path.count - 1) {
            walked.insert(EdgeKey(path[j], path[j + 1]))
            recordedCount += 1
        }
    }
}

print("Recorded \(recordedCount) edge traversals (\(walked.count) unique edges in history)\n")

print("\(col("#", 3)) \(col("Route", 40)) \(col("ShortD", 8)) \(col("NovelD", 8)) \(col("Novel%", 8)) \(col("Over%", 7)) \(col("Time(s)", 8)) Meets")
print(String(repeating: "-", count: 95))

for i in 0..<results.count {
    if !results[i].shortestPathFound {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) SKIP")
        continue
    }

    let t0 = CFAbsoluteTimeGetCurrent()
    let nr = noveltyRoute(graph, source: results[i].srcNode, target: results[i].tgtNode,
                          walkedEdges: walked, minNovelty: 0.3, maxOverhead: 0.25)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0

    guard let nr = nr else {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) FAIL - no route found")
        results[i].noveltyWalkedOk = false
        results[i].noveltyWalkedTimeS = elapsed
        continue
    }

    let meetsNovelty = nr.novelty >= 0.3
    let meetsOverhead = nr.overhead <= 0.25
    let meetsBoth = meetsNovelty && meetsOverhead
    let changed = abs(nr.distance - results[i].shortestDistM!) > 1.0

    results[i].noveltyWalkedDistM = nr.distance
    results[i].noveltyWalkedNovelty = nr.novelty * 100
    results[i].noveltyWalkedOverhead = nr.overhead * 100
    results[i].noveltyWalkedTimeS = elapsed
    results[i].noveltyWalkedChanged = changed
    results[i].noveltyWalkedMeetsNovelty = meetsNovelty
    results[i].noveltyWalkedMeetsOverhead = meetsOverhead
    results[i].noveltyWalkedMeetsBoth = meetsBoth
    results[i].noveltyWalkedOk = true
    results[i].noveltyWalkedEdges = nr.edges.count

    let constraint: String
    if meetsBoth { constraint = "BOTH" }
    else if meetsNovelty { constraint = "NOV" }
    else if meetsOverhead { constraint = "OVH" }
    else { constraint = "NONE" }

    print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) \(col(String(format: "%.0f", results[i].shortestDistM!), 8)) \(col(String(format: "%.0f", nr.distance), 8)) \(col(String(format: "%.1f", nr.novelty * 100), 8)) \(col(String(format: "%.1f", nr.overhead * 100), 7)) \(col(String(format: "%.2f", elapsed), 8)) \(constraint)")
}

// ===== PHASE 4: Record novelty routes, re-route again =====
print("\n" + String(repeating: "=", count: 80))
print("PHASE 4: RE-ROUTING AFTER RECORDING NOVELTY ROUTES (2ND WALK)")
print(String(repeating: "=", count: 80))

// Record novelty routes
for i in 0..<results.count {
    if results[i].noveltyWalkedOk == true, results[i].noveltyWalkedDistM != nil {
        let nr = noveltyRoute(graph, source: results[i].srcNode, target: results[i].tgtNode,
                              walkedEdges: walked, minNovelty: 0.3, maxOverhead: 0.25)
        if let nr = nr {
            for edge in nr.edges {
                walked.insert(edge)
            }
        }
    }
}

print("History now has \(walked.count) unique walked edges\n")

print("\(col("#", 3)) \(col("Route", 40)) \(col("Novel%", 8)) \(col("Over%", 7)) \(col("Changed", 8)) \(col("Time(s)", 8)) Meets")
print(String(repeating: "-", count: 85))

for i in 0..<results.count {
    if !results[i].shortestPathFound {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) SKIP")
        continue
    }

    let t0 = CFAbsoluteTimeGetCurrent()
    let nr = noveltyRoute(graph, source: results[i].srcNode, target: results[i].tgtNode,
                          walkedEdges: walked, minNovelty: 0.3, maxOverhead: 0.25)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0

    guard let nr = nr else {
        print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) FAIL")
        results[i].novelty2ndMeetsBoth = nil
        continue
    }

    let prevDist = results[i].noveltyWalkedDistM ?? results[i].shortestDistM!
    let changed = abs(nr.distance - prevDist) > 1.0
    let meetsNovelty = nr.novelty >= 0.3
    let meetsOverhead = nr.overhead <= 0.25
    let meetsBoth = meetsNovelty && meetsOverhead

    results[i].novelty2ndNovelty = nr.novelty * 100
    results[i].novelty2ndOverhead = nr.overhead * 100
    results[i].novelty2ndChanged = changed
    results[i].novelty2ndMeetsBoth = meetsBoth
    results[i].novelty2ndTimeS = elapsed

    let constraint: String
    if meetsBoth { constraint = "BOTH" }
    else if meetsNovelty { constraint = "NOV" }
    else if meetsOverhead { constraint = "OVH" }
    else { constraint = "NONE" }

    let changedStr = changed ? "YES" : "NO"
    print("\(col("\(i+1)", 3)) \(col(results[i].name, 40)) \(col(String(format: "%.1f", nr.novelty * 100), 8)) \(col(String(format: "%.1f", nr.overhead * 100), 7)) \(col(changedStr, 8)) \(col(String(format: "%.2f", elapsed), 8)) \(constraint)")
}

// ===== SUMMARY REPORT =====
print("\n" + String(repeating: "=", count: 80))
print("SUMMARY REPORT")
print(String(repeating: "=", count: 80))

let total = results.count
let spFound = results.filter { $0.shortestPathFound }.count
let spFailed = total - spFound

print("\n1. SHORTEST PATH RELIABILITY")
print("   Routes tested:     \(total)")
print("   Paths found:       \(spFound)/\(total) (\(String(format: "%.0f", Double(spFound) / Double(total) * 100))%)")
if spFailed > 0 {
    print("   Paths NOT found:   \(spFailed)")
    for r in results where !r.shortestPathFound {
        print("     - \(r.name)")
    }
}

// Snap distances
let snapDists = results.map { $0.snapMaxM }
print("\n   Node snap distance (max of src/tgt):")
print("     Mean:  \(String(format: "%.0f", snapDists.reduce(0, +) / Double(snapDists.count)))m")
print("     Max:   \(String(format: "%.0f", snapDists.max()!))m")
print("     >100m: \(snapDists.filter { $0 > 100 }.count)")

// Timing
let spTimes = results.map { $0.shortestTimeS }
print("\n   Shortest path timing:")
print("     Mean:  \(String(format: "%.2f", spTimes.reduce(0, +) / Double(spTimes.count)))s")
print("     Max:   \(String(format: "%.2f", spTimes.max()!))s")
print("     Min:   \(String(format: "%.2f", spTimes.min()!))s")

// Distance accuracy
print("\n   Distance accuracy (actual vs crow-flies approx):")
var ratios = [Double]()
for r in results where r.shortestPathFound {
    if let d = r.shortestDistM, r.approxKm > 0 {
        ratios.append(d / (r.approxKm * 1000))
    }
}
if !ratios.isEmpty {
    print("     Mean ratio (actual/approx): \(String(format: "%.2f", ratios.reduce(0, +) / Double(ratios.count)))")
    print("     Min ratio:  \(String(format: "%.2f", ratios.min()!))")
    print("     Max ratio:  \(String(format: "%.2f", ratios.max()!))")
}

// Phase 2
let freshTested = results.filter { $0.noveltyFreshOk != nil }
let freshMatch = freshTested.filter { $0.noveltyFreshOk == true }.count
print("\n2. NOVELTY ROUTING (NO HISTORY)")
print("   Routes tested:     \(freshTested.count)")
if !freshTested.isEmpty {
    print("   Matched shortest:  \(freshMatch)/\(freshTested.count) (\(String(format: "%.0f", Double(freshMatch) / Double(freshTested.count) * 100))% - should be 100%)")
}

// Phase 3
let walkedTested = results.filter { $0.noveltyWalkedOk != nil }
let walkedOk = walkedTested.filter { $0.noveltyWalkedOk == true }.count
let walkedBoth = walkedTested.filter { $0.noveltyWalkedMeetsBoth == true }.count
let walkedNoveltyOnly = walkedTested.filter { $0.noveltyWalkedMeetsNovelty == true }.count
let walkedOverheadOnly = walkedTested.filter { $0.noveltyWalkedMeetsOverhead == true }.count
let walkedChanged = walkedTested.filter { $0.noveltyWalkedChanged == true }.count

print("\n3. NOVELTY ROUTING (AFTER 1ST WALK)")
print("   Routes tested:     \(walkedTested.count)")
print("   Routes found:      \(walkedOk)/\(walkedTested.count)")
if walkedOk > 0 {
    print("   Route changed:     \(walkedChanged)/\(walkedOk) (\(String(format: "%.0f", Double(walkedChanged) / Double(walkedOk) * 100))% - should be high)")
    print("   Meets BOTH:        \(walkedBoth)/\(walkedOk) (\(String(format: "%.0f", Double(walkedBoth) / Double(walkedOk) * 100))%)")
    print("   Meets novelty:     \(walkedNoveltyOnly)/\(walkedOk) (\(String(format: "%.0f", Double(walkedNoveltyOnly) / Double(walkedOk) * 100))%)")
    print("   Meets overhead:    \(walkedOverheadOnly)/\(walkedOk) (\(String(format: "%.0f", Double(walkedOverheadOnly) / Double(walkedOk) * 100))%)")

    let novelties = results.compactMap { $0.noveltyWalkedNovelty }
    let overheads = results.compactMap { $0.noveltyWalkedOverhead }
    let times = results.compactMap { r -> Double? in r.noveltyWalkedOk == true ? r.noveltyWalkedTimeS : nil }

    if !novelties.isEmpty {
        print("\n   Novelty % (after 1st walk):")
        print("     Mean:  \(String(format: "%.1f", novelties.reduce(0, +) / Double(novelties.count)))%")
        print("     Min:   \(String(format: "%.1f", novelties.min()!))%")
        print("     Max:   \(String(format: "%.1f", novelties.max()!))%")
    }
    if !overheads.isEmpty {
        print("\n   Overhead % (after 1st walk):")
        print("     Mean:  \(String(format: "%.1f", overheads.reduce(0, +) / Double(overheads.count)))%")
        print("     Min:   \(String(format: "%.1f", overheads.min()!))%")
        print("     Max:   \(String(format: "%.1f", overheads.max()!))%")
    }
    if !times.isEmpty {
        print("\n   Novelty routing timing:")
        print("     Mean:  \(String(format: "%.2f", times.reduce(0, +) / Double(times.count)))s")
        print("     Max:   \(String(format: "%.2f", times.max()!))s")
    }
}

// Phase 4
let walk2Tested = results.filter { $0.novelty2ndMeetsBoth != nil }
let walk2Both = walk2Tested.filter { $0.novelty2ndMeetsBoth == true }.count
let walk2Changed = walk2Tested.filter { $0.novelty2ndChanged == true }.count

print("\n4. NOVELTY ROUTING (AFTER 2ND WALK)")
print("   Routes tested:     \(walk2Tested.count)")
if !walk2Tested.isEmpty {
    print("   Meets BOTH:        \(walk2Both)/\(walk2Tested.count) (\(String(format: "%.0f", Double(walk2Both) / Double(walk2Tested.count) * 100))%)")
    print("   Route changed:     \(walk2Changed)/\(walk2Tested.count) (\(String(format: "%.0f", Double(walk2Changed) / Double(walk2Tested.count) * 100))%)")

    let novelties2 = results.compactMap { $0.novelty2ndNovelty }
    if !novelties2.isEmpty {
        print("\n   Novelty % (after 2nd walk):")
        print("     Mean:  \(String(format: "%.1f", novelties2.reduce(0, +) / Double(novelties2.count)))%")
        print("     Min:   \(String(format: "%.1f", novelties2.min()!))%")
        print("     Max:   \(String(format: "%.1f", novelties2.max()!))%")
    }
}

// Overall assessment
print("\n" + String(repeating: "=", count: 80))
print("OVERALL ASSESSMENT")
print(String(repeating: "=", count: 80))

var issues = [String]()
if spFailed > 0 {
    issues.append("- \(spFailed) shortest path(s) failed to find a route")
}
if freshMatch < freshTested.count {
    issues.append("- \(freshTested.count - freshMatch) route(s) didn't match shortest path with empty history")
}
if walkedOk > 0 && walkedBoth < walkedOk {
    issues.append("- \(walkedOk - walkedBoth) route(s) failed to meet both novelty+overhead constraints after 1st walk")
}
if walkedOk > 0 && walkedChanged < walkedOk {
    issues.append("- \(walkedOk - walkedChanged) route(s) didn't change after recording walk history")
}
if spTimes.contains(where: { $0 > 30 }) {
    issues.append("- Some shortest path queries took >30s")
}
if results.contains(where: { $0.noveltyWalkedTimeS > 60 }) {
    issues.append("- Some novelty routing queries took >60s")
}
if snapDists.max()! > 200 {
    issues.append("- Maximum node snap distance was \(String(format: "%.0f", snapDists.max()!))m (graph coverage gap)")
}

if issues.isEmpty {
    print("\nAll tests passed with no issues detected.")
} else {
    print("\nIssues found (\(issues.count)):")
    for issue in issues {
        print("  \(issue)")
    }
}
