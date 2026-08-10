import Foundation

public struct FongMiConfiguration: Codable, Equatable, Sendable {
    public var spider: String?
    public var wallpaper: String?
    public var logo: String?
    public var notice: String?
    public var sites: [SiteConfiguration]
    public var parses: [ParseConfiguration]
    public var lives: [LiveConfiguration]
    public var doh: [DohConfiguration]
    public var proxy: [ProxyConfiguration]
    public var rules: [NetworkRuleConfiguration]
    public var headers: [HeaderRuleConfiguration]
    public var hosts: [String]
    public var flags: [String]
    public var ads: [String]
    public var danmaku: String?
    public var extra: [String: JSONValue]

    public init(
        spider: String? = nil,
        wallpaper: String? = nil,
        logo: String? = nil,
        notice: String? = nil,
        sites: [SiteConfiguration] = [],
        parses: [ParseConfiguration] = [],
        lives: [LiveConfiguration] = [],
        doh: [DohConfiguration] = [],
        proxy: [ProxyConfiguration] = [],
        rules: [NetworkRuleConfiguration] = [],
        headers: [HeaderRuleConfiguration] = [],
        hosts: [String] = [],
        flags: [String] = [],
        ads: [String] = [],
        danmaku: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.spider = spider
        self.wallpaper = wallpaper
        self.logo = logo
        self.notice = notice
        self.sites = sites
        self.parses = parses
        self.lives = lives
        self.doh = doh
        self.proxy = proxy
        self.rules = rules
        self.headers = headers
        self.hosts = hosts
        self.flags = flags
        self.ads = ads
        self.danmaku = danmaku
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        spider = object.removeString("spider")
        wallpaper = object.removeString("wallpaper")
        logo = object.removeString("logo")
        notice = object.removeString("notice")
        sites = try object.removeDecoded("sites", default: [])
        parses = try object.removeDecoded("parses", default: [])
        lives = try object.removeDecoded("lives", default: [])
        doh = try object.removeDecoded("doh", default: [])
        proxy = try object.removeDecoded("proxy", default: [])
        rules = try object.removeDecoded("rules", default: [])
        headers = try object.removeDecoded("headers", default: [])
        hosts = object.removeStringArray("hosts")
        flags = object.removeStringArray("flags")
        ads = object.removeStringArray("ads")
        danmaku = object.removeString("danmaku")
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object.set("spider", spider)
        object.set("wallpaper", wallpaper)
        object.set("logo", logo)
        object.set("notice", notice)
        try object.setEncoded("sites", sites, omitWhenEmpty: true)
        try object.setEncoded("parses", parses, omitWhenEmpty: true)
        try object.setEncoded("lives", lives, omitWhenEmpty: true)
        try object.setEncoded("doh", doh, omitWhenEmpty: true)
        try object.setEncoded("proxy", proxy, omitWhenEmpty: true)
        try object.setEncoded("rules", rules, omitWhenEmpty: true)
        try object.setEncoded("headers", headers, omitWhenEmpty: true)
        object.set("hosts", hosts)
        object.set("flags", flags)
        object.set("ads", ads)
        object.set("danmaku", danmaku)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct SiteConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }

    public var key: String
    public var name: String
    public var type: Int
    public var api: String
    public var ext: JSONValue?
    public var jar: String?
    public var click: String?
    public var playURL: String?
    public var hide: Int
    public var indexs: Int
    public var timeout: Int?
    public var searchable: Int
    public var changeable: Int
    public var quickSearch: Int
    public var categories: [String]
    public var header: [String: String]
    public var style: StyleConfiguration?
    public var extra: [String: JSONValue]

    public init(
        key: String,
        name: String,
        type: Int,
        api: String,
        ext: JSONValue? = nil,
        jar: String? = nil,
        click: String? = nil,
        playURL: String? = nil,
        hide: Int = 0,
        indexs: Int = 0,
        timeout: Int? = nil,
        searchable: Int = 1,
        changeable: Int = 1,
        quickSearch: Int = 1,
        categories: [String] = [],
        header: [String: String] = [:],
        style: StyleConfiguration? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.ext = ext
        self.jar = jar
        self.click = click
        self.playURL = playURL
        self.hide = hide
        self.indexs = indexs
        self.timeout = timeout
        self.searchable = searchable
        self.changeable = changeable
        self.quickSearch = quickSearch
        self.categories = categories
        self.header = header
        self.style = style
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        key = object.removeString("key") ?? ""
        name = object.removeString("name") ?? ""
        type = object.removeInt("type") ?? 0
        api = object.removeString("api") ?? ""
        ext = object.removeValue("ext")
        jar = object.removeString("jar")
        click = object.removeString("click")
        playURL = object.removeString("playUrl")
        hide = object.removeInt("hide") ?? 0
        indexs = object.removeInt("indexs") ?? 0
        timeout = object.removeInt("timeout")
        searchable = object.removeInt("searchable") ?? 1
        changeable = object.removeInt("changeable") ?? 1
        quickSearch = object.removeInt("quickSearch") ?? 1
        categories = object.removeStringArray("categories")
        header = object.removeStringDictionary("header")
        style = try object.removeDecoded("style", default: nil)
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["key"] = .string(key)
        object["name"] = .string(name)
        object["type"] = .integer(Int64(type))
        object["api"] = .string(api)
        object.set("ext", ext)
        object.set("jar", jar)
        object.set("click", click)
        object.set("playUrl", playURL)
        object["hide"] = .integer(Int64(hide))
        object["indexs"] = .integer(Int64(indexs))
        object.set("timeout", timeout)
        object["searchable"] = .integer(Int64(searchable))
        object["changeable"] = .integer(Int64(changeable))
        object["quickSearch"] = .integer(Int64(quickSearch))
        object.set("categories", categories)
        object.set("header", header)
        try object.setEncoded("style", style)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct ParseConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }

    public var name: String
    public var type: Int
    public var url: String
    public var ext: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        name: String,
        type: Int,
        url: String,
        ext: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
        self.extra = extra
    }

    public var flags: [String] {
        ext?.objectValue?["flag"]?.stringArrayValue ?? []
    }

    public var headers: [String: String] {
        ext?.objectValue?["header"]?.stringDictionaryValue ?? [:]
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        name = object.removeString("name") ?? ""
        type = object.removeInt("type") ?? 0
        url = object.removeString("url") ?? ""
        ext = object.removeValue("ext")
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["name"] = .string(name)
        object["type"] = .integer(Int64(type))
        object["url"] = .string(url)
        object.set("ext", ext)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct LiveConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }

    public var name: String
    public var url: String?
    public var api: String?
    public var ext: JSONValue?
    public var jar: String?
    public var click: String?
    public var logo: String?
    public var epg: String?
    public var userAgent: String?
    public var origin: String?
    public var referer: String?
    public var timeZone: String?
    public var timeout: Int?
    public var header: [String: String]
    public var groups: [LiveGroupConfiguration]
    public var boot: Bool
    public var pass: Bool
    public var extra: [String: JSONValue]

    public init(
        name: String,
        url: String? = nil,
        api: String? = nil,
        ext: JSONValue? = nil,
        jar: String? = nil,
        click: String? = nil,
        logo: String? = nil,
        epg: String? = nil,
        userAgent: String? = nil,
        origin: String? = nil,
        referer: String? = nil,
        timeZone: String? = nil,
        timeout: Int? = nil,
        header: [String: String] = [:],
        groups: [LiveGroupConfiguration] = [],
        boot: Bool = false,
        pass: Bool = false,
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.url = url
        self.api = api
        self.ext = ext
        self.jar = jar
        self.click = click
        self.logo = logo
        self.epg = epg
        self.userAgent = userAgent
        self.origin = origin
        self.referer = referer
        self.timeZone = timeZone
        self.timeout = timeout
        self.header = header
        self.groups = groups
        self.boot = boot
        self.pass = pass
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        name = object.removeString("name") ?? ""
        url = object.removeString("url")
        api = object.removeString("api")
        ext = object.removeValue("ext")
        jar = object.removeString("jar")
        click = object.removeString("click")
        logo = object.removeString("logo")
        epg = object.removeString("epg")
        userAgent = object.removeString("ua")
        origin = object.removeString("origin")
        referer = object.removeString("referer")
        timeZone = object.removeString("timeZone")
        timeout = object.removeInt("timeout")
        header = object.removeStringDictionary("header")
        groups = try object.removeDecoded("groups", default: [])
        boot = object.removeBool("boot") ?? false
        pass = object.removeBool("pass") ?? false
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["name"] = .string(name)
        object.set("url", url)
        object.set("api", api)
        object.set("ext", ext)
        object.set("jar", jar)
        object.set("click", click)
        object.set("logo", logo)
        object.set("epg", epg)
        object.set("ua", userAgent)
        object.set("origin", origin)
        object.set("referer", referer)
        object.set("timeZone", timeZone)
        object.set("timeout", timeout)
        object.set("header", header)
        try object.setEncoded("groups", groups, omitWhenEmpty: true)
        object["boot"] = .bool(boot)
        object["pass"] = .bool(pass)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct LiveGroupConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var pass: String?
    public var channels: [LiveChannelConfiguration]

    enum CodingKeys: String, CodingKey {
        case name
        case pass
        case channels = "channel"
    }

    public init(name: String, pass: String? = nil, channels: [LiveChannelConfiguration] = []) {
        self.name = name
        self.pass = pass
        self.channels = channels
    }
}

public struct LiveChannelConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var urls: [String]
    public var number: String?
    public var logo: String?
    public var epg: String?
    public var userAgent: String?
    public var click: String?
    public var format: String?
    public var origin: String?
    public var referer: String?
    public var tvgID: String?
    public var tvgName: String?
    public var header: [String: String]
    public var parse: Int?

    enum CodingKeys: String, CodingKey {
        case name, urls, number, logo, epg, click, format, origin, referer, header, parse
        case userAgent = "ua"
        case tvgID = "tvgId"
        case tvgName
    }

    public init(
        name: String,
        urls: [String],
        number: String? = nil,
        logo: String? = nil,
        epg: String? = nil,
        userAgent: String? = nil,
        click: String? = nil,
        format: String? = nil,
        origin: String? = nil,
        referer: String? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil,
        header: [String: String] = [:],
        parse: Int? = nil
    ) {
        self.name = name
        self.urls = urls
        self.number = number
        self.logo = logo
        self.epg = epg
        self.userAgent = userAgent
        self.click = click
        self.format = format
        self.origin = origin
        self.referer = referer
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.header = header
        self.parse = parse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        number = try container.decodeIfPresent(String.self, forKey: .number)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        epg = try container.decodeIfPresent(String.self, forKey: .epg)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        click = try container.decodeIfPresent(String.self, forKey: .click)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        referer = try container.decodeIfPresent(String.self, forKey: .referer)
        tvgID = try container.decodeIfPresent(String.self, forKey: .tvgID)
        tvgName = try container.decodeIfPresent(String.self, forKey: .tvgName)
        header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        parse = try container.decodeIfPresent(Int.self, forKey: .parse)
    }
}

public struct StyleConfiguration: Codable, Equatable, Sendable {
    public var type: String?
    public var ratio: Double?

    public init(type: String? = nil, ratio: Double? = nil) {
        self.type = type
        self.ratio = ratio
    }
}

public struct DohConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var ips: [String]
    public var extra: [String: JSONValue]

    public init(name: String, url: String, ips: [String] = [], extra: [String: JSONValue] = [:]) {
        self.name = name
        self.url = url
        self.ips = ips
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        name = object.removeString("name") ?? ""
        url = object.removeString("url") ?? ""
        ips = object.removeStringArray("ips")
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["name"] = .string(name)
        object["url"] = .string(url)
        object.set("ips", ips)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct ProxyConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var urls: [String]
    public var hosts: [String]
    public var extra: [String: JSONValue]

    public init(
        name: String,
        urls: [String],
        hosts: [String] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.urls = urls
        self.hosts = hosts
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        name = object.removeString("name") ?? ""
        urls = object.removeStringArray("urls")
        if urls.isEmpty, let legacyURL = object.removeString("url") {
            urls = [legacyURL]
        }
        hosts = object.removeStringArray("hosts")
        if hosts.isEmpty {
            hosts = object.removeStringArray("host")
        }
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["name"] = .string(name)
        object.set("urls", urls)
        object.set("hosts", hosts)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct NetworkRuleConfiguration: Codable, Equatable, Sendable {
    public var name: String?
    public var hosts: [String]
    public var regex: [String]
    public var script: [String]
    public var exclude: [String]
    public var extra: [String: JSONValue]

    public init(
        name: String? = nil,
        hosts: [String] = [],
        regex: [String] = [],
        script: [String] = [],
        exclude: [String] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.script = script
        self.exclude = exclude
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        name = object.removeString("name")
        hosts = object.removeStringArray("hosts")
        if hosts.isEmpty {
            hosts = object.removeStringArray("host")
        }
        regex = object.removeStringArray("regex")
        script = object.removeStringArray("script")
        exclude = object.removeStringArray("exclude")
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object.set("name", name)
        object.set("hosts", hosts)
        object.set("regex", regex)
        object.set("script", script)
        object.set("exclude", exclude)
        try encodeJSONObject(object, to: encoder)
    }
}

public struct HeaderRuleConfiguration: Codable, Equatable, Sendable {
    public var host: String
    public var header: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        host: String,
        header: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.host = host
        self.header = header
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        var object = try decodeJSONObject(from: decoder)
        host = object.removeString("host") ?? ""
        header = object.removeValue("header")
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["host"] = .string(host)
        object.set("header", header)
        try encodeJSONObject(object, to: encoder)
    }

    public var headerDictionary: [String: String] {
        header?.stringDictionaryValue ?? [:]
    }
}

private func decodeJSONObject(from decoder: Decoder) throws -> [String: JSONValue] {
    let container = try decoder.singleValueContainer()
    return try container.decode([String: JSONValue].self)
}

private func encodeJSONObject(_ object: [String: JSONValue], to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(object)
}

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value):
            guard value.rounded() == value else { return nil }
            return Int(exactly: value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    var stringDictionaryValue: [String: String]? {
        guard case .object(let values) = self else { return nil }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            value.stringValue.map { (key, $0) }
        })
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func removeValue(_ key: String) -> JSONValue? {
        removeValue(forKey: key)
    }

    mutating func removeString(_ key: String) -> String? {
        removeValue(forKey: key)?.stringValue
    }

    mutating func removeInt(_ key: String) -> Int? {
        removeValue(forKey: key)?.intValue
    }

    mutating func removeBool(_ key: String) -> Bool? {
        removeValue(forKey: key)?.boolValue
    }

    mutating func removeStringArray(_ key: String) -> [String] {
        removeValue(forKey: key)?.stringArrayValue ?? []
    }

    mutating func removeStringDictionary(_ key: String) -> [String: String] {
        removeValue(forKey: key)?.stringDictionaryValue ?? [:]
    }

    mutating func removeDecoded<T: Decodable>(_ key: String, default defaultValue: T) throws -> T {
        guard let value = removeValue(forKey: key) else { return defaultValue }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value {
            self[key] = value
        }
    }

    mutating func set(_ key: String, _ value: String?) {
        if let value {
            self[key] = .string(value)
        }
    }

    mutating func set(_ key: String, _ value: Int?) {
        if let value {
            self[key] = .integer(Int64(value))
        }
    }

    mutating func set(_ key: String, _ value: [String]) {
        if !value.isEmpty {
            self[key] = .array(value.map(JSONValue.string))
        }
    }

    mutating func set(_ key: String, _ value: [String: String]) {
        if !value.isEmpty {
            self[key] = .object(value.mapValues(JSONValue.string))
        }
    }

    mutating func setEncoded<T: Encodable>(
        _ key: String,
        _ value: T?,
        omitWhenEmpty: Bool = false
    ) throws {
        guard let value else { return }
        let data = try JSONEncoder().encode(value)
        let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
        if omitWhenEmpty {
            switch jsonValue {
            case .array(let items) where items.isEmpty:
                return
            case .object(let object) where object.isEmpty:
                return
            default:
                break
            }
        }
        self[key] = jsonValue
    }
}
