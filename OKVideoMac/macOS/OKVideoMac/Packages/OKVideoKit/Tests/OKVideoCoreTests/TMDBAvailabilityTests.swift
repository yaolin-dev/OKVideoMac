import XCTest
@testable import OKVideoCore

final class TMDBAvailabilityTests: XCTestCase {
    func testLiveBothLinkProbesUsingApplicationClient() async throws {
        guard ProcessInfo.processInfo.environment["OKVIDEO_TMDB_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in live link probes") }
        let health = TMDBAvailability()
        await TMDBLinkProber(availability: health).warm()
        for _ in 0..<100 {
            let state = await health.snapshot()
            if !state.metadata.checking && !state.images.checking { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = await health.snapshot()
        print("Live links: metadata=\(state.metadata.state.rawValue) images=\(state.images.state.rawValue)")
        XCTAssertTrue(state.ready, "Actual metadata and decodable image GET must both succeed")
    }

    func testBothLinksRequiredAndResourceMissingIsNotOutage() async {
        let health = TMDBAvailability()
        await health.finish(health.ticket(.metadata), outcome: .success)
        var snapshot = await health.snapshot()
        XCTAssertFalse(snapshot.ready); XCTAssertFalse(snapshot.blocked)
        await health.finish(health.ticket(.images), outcome: .missing)
        snapshot = await health.snapshot(); XCTAssertEqual(snapshot.images.state, .unknown)
        await health.finish(health.ticket(.images), outcome: .success)
        snapshot = await health.snapshot(); XCTAssertTrue(snapshot.ready)
        await health.finish(health.ticket(.images), outcome: .missing)
        snapshot = await health.snapshot(); XCTAssertTrue(snapshot.ready)
        await health.finish(health.ticket(.images), outcome: .failure(.network))
        snapshot = await health.snapshot(); XCTAssertTrue(snapshot.blocked); XCTAssertEqual(snapshot.metadata.state, .available)
    }
    func testOldNetworkAndOlderProbeCannotOverrideNewFailure() async {
        let health = TMDBAvailability()
        let oldNetwork = await health.ticket(.metadata)
        await health.networkChanged()
        await health.finish(oldNetwork, outcome: .success)
        var snapshot = await health.snapshot(); XCTAssertEqual(snapshot.metadata.state, .unknown)
        let older = await health.ticket(.metadata), newer = await health.ticket(.metadata)
        await health.finish(newer, outcome: .failure(.server))
        await health.finish(older, outcome: .success)
        snapshot = await health.snapshot(); XCTAssertTrue(snapshot.blocked)
    }
    func testExpiryCancellationAndCooldownAreSeparate() async {
        let clock = TMDBTestClock(), health = TMDBAvailability(now: { clock.now })
        await health.finish(health.ticket(.metadata), outcome: .success)
        clock.advance(181)
        var snapshot = await health.snapshot(); XCTAssertEqual(snapshot.metadata.state, .unknown)
        await health.finish(health.ticket(.metadata), outcome: .cancelled)
        snapshot = await health.snapshot(); XCTAssertNil(snapshot.metadata.failure)
        for seconds in [30.0, 60, 120, 240, 300, 300] {
            await health.finish(health.ticket(.metadata), outcome: .failure(.network))
            snapshot = await health.snapshot(); XCTAssertEqual(snapshot.metadata.retryAt, clock.now + seconds)
            clock.advance(seconds + 1)
            snapshot = await health.snapshot(); XCTAssertEqual(snapshot.metadata.state, .unknown)
        }
    }
    func testProbeCoalescingPreservesUnexpiredSuccess() async throws {
        let health = TMDBAvailability(), count = ProbeCounter(), gate = ProbeGate()
        let started = expectation(description: "Probe operation started")
        let checking = expectation(description: "Checking state published")
        let completed = expectation(description: "Probe completion published")
        await health.finish(health.ticket(.metadata), outcome: .success)
        let updates = await health.updates()
        let observer = Task {
            var sawChecking = false
            for await state in updates {
                if state.metadata.checking && !sawChecking {
                    sawChecking = true
                    checking.fulfill()
                } else if sawChecking && !state.metadata.checking {
                    completed.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }
        for _ in 0..<20 {
            await health.probe(.metadata, force: true) {
                await count.increment()
                started.fulfill()
                await gate.wait()
                return .success
            }
        }
        await fulfillment(of: [started, checking], timeout: 5)
        let during = await health.snapshot()
        XCTAssertTrue(during.metadata.checking); XCTAssertEqual(during.metadata.state, .available)
        await gate.open()
        await fulfillment(of: [completed], timeout: 5)
        let calls = await count.value, after = await health.snapshot()
        XCTAssertEqual(calls, 1); XCTAssertFalse(after.metadata.checking)
        XCTAssertEqual(after.metadata.state, .available)
    }
    func testRateLimitCannotBeBypassedByRetryNetworkChangeOrInFlightSuccess() async throws {
        let clock = TMDBTestClock(), health = TMDBAvailability(now: { clock.now }), count = ProbeCounter()
        await health.finish(health.ticket(.metadata), outcome: .failure(.rateLimited, retryAfter: 900))
        await health.finish(health.ticket(.metadata), outcome: .success)
        await health.networkChanged()
        await health.probe(.metadata, force: true) { await count.increment(); return .success }
        try await Task.sleep(nanoseconds: 10_000_000)
        let calls = await count.value, blocked = await health.snapshot()
        XCTAssertEqual(calls, 0); XCTAssertEqual(blocked.metadata.retryAt, clock.now + 900)
        clock.advance(901)
        let allowed = await health.requestAllowed(.metadata)
        XCTAssertTrue(allowed)
    }
    func testImageProbeUsesGETDecodingAndAtMostOne404Replacement() async throws {
        let health = TMDBAvailability(), transport = ImageProbeTransport()
        let prober = TMDBLinkProber(availability: health, metadata: ProbeConfigurationService(), images: transport, imagePaths: ["/missing.jpg", "/valid.png", "/unused.jpg"])
        await prober.warm()
        for _ in 0..<40 {
            if await health.snapshot().ready { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let snapshot = await health.snapshot(), requests = await transport.requests
        XCTAssertTrue(snapshot.ready); XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == .get && $0.headers["Cache-Control"] == "no-cache" })
        let bad = TMDBObservedImageClient(base: ImageProbeTransport(invalid: true), availability: health)
        do { _ = try await bad.send(.init(url: TMDBClient.imageURL(path: "/valid.png", size: "w92")!)); XCTFail() } catch {}
        let failed = await health.snapshot(); XCTAssertEqual(failed.images.failure, .invalidResponse)
    }

    func testBrokenImageDoesNotBlockOtherArtwork() async throws {
        let health = TMDBAvailability()
        let bad = TMDBObservedImageClient(base: ImageProbeTransport(invalid: true), availability: health)
        do { _ = try await bad.send(.init(url: TMDBClient.imageURL(path: "/bad.png", size: "w92")!)); XCTFail() } catch {}
        let good = TMDBObservedImageClient(base: ImageProbeTransport(), availability: health)
        let result = try await good.send(.init(url: TMDBClient.imageURL(path: "/valid.png", size: "w92")!))
        XCTAssertTrue(TMDBImageValidation.decodes(result.body))
        let snapshot = await health.snapshot()
        XCTAssertEqual(snapshot.images.state, .available)
    }

    func testFailureClassificationAndRetryAfter() {
        XCTAssertEqual(TMDBLinkOutcome.status(404), .missing)
        XCTAssertEqual(TMDBLinkOutcome.status(403), .failure(.configuration))
        XCTAssertEqual(TMDBLinkOutcome.status(503), .failure(.server))
        XCTAssertEqual(TMDBLinkOutcome.error(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(TMDBLinkOutcome.error(URLError(.timedOut)), .failure(.network))
        XCTAssertEqual(TMDBClient.retryAfter("120"), 120)
        XCTAssertEqual(TMDBClient.retryAfter("Thu, 01 Jan 1970 00:02:00 GMT", now: Date(timeIntervalSince1970: 0)), 120)
        XCTAssertNil(TMDBClient.retryAfter("invalid"))
    }
}
private actor ProbeCounter { var value = 0; func increment() { value += 1 } }
private actor ProbeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
private final class TMDBTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ value: TimeInterval) { lock.lock(); self.value += value; lock.unlock() }
}

private struct ProbeConfigurationService: TMDBServing {
    func imageConfiguration() async throws -> TMDBImageConfiguration { .init(stillSizes: ["w92"]) }
    func search(query: String, type: TMDBMediaType?, year: Int?) async throws -> [TMDBWork] { [] }
    func detail(_ reference: TMDBReference) async throws -> TMDBWork { throw TMDBError.invalidInput }
    func season(tvID: Int, number: Int) async throws -> TMDBSeason { throw TMDBError.invalidInput }
}
private actor ImageProbeTransport: HTTPClient {
    var requests: [HTTPRequest] = []
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6RYsAAAAASUVORK5CYII=")!
        return .init(url: request.url, statusCode: request.url.lastPathComponent == "missing.jpg" ? 404 : 200, headers: [:], body: invalid ? Data("login portal".utf8) : pixel)
    }
}

extension TMDBAvailabilityTests {
    func testInvalidCredentialSuspendsAutomaticRequestsUntilConfigurationChanges() async {
        let clock = TMDBTestClock(), health = TMDBAvailability(now: { clock.now })
        await health.finish(health.ticket(.metadata), outcome: .failure(.configuration))
        clock.advance(86400)
        let allowed = await health.requestAllowed(.metadata)
        XCTAssertFalse(allowed)
        await health.networkChanged()
        let reset = await health.requestAllowed(.metadata)
        XCTAssertTrue(reset)
    }
}

extension TMDBAvailabilityTests {
    func testDisablingMetadataKeepsPublicProviderArtworkAvailable() async throws {
        let health = TMDBAvailability(), transport = ImageProbeTransport()
        await health.setMetadataRequestsEnabled(false)
        let allowed = await health.requestAllowed(.metadata)
        XCTAssertFalse(allowed)
        let client = TMDBObservedImageClient(base: transport, availability: health)
        _ = try await client.send(.init(url: TMDBClient.imageURL(path: "/fixture.jpg", size: "w92")!))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "Provider posters on the public CDN must not require a metadata credential")
        await health.setMetadataRequestsEnabled(true)
        let restored = await health.requestAllowed(.metadata)
        XCTAssertTrue(restored)
    }
}
