import XCTest
@testable import OKVideoCore

final class SpiderEngineTests: XCTestCase {
    func testMethodMappingAndArguments() async throws {
        let runtime = FixtureSpiderRuntime(siteKey: "fixture")
        let site = SiteConfiguration(
            key: "fixture",
            name: "Fixture",
            type: 3,
            api: "./fixture.js",
            ext: .object(["mode": .string("test")])
        )
        let engine = SpiderEngine(site: site, runtime: runtime)
        try await engine.initialize(script: "export default {}", sourceURL: nil)
        _ = try await engine.category(
            id: "movie",
            page: 2,
            filter: true,
            extend: ["area": "fixture"]
        )
        _ = try await engine.play(flag: "fixture", id: "episode", vipFlags: ["fixture"])

        let invocations = await runtime.invocations
        XCTAssertEqual(invocations.map(\.method), [.initialize, .category, .play])
        XCTAssertEqual(
            invocations[1].arguments,
            [
                .string("movie"),
                .string("2"),
                .bool(true),
                .object(["area": .string("fixture")])
            ]
        )
    }

    func testCallBeforeInitializationFails() async {
        let site = SiteConfiguration(
            key: "fixture",
            name: "Fixture",
            type: 3,
            api: "./fixture.js"
        )
        let engine = SpiderEngine(site: site, runtime: FixtureSpiderRuntime(siteKey: "fixture"))
        do {
            _ = try await engine.home()
            XCTFail("Expected initialization error")
        } catch {
            XCTAssertEqual(
                error as? AppError,
                .spider("站点 Fixture 的 Spider 尚未初始化")
            )
        }
    }

    func testSpiderResponseMapsToDomainModels() throws {
        let site = SiteConfiguration(
            key: "fixture",
            name: "Fixture",
            type: 3,
            api: "https://example.invalid/spider.js"
        )
        let value = JSONValue.object([
            "class": .array([
                .object([
                    "type_id": .string("movie"),
                    "type_name": .string("Movies")
                ])
            ]),
            "list": .array([
                .object([
                    "vod_id": .string("1"),
                    "vod_name": .string("Fixture Movie"),
                    "vod_year": .string("2026")
                ])
            ])
        ])

        let home = try SpiderResponseMapper.home(
            value,
            homeVideoValue: nil,
            site: site,
            baseURL: nil
        )
        XCTAssertEqual(home.categories.first?.name, "Movies")
        XCTAssertEqual(home.recommendations.first?.title, "Fixture Movie")
    }
}

private actor InvocationStorage {
    var values: [SpiderInvocation] = []

    func append(_ value: SpiderInvocation) {
        values.append(value)
    }
}

private final class FixtureSpiderRuntime: SpiderRuntime {
    let siteKey: String
    let limits: SpiderRuntimeLimits = .standard
    private let storage = InvocationStorage()

    init(siteKey: String) {
        self.siteKey = siteKey
    }

    var invocations: [SpiderInvocation] {
        get async { await storage.values }
    }

    func load(script: String, sourceURL: URL?) async throws {
        XCTAssertFalse(script.isEmpty)
    }

    func invoke(_ invocation: SpiderInvocation) async throws -> JSONValue {
        await storage.append(invocation)
        return .object([:])
    }

    func destroy() async {}
}
