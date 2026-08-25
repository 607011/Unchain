import Foundation
import UniformTypeIdentifiers

struct GPXTrackpoint {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double
}

enum GPXParseError: LocalizedError {
    case unreadable
    case noTrackpoints
    case missingElevation

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The file couldn't be parsed as GPX."
        case .noTrackpoints:
            return "No track points found in this GPX file."
        case .missingElevation:
            return "This GPX track is missing elevation data (<ele>) for at least one point. Unchain needs elevation in the file itself to derive a grade profile – it doesn't look elevation up online."
        }
    }
}

/// Parses `<trkpt>` elements out of a GPX track – latitude/longitude/
/// elevation only, in file order. Deliberately offline: if any point is
/// missing `<ele>`, the whole file is rejected rather than falling back to
/// an elevation lookup service, so this never needs network access.
enum GPXParser {
    static var supportedContentTypes: [UTType] {
        [UTType(filenameExtension: "gpx")].compactMap { $0 }
    }

    static func parse(data: Data) -> Result<[GPXTrackpoint], Error> {
        let delegate = TrackpointCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return .failure(delegate.parseError ?? GPXParseError.unreadable)
        }
        if delegate.sawPointMissingElevation {
            return .failure(GPXParseError.missingElevation)
        }
        guard !delegate.points.isEmpty else {
            return .failure(GPXParseError.noTrackpoints)
        }
        return .success(delegate.points)
    }

    private final class TrackpointCollector: NSObject, XMLParserDelegate {
        var points: [GPXTrackpoint] = []
        var sawPointMissingElevation = false
        var parseError: Error?

        private var isInsideTrkpt = false
        private var isInsideEle = false
        private var currentLatitude: Double?
        private var currentLongitude: Double?
        private var currentElevationText: String?
        private var eleBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            switch elementName {
            case "trkpt":
                isInsideTrkpt = true
                currentLatitude = attributeDict["lat"].flatMap(Double.init)
                currentLongitude = attributeDict["lon"].flatMap(Double.init)
                currentElevationText = nil
            case "ele":
                if isInsideTrkpt {
                    isInsideEle = true
                    eleBuffer = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideEle {
                eleBuffer += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "ele":
                if isInsideEle {
                    currentElevationText = eleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    isInsideEle = false
                }
            case "trkpt":
                defer { isInsideTrkpt = false }
                // A point without valid lat/lon is malformed rather than
                // "missing elevation" – skip it silently instead of rejecting
                // the whole file over it.
                guard let lat = currentLatitude, let lon = currentLongitude else { return }
                guard let text = currentElevationText, let elevation = Double(text) else {
                    sawPointMissingElevation = true
                    return
                }
                points.append(GPXTrackpoint(latitude: lat, longitude: lon, elevationMeters: elevation))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = parseError
        }
    }
}
