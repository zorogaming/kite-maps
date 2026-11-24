import Foundation

/**
 * Posted speed limits along a route from the public Valhalla server (FOSSGIS, the same people as
 * the open router), which matches the route to OpenStreetMap's roads and says each one's limit.
 * It answers a whole drive in under a second, where the public Overpass servers can take a minute
 * or not answer at all at night; Overpass still brings the cameras and traffic lights.
 */
public enum Valhalla {
    static let endpoint = URL(string: "https://valhalla1.openstreetmap.de/trace_attributes")!
    private static let routeEndpoint = URL(string: "https://valhalla1.openstreetmap.de/route")!

    /** Motorcycle-specific routes and turn instructions from the open Valhalla router. */
    public static func motorcycleRoutes(from start: LatLng, to destination: LatLng, via: [LatLng] = [],
                                        heading: Double? = nil, avoidHighways: Bool = false,
                                        avoidTolls: Bool = false, alternatives: Bool = false) async throws -> [Route] {
        let points = [start] + via + [destination]
        let locations: [[String: Any]] = points.enumerated().map { index, point in
            var location: [String: Any] = [
                "lat": point.lat,
                "lon": point.lng,
                "type": index == 0 || index == points.count - 1 ? "break" : "through",
            ]
            if index == 0, let heading { location["heading"] = heading }
            if index == 0, heading != nil { location["heading_tolerance"] = 60 }
            return location
        }
        var motorcycleOptions: [String: Any] = [
            "use_highways": avoidHighways ? 0.0 : 0.5,
            "use_trails": 0.0,
        ]
        if avoidTolls { motorcycleOptions["use_tolls"] = 0.0 }
        var body: [String: Any] = [
            "locations": locations,
            "costing": "motorcycle",
            "costing_options": ["motorcycle": motorcycleOptions],
            "format": "osrm",
            "shape_format": "polyline6",
            "units": "kilometers",
            "language": "en-US",
            "roundabout_exits": true,
            "turn_lanes": true,
        ]
        if alternatives, via.isEmpty { body["alternates"] = 2 }
        var request = URLRequest(url: routeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OSRM.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VelaError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw VelaError.unexpectedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "Valhalla motorcycle route")
        }
        return OSRM.parse(data, mode: .motorcycle).map { route in
            var route = route
            route.source = "osm"
            StepMerge.tidy(&route.maneuvers)
            return Roundabouts.settle(route)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": OSRM.userAgent]
        return URLSession(configuration: c)
    }()

    /** The limits along [line], and the roads it drives (with their limit where known). Nil when the server didn't answer. */
    /// [progress] gets the limits so far after each piece, so a long drive's first miles show straight away.
    public static func speedLimits(along line: [LatLng], progress: (@Sendable ([SpeedLimit]) async -> Void)? = nil) async
        -> (limits: [SpeedLimit], ways: [Overpass.LimitWay], entries: [RoundaboutEntry])? {
        guard line.count >= 2 else { return ([], [], []) }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        // In pieces of about 25 km: the server turns away very long traces, and placing each road on
        // a short piece of the line is quick.
        var merged: [SpeedLimit] = []
        var ways: [Overpass.LimitWay] = []
        var entries: [RoundaboutEntry] = []
        var start = 0.0
        while start < total {
            let end = min(total, start + 25_000)
            let piece = Geo.slice(line, from: start, to: end, cumulative: cum)
            guard let data = await fetch(thin(piece)), let parsed = parse(data) else { return nil }
            // Placed by where each road really lies on the route; scaled by length (the matched
            // roads run a little longer or shorter) only where that doesn't place it.
            let placed = Overpass.speedLimits(parsed.ways, on: piece)
            let scale = parsed.meters > 0 ? (end - start) / parsed.meters : 1
            for m in stride(from: 0.0, to: end - start, by: 25) {
                let kmh = placed.last { $0.startMeters <= m }?.kmh ?? parsed.limits.last { $0.startMeters * scale <= m }?.kmh
                if merged.last.map({ $0.kmh != kmh }) ?? true { merged.append(SpeedLimit(startMeters: start + m, kmh: kmh)) }
            }
            ways += parsed.ways
            entries += parsed.entries
            start = end
            // Unknown past what has been matched so far, not the last limit carried on.
            if start < total { await progress?(merged + [SpeedLimit(startMeters: start, kmh: nil)]) }
        }
        return (merged, ways, entries)
    }

    /** About one point every 15 m is plenty to match on, and keeps the request small. */
    static func thin(_ line: [LatLng]) -> [LatLng] {
        guard var last = line.first else { return [] }
        var out = [last]
        for p in line.dropFirst() where last.distance(to: p) >= 15 {
            out.append(p)
            last = p
        }
        if let end = line.last, out.last != end { out.append(end) }
        return out
    }

    static let limitAttributes = ["edge.speed_limit", "edge.way_id", "edge.names", "edge.length", "edge.begin_shape_index",
                                  "edge.end_shape_index", "edge.lane_count", "edge.roundabout", "shape"]

    private static func fetch(_ shape: [LatLng], attributes: [String] = limitAttributes) async -> Data? {
        let body: [String: Any] = [
            "shape": shape.map { ["lat": $0.lat, "lon": $0.lng] },
            "costing": "auto",
            "shape_match": "map_snap",
            "filters": ["attributes": attributes, "action": "include"],
        ]
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /**
     * A driving line from [from] to [to] through [via], kept off the roads at [avoid] (what you
     * tapped on the route to avoid). Just the line: Kite turns it into turn-by-turn with the open
     * router, as for Google's routes. Nil when there's no other way or the server didn't answer.
     */
    public static func lineAvoiding(from: LatLng, to: LatLng, via: [LatLng] = [], avoid: [LatLng]) async -> [LatLng]? {
        let locations = ([from] + via + [to]).map { ["lat": $0.lat, "lon": $0.lng] }
        let body: [String: Any] = [
            "locations": locations,
            "costing": "auto",
            "exclude_locations": avoid.map { ["lat": $0.lat, "lon": $0.lng] },
            "directions_options": ["units": "kilometers", "narrative": false],
        ]
        var r = URLRequest(url: URL(string: "https://valhalla1.openstreetmap.de/route")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseLine(data)
    }

    static func parseLine(_ data: Data) -> [LatLng]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trip = root["trip"] as? [String: Any], let legs = trip["legs"] as? [[String: Any]], !legs.isEmpty else { return nil }
        var line: [LatLng] = []
        for leg in legs {
            guard let shape = leg["shape"] as? String else { return nil }
            let pts = Geo.decodePolyline(shape, precision: 1e6)
            line += line.isEmpty ? pts : Array(pts.dropFirst())
        }
        return line.count >= 2 ? line : nil
    }

    /**
     * The toll roads a route drives, by name ("M6 Toll", "Dartford Crossing"), from the road map's own
     * toll marks. Empty when there are none; nil when the server didn't answer. For "Avoid tolls": the
     * open router Kite falls back on can't avoid them, and some tolls only the map knows.
     */
    public static func tolls(along line: [LatLng]) async -> [String]? {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var names: [String] = []
        var start = 0.0
        while start < total {
            let end = min(total, start + 25_000)
            guard let data = await fetch(thin(Geo.slice(line, from: start, to: end, cumulative: cum)),
                                         attributes: ["edge.toll", "edge.names", "edge.length"]) else { return nil }
            for n in parseTolls(data) where !names.contains(n) { names.append(n) }
            start = end
        }
        return names
    }

    /** Each run of toll roads in a matcher answer, by its first name (or "A toll road"). */
    static func parseTolls(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edges = root["edges"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        var inToll = false
        var meters = 0.0
        var name: String?
        func close() {
            // A few metres of toll mark at a junction's edge isn't driving the toll road.
            if inToll, meters >= 50 {
                let n = name ?? "A toll road"
                if !out.contains(n) { out.append(n) }
            }
            inToll = false; meters = 0; name = nil
        }
        for e in edges {
            if (e["toll"] as? Bool) == true {
                inToll = true
                meters += ((e["length"] as? NSNumber)?.doubleValue ?? 0) * 1000
                if name == nil { name = (e["names"] as? [String])?.first { !$0.isEmpty } }
            } else {
                close()
            }
        }
        close()
        return out
    }

    /** The road you're on now and its posted limit, matched from your last few hundred metres of GPS. */
    public struct Here: Equatable, Sendable {
        public var road: String?
        public var ref: String?
        public var kmh: Double?
    }

    /**
     * Where you are on the map, for driving without a route: the road under the newest fix of [trace]
     * (oldest first, a few hundred metres of it) and its limit. Nil when the server didn't answer
     * or couldn't place you on a road.
     */
    public static func here(trace: [LatLng]) async -> Here? {
        guard trace.count >= 2,
              let data = await fetch(thin(trace), attributes: ["edge.names", "edge.speed_limit", "edge.length", "edge.road_class"]) else { return nil }
        return parseHere(data, at: trace.last!)
    }

    static func parseHere(_ data: Data, at p: LatLng) -> Here? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = (root["edges"] as? [[String: Any]])?.last else { return nil }
        let names = ((e["names"] as? [String]) ?? []).filter { !$0.isEmpty }
        // A road number ("A33", "M27") and a street name are both in names: the number apart.
        let isRef: (String) -> Bool = { $0.range(of: #"^[ABM]\d{1,4}(\(M\))?$"#, options: .regularExpression) != nil }
        let raw = (e["speed_limit"] as? NSNumber)?.doubleValue
        let kmh = Overpass.britishLimit(raw.flatMap { (1...200).contains($0) ? $0 : nil }, at: p)
        return Here(road: names.first { !isRef($0) }, ref: names.first(where: isRef), kmh: kmh)
    }

    /** Limit changes along the matched roads (meters from their start), the roads themselves, and their length. */
    static func parse(_ data: Data) -> (limits: [SpeedLimit], ways: [Overpass.LimitWay], meters: Double, entries: [RoundaboutEntry])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edges = root["edges"] as? [[String: Any]] else { return nil }
        let shape = (root["shape"] as? String).map { Geo.decodePolyline($0) } ?? []
        var limits: [SpeedLimit] = []
        var ways: [Overpass.LimitWay] = []
        var along = 0.0
        // The last posted limit and the road it was on.
        var carried: (kmh: Double, names: Set<String>)?
        var entries: [RoundaboutEntry] = []
        for (k, e) in edges.enumerated() {
            // The road in to a roundabout: its lanes where it meets the circle.
            if (e["roundabout"] as? Bool) != true, k + 1 < edges.count, (edges[k + 1]["roundabout"] as? Bool) == true,
               let lanes = (e["lane_count"] as? NSNumber)?.intValue, (1...6).contains(lanes),
               let b = (e["end_shape_index"] as? NSNumber)?.intValue, shape.indices.contains(b) {
                entries.append(RoundaboutEntry(at: shape[b], lanes: lanes))
            }
            // 0 is "not known"; Valhalla marks a variable or no limit with 255.
            let raw = (e["speed_limit"] as? NSNumber)?.doubleValue
            let mapped = Overpass.britishLimit(raw.flatMap { (1...200).contains($0) ? $0 : nil }, at: shape.first ?? LatLng(0, 0))
            let names = Set((e["names"] as? [String]) ?? [])
            // A limit holds until a sign says otherwise: further along the same road with no limit
            // mapped, the last one still applies (Normandy Way, Marchwood: 40 mph mapped by the
            // roundabout, then a mile with none, 2026-10-27). A different road starts unknown.
            if let m = mapped, !names.isEmpty { carried = (m, names) }
            else if mapped == nil, let c = carried, names.isDisjoint(with: c.names) { carried = nil }
            else if mapped != nil { carried = nil }
            let kmh = mapped ?? carried?.kmh
            if limits.last.map({ $0.kmh != kmh }) ?? true { limits.append(SpeedLimit(startMeters: along, kmh: kmh)) }
            along += ((e["length"] as? NSNumber)?.doubleValue ?? 0) * 1000
            if let a = (e["begin_shape_index"] as? NSNumber)?.intValue, let b = (e["end_shape_index"] as? NSNumber)?.intValue,
               a >= 0, b < shape.count, b > a {
                // The roads keep only what's mapped (they're remembered for later drives); the carried limit is in [limits].
                ways.append(Overpass.LimitWay(id: (e["way_id"] as? NSNumber)?.int64Value ?? 0, kmh: mapped, line: Array(shape[a...b])))
            }
        }
        return (limits, ways, along, entries)
    }
}

/** Where the route meets a roundabout, and how many lanes the road in has there (from the road matcher). */
public struct RoundaboutEntry: Hashable, Sendable {
    public var at: LatLng
    public var lanes: Int
}
