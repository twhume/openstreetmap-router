import Foundation

/// Calculate great-circle distance in meters between two lat/lon points.
public func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6371000.0
    let phi1 = lat1 * .pi / 180.0
    let phi2 = lat2 * .pi / 180.0
    let dphi = (lat2 - lat1) * .pi / 180.0
    let dlam = (lon2 - lon1) * .pi / 180.0
    let a = sin(dphi / 2) * sin(dphi / 2) +
            cos(phi1) * cos(phi2) * sin(dlam / 2) * sin(dlam / 2)
    return R * 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
}

/// Calculate initial bearing in degrees [0, 360) from point 1 to point 2.
public func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let phi1 = lat1 * .pi / 180.0
    let phi2 = lat2 * .pi / 180.0
    let dlam = (lon2 - lon1) * .pi / 180.0
    let y = sin(dlam) * cos(phi2)
    let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dlam)
    var degrees = atan2(y, x) * 180.0 / .pi
    if degrees < 0 { degrees += 360.0 }
    return degrees
}
