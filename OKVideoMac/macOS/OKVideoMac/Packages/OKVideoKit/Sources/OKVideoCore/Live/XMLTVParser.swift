import Foundation

public struct XMLTVParser {
    private let defaultTimeZone: TimeZone?

    public init(defaultTimeZone: TimeZone? = nil) {
        self.defaultTimeZone = defaultTimeZone
    }

    public func parse(_ data: Data) throws -> XMLTVGuide {
        try Task.checkCancellation()
        let expanded = try Gzip.decompress(data)
        guard expanded.count <= 64 * 1_024 * 1_024 else {
            throw AppError.live("XMLTV 超过 64 MiB 限制")
        }
        var programmes: [EPGProgramme] = []
        let parser = XMLParser(data: expanded)
        let delegate = try parseXML(parser) { programme, _ in programmes.append(programme) }
        return XMLTVGuide(channels: delegate.channels, programmes: programmes)
    }

    // Both entry points use the same element/date/alias rules. The legacy API
    // deliberately remains a collecting adapter; only the explicit SPI streams.
    func parseXML(_ parser: XMLParser, boundsDateTemporaries: Bool = false,
                  onChannel: ((EPGChannel) throws -> Void)? = nil,
                  checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() },
                  onProgramme: @escaping (EPGProgramme, Int) throws -> Void) throws -> XMLTVDelegate {
        let delegate = XMLTVDelegate(defaultTimeZone: defaultTimeZone,
                                     boundsDateTemporaries: boundsDateTemporaries,
                                     onChannel: onChannel, checkCancellation: checkCancellation,
                                     onProgramme: onProgramme)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let success = parser.parse()
        try Task.checkCancellation()
        try checkCancellation()
        if let failure = delegate.failure { throw failure }
        guard success, delegate.hasTVRoot,
              delegate.programmeElementCount == 0 || delegate.validProgrammeCount > 0 else {
            if onChannel != nil { throw XMLTVStreamError.invalidDocument }
            throw AppError.live(
                "XMLTV 解析失败：\(parser.parserError?.localizedDescription ?? "未知错误")"
            )
        }
        return delegate
    }
}

final class XMLTVDelegate: NSObject, XMLParserDelegate {
    private(set) var channels: [EPGChannel] = []
    private(set) var validProgrammeCount = 0
    private(set) var failure: Error?
    private let onProgramme: (EPGProgramme, Int) throws -> Void
    private let onChannel: ((EPGChannel) throws -> Void)?
    private let checkCancellation: () throws -> Void
    private var textBytes = 0
    private let boundsDateTemporaries: Bool
    private(set) var hasTVRoot = false
    private(set) var programmeElementCount = 0
    private var sawRoot = false
    private var channelIndices: [String: Int] = [:]
    private var displayNameCount = 0

    private let defaultTimeZone: TimeZone?
    private let dateFormatters: [DateFormatter]
    // A guide repeats the same broadcast times across many channels. Keep this
    // cache local to one parse (and its time zone), with bounded keys and count.
    private var dateCache: [String: Date] = [:]
    private var dateCacheKeys: [String] = []
    private var dateCacheCursor = 0
    static let maximumCachedDates = 4_096
    var cachedDateCount: Int { dateCache.count }
    private var currentChannelID: String?
    private var currentProgramme: ProgrammeBuilder?
    private var currentElement = ""
    private var text = ""

    init(defaultTimeZone: TimeZone?, boundsDateTemporaries: Bool,
         onChannel: ((EPGChannel) throws -> Void)?, checkCancellation: @escaping () throws -> Void,
         onProgramme: @escaping (EPGProgramme, Int) throws -> Void) {
        self.defaultTimeZone = defaultTimeZone
        self.boundsDateTemporaries = boundsDateTemporaries
        self.onProgramme = onProgramme
        self.onChannel = onChannel
        self.checkCancellation = checkCancellation
        dateFormatters = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = defaultTimeZone ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if Task.isCancelled { parser.abortParsing(); return }
        do {
            try checkCancellation()
            if onChannel != nil, attributeDict.values.contains(where: { $0.utf8.count > 1_048_512 }) {
                throw XMLTVStreamError.oversizedRecord
            }
        } catch { failure = error; parser.abortParsing(); return }
        if !sawRoot {
            sawRoot = true
            hasTVRoot = elementName.lowercased() == "tv"
            if !hasTVRoot { parser.abortParsing(); return }
        }
        currentElement = elementName.lowercased()
        text = ""
        textBytes = 0
        if currentElement == "channel" {
            currentChannelID = attributeDict["id"]
        } else if currentElement == "programme" {
            programmeElementCount += 1
            if programmeElementCount > 200_000 { parser.abortParsing(); return }
            currentProgramme = ProgrammeBuilder(
                channelID: attributeDict["channel"] ?? "",
                start: parseDate(attributeDict["start"] ?? ""),
                end: parseDate(attributeDict["stop"] ?? ""),
                title: ""
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if onChannel != nil {
            do {
                try checkCancellation()
                guard currentElement == "title" || currentElement == "display-name" else { return }
                let bytes = string.utf8.count
                guard bytes <= 1_048_512 - textBytes else { throw XMLTVStreamError.oversizedRecord }
                textBytes += bytes
            } catch { failure = error; parser.abortParsing(); return }
        }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        do { try checkCancellation() } catch { failure = error; parser.abortParsing(); return }
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "display-name", let id = currentChannelID, !value.isEmpty {
            displayNameCount += 1
            if displayNameCount > 200_000 { parser.abortParsing(); return }
            if let onChannel {
                do { try onChannel(EPGChannel(id: id, displayName: value)) }
                catch { failure = error; parser.abortParsing(); return }
            } else if let index = channelIndices[id] {
                if channels[index].displayName != value,
                   !(channels[index].aliases ?? []).contains(value) {
                    channels[index].aliases = (channels[index].aliases ?? []) + [value]
                }
            } else {
                channelIndices[id] = channels.count
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
                validProgrammeCount += 1
                do {
                    try onProgramme(EPGProgramme(
                        channelID: programme.channelID,
                        title: programme.title,
                        start: start,
                        end: end
                    ), programmeElementCount - 1)
                } catch {
                    failure = error
                    parser.abortParsing()
                }
            }
            currentProgramme = nil
        }
        currentElement = ""
        text = ""
        textBytes = 0
    }

    private func parseDate(_ value: String) -> Date? {
        // Streaming calls cannot accumulate Foundation autoreleased temporaries
        // until a whole document finishes. Same formatters/rules, scoped lifetime.
        // Keep the legacy collecting entry point's lifetime behavior unchanged.
        if boundsDateTemporaries { return autoreleasepool { parseDateValue(value) } }
        return parseDateValue(value)
    }

    private func parseDateValue(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let cached = dateCache[normalized] { return cached }
        for formatter in dateFormatters {
            if let date = formatter.date(from: normalized) {
                if normalized.utf8.count <= 128 {
                    if dateCacheKeys.count < Self.maximumCachedDates {
                        dateCacheKeys.append(normalized)
                    } else {
                        dateCache.removeValue(forKey: dateCacheKeys[dateCacheCursor])
                        dateCacheKeys[dateCacheCursor] = normalized
                        dateCacheCursor = (dateCacheCursor + 1) % Self.maximumCachedDates
                    }
                    dateCache[normalized] = date
                }
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
