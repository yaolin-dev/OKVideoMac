import Foundation

public struct XMLTVParser {
    private let defaultTimeZone: TimeZone?

    public init(defaultTimeZone: TimeZone? = nil) {
        self.defaultTimeZone = defaultTimeZone
    }

    public func parse(_ data: Data) throws -> XMLTVGuide {
        let expanded = try Gzip.decompress(data)
        guard expanded.count <= 64 * 1_024 * 1_024 else {
            throw AppError.live("XMLTV 超过 64 MiB 限制")
        }
        let delegate = XMLTVDelegate(defaultTimeZone: defaultTimeZone)
        let parser = XMLParser(data: expanded)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.live(
                "XMLTV 解析失败：\(parser.parserError?.localizedDescription ?? "未知错误")"
            )
        }
        return XMLTVGuide(channels: delegate.channels, programmes: delegate.programmes)
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    private(set) var channels: [EPGChannel] = []
    private(set) var programmes: [EPGProgramme] = []

    private let defaultTimeZone: TimeZone?
    private var currentChannelID: String?
    private var currentProgramme: ProgrammeBuilder?
    private var currentElement = ""
    private var text = ""

    init(defaultTimeZone: TimeZone?) {
        self.defaultTimeZone = defaultTimeZone
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        text = ""
        if currentElement == "channel" {
            currentChannelID = attributeDict["id"]
        } else if currentElement == "programme" {
            currentProgramme = ProgrammeBuilder(
                channelID: attributeDict["channel"] ?? "",
                start: parseDate(attributeDict["start"] ?? ""),
                end: parseDate(attributeDict["stop"] ?? ""),
                title: ""
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "display-name", let id = currentChannelID, !value.isEmpty {
            if !channels.contains(where: { $0.id == id }) {
                channels.append(EPGChannel(id: id, displayName: value))
            }
        } else if element == "title", currentProgramme != nil, !value.isEmpty {
            currentProgramme?.title = value
        } else if element == "channel" {
            currentChannelID = nil
        } else if element == "programme", let programme = currentProgramme {
            if !programme.channelID.isEmpty,
               !programme.title.isEmpty,
               let start = programme.start,
               let end = programme.end,
               start < end {
                programmes.append(
                    EPGProgramme(
                        channelID: programme.channelID,
                        title: programme.title,
                        start: start,
                        end: end
                    )
                )
            }
            currentProgramme = nil
        }
        currentElement = ""
        text = ""
    }

    private func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        for format in ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = defaultTimeZone ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }
}

private struct ProgrammeBuilder {
    var channelID: String
    var start: Date?
    var end: Date?
    var title: String
}
