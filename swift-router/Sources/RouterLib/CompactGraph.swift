import Foundation

/// CSR-format graph loaded from a flat binary file.
///
/// Binary layout:
///   Header (32 bytes): magic "CSRG", version u32 (1 or 2), num_nodes u32, num_directed_edges u32, 16 reserved
///   Data: node_ids(Int64), node_lats(Float32), node_lons(Float32),
///         adj_offsets(Int32 × numNodes+1), adj_targets(Int32), adj_weights(Float32)
///   v2 additions: edge_name_indices(Int32), edge_highway_indices(Int32),
///                 name_table(string table), highway_table(string table)
public final class CompactGraph {
    public let numNodes: Int
    public let numDirectedEdges: Int
    public let version: UInt32

    private let nsData: NSData

    // Typed pointers into `data`
    public let nodeIds: UnsafeBufferPointer<Int64>
    public let nodeLats: UnsafeBufferPointer<Float32>
    public let nodeLons: UnsafeBufferPointer<Float32>
    public let adjOffsets: UnsafeBufferPointer<Int32>
    public let adjTargets: UnsafeBufferPointer<Int32>
    public let adjWeights: UnsafeBufferPointer<Float32>

    // v2: name/highway data (nil for v1)
    public let edgeNameIndices: UnsafeBufferPointer<UInt16>?
    public let edgeHighwayIndices: UnsafeBufferPointer<UInt8>?
    public let nameTable: [String]?
    public let highwayTable: [String]?

    // OSM ID → array index
    private var nodeIdToIdx: [Int64: Int32]

    // Lazy KDTree
    private var kdTree: KDTree?
    private var kdTreeCosLat: Double = 1.0

    public init(contentsOf url: URL) throws {
        // Use NSData for a stable .bytes pointer valid for the object's lifetime
        let nd = try NSData(contentsOf: url, options: .mappedIfSafe)
        self.nsData = nd
        let base = nd.bytes

        // Parse header
        guard nd.length >= 32 else {
            fatalError("File too small for header")
        }

        let magic = Data(bytes: base, count: 4)
        guard String(data: magic, encoding: .ascii) == "CSRG" else {
            fatalError("Invalid magic bytes")
        }

        let ver = base.load(fromByteOffset: 4, as: UInt32.self)
        guard ver == 1 || ver == 2 else {
            fatalError("Unsupported version \(ver)")
        }
        self.version = ver

        let numNodes32 = base.load(fromByteOffset: 8, as: UInt32.self)
        let numEdges32 = base.load(fromByteOffset: 12, as: UInt32.self)

        let nn = Int(numNodes32)
        let ne = Int(numEdges32)
        self.numNodes = nn
        self.numDirectedEdges = ne

        // Compute offsets into the data buffer
        let headerSize = 32
        var offset = headerSize

        let nodeIdsSize = nn * MemoryLayout<Int64>.size
        let nodeLatsSize = nn * MemoryLayout<Float32>.size
        let nodeLonsSize = nn * MemoryLayout<Float32>.size
        let adjOffsetsSize = (nn + 1) * MemoryLayout<Int32>.size
        let adjTargetsSize = ne * MemoryLayout<Int32>.size
        let adjWeightsSize = ne * MemoryLayout<Float32>.size

        let v1Size = headerSize + nodeIdsSize + nodeLatsSize + nodeLonsSize +
                     adjOffsetsSize + adjTargetsSize + adjWeightsSize
        guard nd.length >= v1Size else {
            fatalError("File too small: \(nd.length) < \(v1Size)")
        }

        // Bind typed pointers directly from base
        self.nodeIds = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Int64.self),
            count: nn
        )
        offset += nodeIdsSize

        self.nodeLats = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Float32.self),
            count: nn
        )
        offset += nodeLatsSize

        self.nodeLons = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Float32.self),
            count: nn
        )
        offset += nodeLonsSize

        self.adjOffsets = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Int32.self),
            count: nn + 1
        )
        offset += adjOffsetsSize

        self.adjTargets = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Int32.self),
            count: ne
        )
        offset += adjTargetsSize

        self.adjWeights = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: Float32.self),
            count: ne
        )
        offset += adjWeightsSize

        // v2: parse name/highway data
        if ver == 2 {
            let edgeNameIndicesSize = ne * MemoryLayout<UInt16>.size
            let edgeHighwayIndicesSize = ne * MemoryLayout<UInt8>.size

            guard nd.length >= offset + edgeNameIndicesSize + edgeHighwayIndicesSize else {
                fatalError("v2 file too small for edge name/highway indices")
            }

            self.edgeNameIndices = UnsafeBufferPointer(
                start: base.advanced(by: offset).assumingMemoryBound(to: UInt16.self),
                count: ne
            )
            offset += edgeNameIndicesSize

            self.edgeHighwayIndices = UnsafeBufferPointer(
                start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                count: ne
            )
            offset += edgeHighwayIndicesSize

            // Parse string tables
            self.nameTable = CompactGraph.readStringTable(base: base, offset: &offset, fileLength: nd.length)
            self.highwayTable = CompactGraph.readStringTable(base: base, offset: &offset, fileLength: nd.length)
        } else {
            self.edgeNameIndices = nil
            self.edgeHighwayIndices = nil
            self.nameTable = nil
            self.highwayTable = nil
        }

        // Build OSM ID → index lookup
        var idMap = [Int64: Int32](minimumCapacity: nn)
        for i in 0..<nn {
            idMap[nodeIds[i]] = Int32(i)
        }
        self.nodeIdToIdx = idMap
    }

    /// Read a string table: u32 count, then per string: u16 length + UTF-8 bytes.
    /// Uses memcpy for reads since offsets may not be naturally aligned after variable-length strings.
    private static func readStringTable(base: UnsafeRawPointer, offset: inout Int, fileLength: Int) -> [String] {
        guard fileLength >= offset + 4 else {
            fatalError("File too small for string table count")
        }
        var count32: UInt32 = 0
        memcpy(&count32, base.advanced(by: offset), 4)
        let count = Int(count32)
        offset += 4

        var strings = [String]()
        strings.reserveCapacity(count)
        for _ in 0..<count {
            guard fileLength >= offset + 2 else {
                fatalError("File too small for string length")
            }
            var len16: UInt16 = 0
            memcpy(&len16, base.advanced(by: offset), 2)
            let len = Int(len16)
            offset += 2

            guard fileLength >= offset + len else {
                fatalError("File too small for string data")
            }
            if len == 0 {
                strings.append("")
            } else {
                let data = Data(bytes: base.advanced(by: offset), count: len)
                strings.append(String(data: data, encoding: .utf8) ?? "")
            }
            offset += len
        }
        return strings
    }

    /// Return (targets, weights) slices for neighbors of node at `idx`.
    @inline(__always)
    public func neighbors(_ idx: Int32) -> (targets: UnsafeBufferPointer<Int32>.SubSequence,
                                             weights: UnsafeBufferPointer<Float32>.SubSequence) {
        let start = Int(adjOffsets[Int(idx)])
        let end = Int(adjOffsets[Int(idx) + 1])
        return (adjTargets[start..<end], adjWeights[start..<end])
    }

    /// Array index for an OSM node ID.
    @inline(__always)
    public func idxForOsmId(_ osmId: Int64) -> Int32 {
        guard let idx = nodeIdToIdx[osmId] else {
            fatalError("Unknown OSM ID \(osmId)")
        }
        return idx
    }

    public func numberOfNodes() -> Int { numNodes }
    public func numberOfEdges() -> Int { numDirectedEdges / 2 }

    /// Whether this graph has street name data (v2 format).
    public var hasNameData: Bool {
        return edgeNameIndices != nil && nameTable != nil
    }

    /// Street name for a directed edge from→to, or nil if unnamed or no name data.
    public func edgeName(from: Int32, to: Int32) -> String? {
        guard let indices = edgeNameIndices, let table = nameTable else { return nil }
        let start = Int(adjOffsets[Int(from)])
        let end = Int(adjOffsets[Int(from) + 1])
        for j in start..<end {
            if adjTargets[j] == to {
                let idx = Int(indices[j])
                let name = table[idx]
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// Highway type for a directed edge from→to, or nil if no data.
    public func edgeHighway(from: Int32, to: Int32) -> String? {
        guard let indices = edgeHighwayIndices, let table = highwayTable else { return nil }
        let start = Int(adjOffsets[Int(from)])
        let end = Int(adjOffsets[Int(from) + 1])
        for j in start..<end {
            if adjTargets[j] == to {
                let idx = Int(indices[j])
                let hw = table[idx]
                return hw.isEmpty ? nil : hw
            }
        }
        return nil
    }

    /// Find the nearest graph node to a lat/lon coordinate.
    /// Returns (index, distanceInMeters).
    public func findNearestNode(lat: Double, lon: Double) -> (index: Int32, distMeters: Double) {
        if kdTree == nil { buildKDTree() }

        let cosLat = kdTreeCosLat
        let qx = lat * .pi / 180.0 * 6371000.0
        let qy = lon * .pi / 180.0 * 6371000.0 * cosLat

        let k = min(10, numNodes)
        let candidates = kdTree!.nearest(qx: qx, qy: qy, k: k)

        var bestIdx: Int32 = 0
        var bestDist = Double.infinity
        for idx in candidates {
            let d = haversine(lat1: lat, lon1: lon,
                              lat2: Double(nodeLats[Int(idx)]),
                              lon2: Double(nodeLons[Int(idx)]))
            if d < bestDist {
                bestDist = d
                bestIdx = idx
            }
        }
        return (bestIdx, bestDist)
    }

    /// Cache fingerprint that changes when the graph changes.
    private func cacheFingerprint(graphFileSize: Int) -> String {
        "\(numNodes)-\(numDirectedEdges)-\(version)-\(graphFileSize)"
    }

    /// Save the built KDTree to a binary cache file.
    /// Returns true on success.
    ///
    /// Header layout (24 bytes, all fields naturally aligned):
    ///   magic "KDTR" (4B) | version UInt32 (4B) | cosLat Double (8B) |
    ///   nodeCount UInt32 (4B) | fpLen UInt32 (4B)
    /// Then: fingerprint UTF-8 bytes, padded to 8-byte alignment, then KDNode array.
    public func saveKDTreeCache(to url: URL, graphFileSize: Int) -> Bool {
        guard let tree = kdTree else { return false }

        let magic: [UInt8] = [0x4B, 0x44, 0x54, 0x52] // "KDTR"
        let ver: UInt32 = 1
        let cosLat = kdTreeCosLat
        let count: UInt32 = UInt32(tree.nodeCount)

        let fp = cacheFingerprint(graphFileSize: graphFileSize)
        let fpData = Array(fp.utf8)
        let fpLen: UInt32 = UInt32(fpData.count)

        let headerSize = 24
        let fpPaddedSize = (fpData.count + 7) & ~7

        var data = Data()
        data.reserveCapacity(headerSize + fpPaddedSize + tree.nodeCount * MemoryLayout<KDTree.KDNode>.stride)

        // Header: magic(4) + version(4) + cosLat(8) + nodeCount(4) + fpLen(4)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: ver) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cosLat) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: count) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fpLen) { data.append(contentsOf: $0) }
        data.append(contentsOf: fpData)
        // Pad to 8-byte alignment
        let pad = fpPaddedSize - fpData.count
        if pad > 0 { data.append(contentsOf: [UInt8](repeating: 0, count: pad)) }

        // Append raw node bytes
        tree.withUnsafeNodeBuffer { buf in
            data.append(contentsOf: buf)
        }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[CompactGraph] Failed to save KDTree cache: \(error)")
            return false
        }
    }

    /// Load a cached KDTree from a binary file. Returns true if the cache
    /// was valid and loaded successfully.
    public func loadKDTreeCache(from url: URL, graphFileSize: Int) -> Bool {
        guard let nd = try? NSData(contentsOf: url, options: .mappedIfSafe) else { return false }
        let base = nd.bytes
        let len = nd.length

        // Need at least the fixed header (24 bytes)
        guard len >= 24 else { return false }

        // Validate magic
        let magic = Data(bytes: base, count: 4)
        guard String(data: magic, encoding: .ascii) == "KDTR" else { return false }

        let ver = base.load(fromByteOffset: 4, as: UInt32.self)
        guard ver == 1 else { return false }

        // cosLat at offset 8 (8-byte aligned for Double)
        let cosLat = base.load(fromByteOffset: 8, as: Double.self)
        let nodeCount = Int(base.load(fromByteOffset: 16, as: UInt32.self))
        let fpLen = Int(base.load(fromByteOffset: 20, as: UInt32.self))

        let fpPaddedSize = (fpLen + 7) & ~7
        let nodeDataOffset = 24 + fpPaddedSize
        let nodeStride = MemoryLayout<KDTree.KDNode>.stride
        let expectedLen = nodeDataOffset + nodeCount * nodeStride
        guard len >= expectedLen else { return false }

        // Validate fingerprint
        let fpBytes = Data(bytes: base.advanced(by: 24), count: fpLen)
        guard let storedFP = String(data: fpBytes, encoding: .utf8) else { return false }
        let expectedFP = cacheFingerprint(graphFileSize: graphFileSize)
        guard storedFP == expectedFP else { return false }

        // Load the tree
        let tree = KDTree(rawNodeData: base.advanced(by: nodeDataOffset), nodeCount: nodeCount)
        self.kdTree = tree
        self.kdTreeCosLat = cosLat

        return true
    }

    private func buildKDTree() {
        var sumLat: Double = 0
        for i in 0..<numNodes {
            sumLat += Double(nodeLats[i])
        }
        let meanLat = sumLat / Double(numNodes)
        let cosLat = cos(meanLat * .pi / 180.0)
        kdTreeCosLat = cosLat

        var points = [KDPoint]()
        points.reserveCapacity(numNodes)
        for i in 0..<numNodes {
            let x = Double(nodeLats[i]) * .pi / 180.0 * 6371000.0
            let y = Double(nodeLons[i]) * .pi / 180.0 * 6371000.0 * cosLat
            points.append(KDPoint(x: x, y: y, index: Int32(i)))
        }

        kdTree = KDTree(points: points)
    }
}

// MARK: - Quickselect

/// Rearranges `a[start..<end]` so that `a[mid]` is the element that would be
/// at index `mid` in a sorted array, with all elements before `mid` ≤ it and
/// all elements after ≥ it.  Expected O(n) using median-of-three pivot.
private func nthElement<T>(_ a: inout [T], start: Int, end: Int, mid: Int,
                           by less: (T, T) -> Bool) {
    var lo = start
    var hi = end
    while hi - lo > 1 {
        // Median-of-three pivot selection
        let m = lo + (hi - lo) / 2
        if less(a[m], a[lo]) { a.swapAt(lo, m) }
        if less(a[hi - 1], a[lo]) { a.swapAt(lo, hi - 1) }
        if less(a[m], a[hi - 1]) { a.swapAt(m, hi - 1) }
        // pivot is now at hi-1
        let pivot = a[hi - 1]

        var i = lo
        var j = hi - 2
        while i <= j {
            while i <= j && less(a[i], pivot) { i += 1 }
            while i <= j && less(pivot, a[j]) { j -= 1 }
            if i <= j {
                a.swapAt(i, j)
                i += 1
                if j == 0 { break }
                j -= 1
            }
        }
        a.swapAt(i, hi - 1)

        if i == mid {
            return
        } else if mid < i {
            hi = i
        } else {
            lo = i + 1
        }
    }
}

// MARK: - KDTree

struct KDPoint {
    var x: Double
    var y: Double
    var index: Int32
}

final class KDTree {
    private var nodes: [KDNode]

    struct KDNode {
        var x: Double
        var y: Double
        var index: Int32
        var left: Int32   // -1 = none
        var right: Int32  // -1 = none
    }

    var nodeCount: Int { nodes.count }

    /// Load from raw bytes (deserialization).
    init(rawNodeData: UnsafeRawPointer, nodeCount: Int) {
        let buffer = UnsafeBufferPointer(
            start: rawNodeData.assumingMemoryBound(to: KDNode.self),
            count: nodeCount
        )
        self.nodes = Array(buffer)
    }

    /// Provide read access to the node array for serialization.
    func withUnsafeNodeBuffer<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        nodes.withUnsafeBytes(body)
    }

    init(points: [KDPoint]) {
        nodes = []
        nodes.reserveCapacity(points.count)
        var pts = points
        _ = build(&pts, start: 0, end: pts.count, depth: 0)
    }

    private func build(_ pts: inout [KDPoint], start: Int, end: Int, depth: Int) -> Int32 {
        if start >= end { return -1 }
        if start + 1 == end {
            let p = pts[start]
            let idx = Int32(nodes.count)
            nodes.append(KDNode(x: p.x, y: p.y, index: p.index, left: -1, right: -1))
            return idx
        }

        let axis = depth % 2
        let mid = (start + end) / 2

        // Quickselect to place median in O(n)
        if axis == 0 {
            nthElement(&pts, start: start, end: end, mid: mid, by: { $0.x < $1.x })
        } else {
            nthElement(&pts, start: start, end: end, mid: mid, by: { $0.y < $1.y })
        }

        let p = pts[mid]
        let nodeIdx = Int32(nodes.count)
        nodes.append(KDNode(x: p.x, y: p.y, index: p.index, left: -1, right: -1))

        let left = build(&pts, start: start, end: mid, depth: depth + 1)
        let right = build(&pts, start: mid + 1, end: end, depth: depth + 1)

        nodes[Int(nodeIdx)].left = left
        nodes[Int(nodeIdx)].right = right

        return nodeIdx
    }

    /// Find k nearest points to (qx, qy). Returns array of original indices.
    func nearest(qx: Double, qy: Double, k: Int) -> [Int32] {
        var heap = BoundedMaxHeap(capacity: k)
        search(nodeIdx: 0, qx: qx, qy: qy, depth: 0, heap: &heap)
        return heap.indices()
    }

    private func search(nodeIdx: Int32, qx: Double, qy: Double, depth: Int, heap: inout BoundedMaxHeap) {
        if nodeIdx < 0 { return }
        let node = nodes[Int(nodeIdx)]

        let dx = qx - node.x
        let dy = qy - node.y
        let dist2 = dx * dx + dy * dy

        heap.insert(dist2: dist2, index: node.index)

        let axis = depth % 2
        let diff = axis == 0 ? dx : dy

        let first = diff < 0 ? node.left : node.right
        let second = diff < 0 ? node.right : node.left

        search(nodeIdx: first, qx: qx, qy: qy, depth: depth + 1, heap: &heap)

        if diff * diff < heap.maxDist2 || !heap.isFull {
            search(nodeIdx: second, qx: qx, qy: qy, depth: depth + 1, heap: &heap)
        }
    }
}

/// Fixed-capacity max-heap for k-nearest-neighbor queries.
private struct BoundedMaxHeap {
    private var items: [(dist2: Double, index: Int32)]
    let capacity: Int
    var maxDist2: Double = .infinity

    var isFull: Bool { items.count >= capacity }

    init(capacity: Int) {
        self.capacity = capacity
        self.items = []
        items.reserveCapacity(capacity + 1)
    }

    mutating func insert(dist2: Double, index: Int32) {
        if items.count < capacity {
            items.append((dist2, index))
            if items.count == capacity {
                // Build heap
                for i in stride(from: items.count / 2 - 1, through: 0, by: -1) {
                    siftDown(i)
                }
                maxDist2 = items[0].dist2
            }
        } else if dist2 < items[0].dist2 {
            items[0] = (dist2, index)
            siftDown(0)
            maxDist2 = items[0].dist2
        }
    }

    func indices() -> [Int32] {
        items.map { $0.index }
    }

    private mutating func siftDown(_ i: Int) {
        var pos = i
        let n = items.count
        while true {
            var largest = pos
            let left = 2 * pos + 1
            let right = 2 * pos + 2
            if left < n && items[left].dist2 > items[largest].dist2 { largest = left }
            if right < n && items[right].dist2 > items[largest].dist2 { largest = right }
            if largest == pos { break }
            items.swapAt(pos, largest)
            pos = largest
        }
    }
}
