import XCTest
import Darwin
@testable import SpleenCore

/// Provider decoders, identity rules and formatting. Every value here is invented.
final class UsageLimitsTests: XCTestCase {
    private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }
    private func codex(_ text: String) -> Result<(windows: [UsageWindow], snapshot: String?), UsageFailure> { CodexUsage.limits(json(text)) }
    private func windows(_ result: Result<(windows: [UsageWindow], snapshot: String?), UsageFailure>) -> [UsageWindow] {
        (try? result.get().windows) ?? []
    }
    private let weekly = #"{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1900000000}"#
    private let fiveHour = #"{"usedPercent":16,"windowDurationMins":300,"resetsAt":1899990000}"#

    // MARK: Codex

    func testCodexLegacySingleBucket() {
        let found = windows(codex(#"{"rateLimits":{"limitId":"codex","limitName":null,"primary":\#(fiveHour),"secondary":\#(weekly)},"accountId":"acct-fixture"}"#))
        XCTAssertEqual(found.map(\.label), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(found.map(\.percentLeft), [84, 58])
        XCTAssertEqual(found[1].resetsAt, Date(timeIntervalSince1970: 1_900_000_000), "Codex resets are Unix seconds")
    }

    func testCodexWeeklyOnlyPrimaryIsLabelledFromItsDuration() {
        let found = windows(codex(#"{"rateLimits":{"limitId":"codex","primary":\#(weekly),"secondary":null}}"#))
        XCTAssertEqual(found.map(\.label), ["Weekly limit"], "primary is not assumed to be five hours")
    }

    func testCodexSecondaryShorterThanPrimaryIsShownFirst() {
        let found = windows(codex(#"{"rateLimits":{"limitId":"codex","primary":\#(weekly),"secondary":\#(fiveHour)}}"#))
        XCTAssertEqual(found.map(\.label), ["5-hour limit", "Weekly limit"])
    }

    func testCodexMultiBucketPrefersTheMapAndShowsABucketOnce() {
        let bucket = #"{"limitId":"codex","limitName":null,"primary":\#(fiveHour),"secondary":\#(weekly)}"#
        let same = windows(codex(#"{"rateLimits":\#(bucket),"rateLimitsByLimitId":{"codex":\#(bucket)}}"#))
        XCTAssertEqual(same.count, 2, "both representations of one bucket are shown once")
        let multi = windows(codex(#"""
        {"rateLimits":\#(bucket),"rateLimitsByLimitId":{
          "zeta":{"limitId":"zeta","limitName":"Fixture Model","primary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":1900000500}},
          "codex":\#(bucket)}}
        """#))
        XCTAssertEqual(multi.map(\.label), ["5-hour limit", "Weekly limit", "Fixture Model · Weekly limit"], "main bucket first")
        XCTAssertEqual(Set(multi.map(\.id)).count, 3)
    }

    func testCodexNullNestedLimitIdKeepsEqualValuedBuckets() {
        let found = windows(codex(#"{"rateLimits":{"primary":\#(weekly)},"rateLimitsByLimitId":{"alpha":{"limitId":null,"primary":\#(weekly)},"beta":{"limitId":null,"primary":\#(weekly)}}}"#))
        XCTAssertEqual(found.map(\.label), ["alpha · Weekly limit", "beta · Weekly limit"])
        XCTAssertEqual(Set(found.map(\.id)).count, 2)
    }

    func testCodexEmptyMapFallsBackToTheCompatibleView() {
        XCTAssertEqual(windows(codex(#"{"rateLimits":{"limitId":"codex","primary":\#(weekly)},"rateLimitsByLimitId":{}}"#)).map(\.label), ["Weekly limit"])
        XCTAssertEqual(windows(codex(#"{"rateLimits":{"limitId":"codex","primary":\#(weekly)},"rateLimitsByLimitId":null}"#)).count, 1)
    }

    func testCodexZeroHundredMissingResetMissingDurationAndMalformedPercent() {
        let found = windows(codex(#"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300},
                       "secondary":{"usedPercent":100,"resetsAt":null}},
         "futureField":{"anything":[1,2,3]}}
        """#))
        XCTAssertEqual(found.map(\.percentLeft), [100, 0], "zero and 100 % are ordinary readings")
        XCTAssertEqual(found.map(\.label), ["5-hour limit", "Usage limit"])
        XCTAssertNil(found[0].resetsAt)
        XCTAssertNil(found[1].resetsAt)
        let sibling = windows(codex(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":"lots","windowDurationMins":300},"secondary":{"usedPercent":12.5,"windowDurationMins":1440,"unknown":true}}}"#))
        XCTAssertEqual(sibling.map(\.label), ["Daily limit"], "a malformed percentage drops only its window")
        XCTAssertEqual(sibling.first?.percentLeft, 88)
        XCTAssertEqual(windows(codex(#"{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":300}}}"#)).count, 0)
        XCTAssertEqual(windows(codex(#"{"rateLimits":{"primary":{"usedPercent":100.3,"windowDurationMins":300}}}"#)).first?.percentLeft, 0,
                       "a tiny overshoot is clamped")
    }

    func testCodexNothingRecognisableIsNeverAnEmptySuccess() {
        XCTAssertEqual(codex(#"{"something":"else"}"#).failureValue, .incompatible)
        XCTAssertEqual(codex(#"{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}"#).failureValue, .offlineOrEmpty)
        XCTAssertEqual(CodexUsage.limits(NSNull()).failureValue, .incompatible)
    }

    func testCodexAccountIdentity() {
        let known = CodexUsage.account(json(#"{"account":{"type":"chatgpt","email":"person@example.com","planType":"plus"},"requiresOpenaiAuth":true,"userId":"user-fixture-1","workspaceRouting":{"chatgptAccountId":"acct-fixture","backendOrigin":"x","accountRoutingOverride":"NO_CONSTRAINT"}}"#))
        guard case .known(let person) = known.identity else { return XCTFail("a user id identifies the person") }
        XCTAssertNotNil(person.organization)
        XCTAssertEqual(known.snapshotKey, CodexUsage.limits(json(#"{"rateLimits":{"primary":\#(weekly)},"accountId":"acct-fixture"}"#)).successSnapshot,
                       "the workspace account is the snapshot owner's kind")
        XCTAssertEqual(CodexUsage.account(json(#"{"account":null,"requiresOpenaiAuth":true,"userId":null}"#)).identity, .signedOut)
        XCTAssertEqual(CodexUsage.account(json(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#)).identity, .unknown)
        XCTAssertEqual(CodexUsage.account(json(#"{"account":null,"requiresOpenaiAuth":false}"#)).identity, .unknown)
    }

    func testCodexEnvelopes() {
        guard case .error(id: 2, code: -32600, let message) = CodexEnvelope(Data(#"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#.utf8)) else { return XCTFail() }
        XCTAssertTrue(CodexUsage.mentionsSignIn(message))
        guard case .notification(method: "account/updated", _) = CodexEnvelope(Data(#"{"method":"account/updated","params":{"authMode":null}}"#.utf8)) else { return XCTFail() }
        guard case .other = CodexEnvelope(Data("not json".utf8)) else { return XCTFail() }
        guard case .other = CodexEnvelope(Data("42".utf8)) else { return XCTFail() }
        guard case .result(id: 1, _) = CodexEnvelope(Data(#"{"id":1,"result":null}"#.utf8)) else { return XCTFail() }
    }

    // MARK: Claude

    func testClaudeOutboundRequestIsTheLiteralSnakeCaseLine() {
        XCTAssertEqual(String(decoding: ClaudeUsage.usageRequest, as: UTF8.self),
                       "{\"type\":\"control_request\",\"request_id\":\"usage\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n")
        XCTAssertFalse(String(decoding: ClaudeUsage.usageRequest, as: UTF8.self).contains("skipBehaviors"))
        XCTAssertEqual(ClaudeUsage.arguments, ["-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
            "--no-session-persistence", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
            "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"])
    }

    func testClaudePreflightRule() {
        XCTAssertTrue(ClaudeUsage.honoursSkipBehaviors(version: "2.1.999", capabilities: ["other_v1", "get_usage_detached_v1"]))
        for version in ["2.1.314", "2.1.325", "2.1.328"] {
            XCTAssertTrue(ClaudeUsage.honoursSkipBehaviors(version: version, capabilities: nil), version)
        }
        for version in ["2.1.300", "2.1.326", "garbage", ""] {
            XCTAssertFalse(ClaudeUsage.honoursSkipBehaviors(version: version, capabilities: ["other_v1"]), version)
        }
        XCTAssertFalse(ClaudeUsage.honoursSkipBehaviors(version: nil, capabilities: nil))
    }

    private let iso = "2026-11-24T22:59:59.915702+00:00"
    private func claudeWindows(_ text: String) -> [UsageWindow] { ClaudeUsage.windows(json(text) as! [String: Any]) }

    func testClaudeNullFiveHourAndModelScopedWithDuplicateLimits() {
        let found = claudeWindows(#"""
        {"five_hour":null,"seven_day":{"utilization":37.0,"resets_at":"\#(iso)","used_dollars":1},
         "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_oauth_apps":null,"some_codename":null,
         "model_scoped":[{"display_name":"Fixture","utilization":12.0,"resets_at":"\#(iso)"}],
         "limits":[{"kind":"weekly_all","group":"weekly","percent":37,"resets_at":"\#(iso)","scope":null,"severity":"normal","is_active":true},
                   {"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"\#(iso)","scope":{"model":{"id":null,"display_name":"Fixture"},"surface":null}},
                   {"kind":"spend_cap","group":"spend","percent":90,"resets_at":"\#(iso)"}],
         "spend":{"percent":50},"extra_usage":{"utilization":80.0},"seven_day_breakdown":{"x":1},"weekly_scoped_shares":[{"a":1}]}
        """#)
        XCTAssertEqual(found.map(\.label), ["Weekly limit", "Weekly limit · Fixture"], "each window once; spend and unknown kinds ignored")
        XCTAssertEqual(found.map(\.percentLeft), [63, 88])
    }

    func testClaudeWindowsOnlyInLimitsAndNamedFieldsWinner() {
        let only = claudeWindows(#"""
        {"limits":[{"kind":"session","group":"session","percent":0,"resets_at":"2026-11-23T03:00:00Z"},
                   {"kind":"weekly_scoped","percent":100,"resets_at":null,"scope":{"model":{"display_name":"Fixture"}}}]}
        """#)
        XCTAssertEqual(only.map(\.label), ["5-hour limit", "Weekly limit · Fixture"])
        XCTAssertEqual(only.map(\.percentLeft), [100, 0])
        XCTAssertNil(only[1].resetsAt)
        let named = claudeWindows(#"""
        {"seven_day_opus":{"utilization":20,"resets_at":"\#(iso)"},
         "model_scoped":[{"display_name":"Opus","utilization":21,"resets_at":"\#(iso)"}],
         "limits":[{"kind":"weekly_scoped","percent":22,"resets_at":"\#(iso)","scope":{"model":{"display_name":"opus"}}}]}
        """#)
        XCTAssertEqual(named.map(\.percentLeft), [80], "one scope reported three ways shows once, from the named field")
    }

    func testClaudeTwoScopesWithEqualValuesAndConnectedApps() {
        let found = claudeWindows(#"""
        {"model_scoped":[{"display_name":"Alpha","utilization":10,"resets_at":"\#(iso)"},{"display_name":"Beta","utilization":10,"resets_at":"\#(iso)"}],
         "seven_day_oauth_apps":{"utilization":3,"resets_at":"2026-11-24T22:59:59Z"}}
        """#)
        XCTAssertEqual(found.map(\.label), ["Weekly limit · Alpha", "Weekly limit · Beta", "Weekly limit · connected apps"])
    }

    func testClaudeTimestampsWithAndWithoutFractions() {
        let whole = UsageTimestamp.parse("2026-11-24T22:59:59Z")
        XCTAssertEqual(whole, Date(timeIntervalSince1970: 1_795_561_199))
        XCTAssertEqual(UsageTimestamp.parse("2026-11-24T22:59:59+00:00"), whole)
        XCTAssertEqual(UsageTimestamp.parse("2026-11-24T22:59:59.5Z")?.timeIntervalSince1970 ?? 0, 1_795_561_199.5, accuracy: 0.001)
        XCTAssertEqual(UsageTimestamp.parse(iso)?.timeIntervalSince1970 ?? 0, 1_795_561_199.915, accuracy: 0.001)
        XCTAssertNil(UsageTimestamp.parse("soon"))
        XCTAssertNil(UsageTimestamp.parse(17))
    }

    private let gate = ClaudeUsageGate()
    private func outcome(_ text: String) -> Result<UsageReading, UsageProblem> {
        ClaudeUsage.outcome(json(text) as! [String: Any], identity: .unknown, checkedAt: Date(timeIntervalSince1970: 0), version: "2.1.330", gate: gate)
    }

    func testClaudeEnvelopes() {
        XCTAssertEqual(outcome(#"{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":null,"behaviors":null}}"#).failureValue?.failure, .offlineOrEmpty,
                       "a success with null limits is not an empty success")
        XCTAssertEqual(outcome(#"{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":null},"behaviors":null}}"#).failureValue?.failure, .offlineOrEmpty)
        XCTAssertEqual(outcome(#"{"subtype":"success","request_id":"usage","response":{"rate_limits_available":false,"rate_limits":null,"behaviors":null}}"#).failureValue?.failure, .noSubscriptionLimits)
        XCTAssertEqual(outcome(#"{"subtype":"error","request_id":"usage","error":"Unsupported control request subtype: get_usage"}"#).failureValue?.failure, .incompatible)
        XCTAssertEqual(outcome(#"{"subtype":"error","request_id":"usage","error":"Not logged in · Please run /login"}"#).failureValue?.failure, .signedOut)
        let ok = outcome(#"{"subtype":"success","request_id":"usage","response":{"session":{"total_cost_usd":1},"brand_new":{"x":1},"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":50,"resets_at":"\#(iso)"}},"behaviors":null}}"#)
        XCTAssertEqual((try? ok.get())?.windows.map(\.percentLeft), [50], "unknown fields are tolerated")
        XCTAssertNil(ClaudeUsage.matches(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"other"}}"#.utf8), requestID: "usage"))
        XCTAssertNil(ClaudeUsage.matches(Data(#"{"type":"system","subtype":"init"}"#.utf8), requestID: "usage"))
        XCTAssertNil(ClaudeUsage.matches(Data("garbage".utf8), requestID: "usage"))
        XCTAssertNotNil(ClaudeUsage.matches(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage"}}"#.utf8), requestID: "usage"))
    }

    func testClaudeBehaviorsAfterPreflightBlocksTheVersion() {
        let gate = ClaudeUsageGate()
        let result = ClaudeUsage.outcome(json(#"{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":50,"resets_at":null}},"behaviors":{"day":{},"week":{}}}}"#) as! [String: Any],
                                         identity: .unknown, checkedAt: Date(), version: "2.1.777", gate: gate)
        XCTAssertEqual(result.failureValue?.failure, .incompatible)
        XCTAssertTrue(gate.isBlocked("2.1.777"))
        XCTAssertFalse(gate.isBlocked("2.1.778"))
    }

    func testClaudeIdentity() {
        guard case .known(let person) = ClaudeUsage.identity(json(#"{"email":"person@example.com","organization":"Example Org","subscriptionType":"max","apiProvider":"firstParty"}"#)) else { return XCTFail() }
        XCTAssertNotNil(person.organization)
        XCTAssertEqual(ClaudeUsage.identity(json(#"{"apiProvider":"firstParty","tokenSource":"none"}"#)), .signedOut)
        XCTAssertEqual(ClaudeUsage.identity(json(#"{"apiProvider":"bedrock"}"#)), .unknown, "a backend alone identifies nobody")
        XCTAssertEqual(ClaudeUsage.identity(json(#"{"organization":"Example Org","apiProvider":"firstParty"}"#)), .unknown, "organization alone identifies nobody")
        XCTAssertEqual(ClaudeUsage.identity(json(#"{"apiProvider":"firstParty","tokenSource":"none","apiKeySource":"ANTHROPIC_API_KEY"}"#)), .unknown)
        XCTAssertEqual(ClaudeUsage.identity(NSNull()), .unknown)
    }

    // MARK: Identity rules

    func testIdentityRules() {
        let a = UsagePerson(key: "a", organization: "org1"), aNoOrg = UsagePerson(key: "a"), aOtherOrg = UsagePerson(key: "a", organization: "org2")
        XCTAssertTrue(UsageIdentityRules.confirmsChange(cached: .known(a), observed: .known(UsagePerson(key: "b"))))
        XCTAssertTrue(UsageIdentityRules.confirmsChange(cached: .known(a), observed: .signedOut))
        XCTAssertTrue(UsageIdentityRules.confirmsChange(cached: .known(a), observed: .known(aOtherOrg)), "same email, different organization on both sides")
        XCTAssertFalse(UsageIdentityRules.confirmsChange(cached: .known(a), observed: .known(aNoOrg)), "one side lacking an organization changes nothing")
        XCTAssertFalse(UsageIdentityRules.confirmsChange(cached: .known(a), observed: .unknown))
        XCTAssertFalse(UsageIdentityRules.confirmsChange(cached: .unknown, observed: .known(a)))
        XCTAssertFalse(UsageIdentityRules.snapshotChanged(cached: nil, observed: "s1"))
        XCTAssertTrue(UsageIdentityRules.snapshotChanged(cached: "s1", observed: "s2"))
        XCTAssertNotEqual(UsageIdentity.hash(["x", "y"]), UsageIdentity.hash(["xy"]))
    }

    // MARK: Labels and formatting

    func testLabelsRoundingAndExpiry() {
        XCTAssertEqual([300, 1440, 10080, 120, 4320, 90, 0].map { UsageLabels.duration(minutes: $0) },
                       ["5-hour limit", "Daily limit", "Weekly limit", "2-hour limit", "3-day limit", "90-minute limit", "Usage limit"])
        XCTAssertEqual(UsageLabels.duration(minutes: nil), "Usage limit")
        let reset = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow(id: "w", label: "Weekly limit", usedPercent: 15.6, resetsAt: reset)
        XCTAssertEqual(window.percentLeft, 85, "percent used is floored, as on the native surfaces")
        XCTAssertEqual(UsageWindow(id: "w", label: "", usedPercent: 0.4, resetsAt: nil).percentLeft, 100)
        XCTAssertEqual(UsageWindow(id: "w", label: "", usedPercent: 99.6, resetsAt: nil).percentLeft, 1)
        XCTAssertFalse(window.isExpired(at: reset.addingTimeInterval(-0.001)))
        XCTAssertTrue(window.isExpired(at: reset), "expired at the boundary")
        XCTAssertFalse(UsageWindow(id: "w", label: "", usedPercent: 1, resetsAt: nil).isExpired(at: .distantFuture))
        XCTAssertNil(UsageWindow.percent(true), "a boolean is not a percentage")
        XCTAssertNil(UsageWindow.percent(Double.nan))
    }

    private let pacific = UsageTimeFormat(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    private func claudeReset(_ iso: String) -> Date? {
        ClaudeUsage.windows(json(#"{"seven_day":{"utilization":10,"resets_at":"\#(iso)"}}"#) as! [String: Any]).first?.resetsAt
    }
    private func codexReset(_ unix: Int) -> Date? {
        windows(codex(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":\#(unix)}}}"#)).first?.resetsAt
    }

    func testResetFormattingWithFixedZoneAndLocale() {
        let now = Date(timeIntervalSince1970: 1_795_420_800) // Mon 23 Nov 2026 08:00 UTC
        let soon = Date(timeIntervalSince1970: 1_795_561_140) // Tue 24 Nov 2026 22:59 UTC = 2:59 PM PST
        XCTAssertEqual(plain(pacific.reset(soon, now: now)), "Tue, Nov 24 at 2:59 PM", "always the exact date and minute")
        XCTAssertEqual(plain(pacific.reset(soon, now: now, spoken: true)), "Tuesday, November 24 at 2:59 PM")
        XCTAssertEqual(plain(pacific.time(soon)), "2:59 PM")
        let nextYear = Date(timeIntervalSince1970: 1_798_909_500) // Sat 2 Jan 2027 17:05 UTC
        XCTAssertTrue(pacific.reset(nextYear, now: Date(timeIntervalSince1970: 1_798_632_000)).contains("2027"), "the year when it is not this one")
        let precise = plain(pacific.precise(Date(timeIntervalSince1970: 1_795_561_199.9)))
        XCTAssertTrue(precise.contains("2:59:59") && precise.contains("Pacific Standard Time") && precise.contains("2026"), precise)
    }

    func testDecodedResetsFormatToTheProvidersExactLocalMinute() throws {
        let now = Date(timeIntervalSince1970: 1_795_420_800)
        // A fractional-second Claude time and a Codex Unix time, never rounded up or shifted.
        XCTAssertEqual(plain(pacific.reset(try XCTUnwrap(claudeReset("2026-11-24T22:59:59.915702+00:00")), now: now)), "Tue, Nov 24 at 2:59 PM")
        XCTAssertEqual(plain(pacific.reset(try XCTUnwrap(codexReset(1_795_561_140)), now: now)), "Tue, Nov 24 at 2:59 PM")
        // Crossing local midnight: the last second of the day stays on that day.
        XCTAssertEqual(plain(pacific.reset(try XCTUnwrap(claudeReset("2026-11-25T07:59:59.999Z")), now: now)), "Tue, Nov 24 at 11:59 PM")
        XCTAssertEqual(plain(pacific.reset(try XCTUnwrap(codexReset(1_795_593_630)), now: now)), "Wed, Nov 25 at 12:00 AM")
    }

    func testDaylightSavingChangesKeepTheExactInstant() throws {
        let beforeFallBack = Date(timeIntervalSince1970: 1_793_512_800) // Sat 31 Oct 2026 11:00 PM PDT
        let daylight = try XCTUnwrap(claudeReset("2026-11-01T08:30:15.5Z"))  // 1:30 AM PDT, before the clocks go back
        let standard = try XCTUnwrap(codexReset(1_793_525_415))               // 1:30 AM PST, an hour later
        XCTAssertEqual(plain(pacific.reset(daylight, now: beforeFallBack)), "Sun, Nov 1 at 1:30 AM")
        XCTAssertEqual(plain(pacific.reset(standard, now: beforeFallBack)), "Sun, Nov 1 at 1:30 AM")
        XCTAssertTrue(pacific.precise(daylight).contains("Pacific Daylight Time") && pacific.precise(standard).contains("Pacific Standard Time"),
                      "the tooltip tells the repeated hour apart")
        XCTAssertEqual(pacific.relative(to: standard, now: beforeFallBack), "in 3 h 30 min", "the countdown is real time, not wall-clock time")
        let beforeSpringForward = Date(timeIntervalSince1970: 1_805_014_800) // Sun 14 Mar 2027 1:00 AM PST
        let springReset = try XCTUnwrap(codexReset(1_805_018_400))            // 3:00 AM PDT, one real hour later
        XCTAssertEqual(plain(pacific.reset(springReset, now: beforeSpringForward)), "Sun, Mar 14 at 3:00 AM")
        XCTAssertEqual(pacific.relative(to: springReset, now: beforeSpringForward), "in 1 h")
    }

    func testCountdownAndItsNextChange() {
        let reset = Date(timeIntervalSince1970: 1_795_561_199.9)
        func left(_ seconds: TimeInterval) -> Date { reset.addingTimeInterval(-seconds) }
        XCTAssertEqual(pacific.relative(to: reset, now: left(2 * 86_400 + 4 * 3600 + 59 * 60)), "in 2 d 4 h")
        XCTAssertEqual(pacific.relative(to: reset, now: left(3 * 86_400 + 30)), "in 3 d")
        XCTAssertEqual(pacific.relative(to: reset, now: left(5 * 3600 + 12 * 60 + 30)), "in 5 h 12 min")
        XCTAssertEqual(pacific.relative(to: reset, now: left(3600)), "in 1 h")
        XCTAssertEqual(pacific.relative(to: reset, now: left(37 * 60 + 59)), "in 37 min", "whole minutes, never rounded up")
        XCTAssertEqual(pacific.relative(to: reset, now: left(60)), "in 1 min")
        XCTAssertEqual(pacific.relative(to: reset, now: left(59.9)), "in under a minute")
        XCTAssertEqual(pacific.relative(to: reset, now: left(2 * 86_400 + 3600), spoken: true), "in 2 days 1 hour")
        let now = left(37 * 60 + 12.5)
        XCTAssertEqual(UsageTimeFormat.nextChange(for: reset, after: now)!.timeIntervalSince(now), 12.5, accuracy: 0.001,
                       "the next tick is when the whole minutes left change")
        XCTAssertEqual(UsageTimeFormat.nextChange(for: reset, after: left(120))!.timeIntervalSince(left(120)), 60, accuracy: 0.001)
        XCTAssertEqual(UsageTimeFormat.nextChange(for: reset, after: left(20)), reset, "the reset itself is a change")
        XCTAssertNil(UsageTimeFormat.nextChange(for: reset, after: reset))
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}
extension Result where Success == (windows: [UsageWindow], snapshot: String?) {
    var successSnapshot: String? { (try? get())?.snapshot ?? nil }
}

/// The Codex and Claude adapters end to end, against a scripted stand-in that records every
/// line it received. Every value is invented.
final class UsageExchangeTests: XCTestCase {
    private var directory: URL!
    private var standIn: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-usage-exchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        standIn = directory.appendingPathComponent("stand-in")
        // "<" reads one request line into $RECEIVED, "~N" sleeps, any other line is written out.
        try #"""
        #!/bin/sh
        while IFS= read -r line <&3; do
          case "$line" in
            "<") IFS= read -r request || exit 0; printf '%s\n' "$request" >> "$RECEIVED";;
            "~"*) sleep "${line#\~}";;
            *) printf '%s\n' "$line";;
          esac
        done 3< "$SCENARIO"
        sleep 30
        """#.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private struct Outcome { var events: [UsageEvent]; var received: [String]
        var finished: Result<UsageReading, UsageProblem>? {
            for event in events.reversed() { if case .finished(let result) = event { return result } }
            return nil
        }
        var identities: [UsageIdentity] { events.compactMap { if case .identity(let identity) = $0 { return identity }; return nil } }
    }

    private func run(_ lines: [String], limits: HelperLimits = HelperLimits(runtime: 5, maximumOutputBytes: 1_000_000),
                     start: (HelperLane, UsageFetchRequest, [String: String]) -> Void) -> Outcome {
        let scenario = directory.appendingPathComponent("scenario-\(UUID().uuidString)")
        let received = directory.appendingPathComponent("received-\(UUID().uuidString)")
        try! (lines.joined(separator: "\n") + "\n").write(to: scenario, atomically: true, encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin", "SCENARIO": scenario.path, "RECEIVED": received.path]
        let lane = HelperLane(label: "test.usage")
        let lock = NSLock()
        var events: [UsageEvent] = []
        let finished = expectation(description: "finished")
        start(lane, UsageFetchRequest(cancellation: HelperCancellation(), cachedOwner: nil) { event in
            lock.lock(); events.append(event); lock.unlock()
            if case .finished = event { finished.fulfill() }
        }, environment)
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(lane.waitUntilIdle(timeout: 3))
        let text = (try? String(contentsOf: received)) ?? ""
        return Outcome(events: events, received: text.split(separator: "\n").map(String.init))
    }

    private func codex(_ lines: [String], cachedOwner: UsageOwner? = nil, executable: URL? = nil,
                       limits: HelperLimits = HelperLimits(runtime: 5, maximumOutputBytes: 1_000_000)) -> Outcome {
        run(lines, limits: limits) { lane, request, environment in
            let owned = UsageFetchRequest(cancellation: request.cancellation, cachedOwner: cachedOwner, emit: request.emit)
            CodexUsage.fetch(executable: { executable ?? self.standIn }, workingDirectory: { self.directory }, environment: environment,
                             lane: lane, request: owned, limits: limits)
        }
    }
    private func claude(_ lines: [String], gate: ClaudeUsageGate = ClaudeUsageGate(), executable: URL? = nil,
                        limits: HelperLimits = HelperLimits(runtime: 5, maximumOutputBytes: 1_000_000)) -> Outcome {
        run(lines, limits: limits) { lane, request, environment in
            ClaudeUsage.fetch(executable: { executable ?? self.standIn }, workingDirectory: { self.directory }, environment: environment,
                              lane: lane, gate: gate, request: request, limits: limits)
        }
    }

    // MARK: Codex fixtures

    private let initReply = #"{"id":0,"result":{"userAgent":"fixture"}}"#
    private let noise = #"{"method":"remoteControl/status/changed","params":{"status":"fixture"}}"#
    private let routing = #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus","reason":"workspaceRoutingReady"}}"#
    private let signOut = #"{"method":"account/updated","params":{"authMode":null,"planType":null}}"#
    private func account(_ user: String, _ workspace: String) -> String {
        #"{"id":1,"result":{"account":{"type":"chatgpt","email":"\#(user)@example.com","planType":"plus","workspaceName":null},"requiresOpenaiAuth":true,"userId":"\#(user)","workspaceRouting":{"chatgptAccountId":"\#(workspace)","backendOrigin":"fixture","accountRoutingOverride":"NO_CONSTRAINT"}}}"#
    }
    private func limitsReply(owner: String?) -> String {
        let bucket = #"{"limitId":"codex","limitName":null,"primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":null,"credits":null,"planType":"plus"}"#
        let named = owner.map { #","accountId":"\#($0)""# } ?? ""
        return #"{"id":2,"result":{"rateLimits":\#(bucket),"rateLimitsByLimitId":{"codex":\#(bucket)}\#(named),"rateLimitResetCredits":null}}"#
    }
    private var handshake: [String] { ["<", noise, initReply, "<", "<", "<"] }
    private func snapshot(_ workspace: String) -> String { UsageIdentity.hash(["codex-account", workspace]) }
    private func person(_ user: String, _ workspace: String) -> UsageIdentity {
        let reply = try! JSONSerialization.jsonObject(with: Data(account(user, workspace).utf8)) as! [String: Any]
        return CodexUsage.account(reply["result"]!).identity
    }

    func testCodexHandshakeWithInterleavedNotifications() throws {
        let outcome = codex(handshake + [routing, account("user-a", "acct-a"), noise, limitsReply(owner: "acct-a")])
        XCTAssertEqual(outcome.received.count, 4)
        XCTAssertTrue(outcome.received[0].contains("\"initialize\"") && outcome.received[1].contains("\"initialized\""))
        XCTAssertTrue(outcome.received[2].contains("account/read") && outcome.received[2].contains("\"refreshToken\":false"))
        XCTAssertTrue(outcome.received[3].contains("account/rateLimits/read"))
        let reading = try XCTUnwrap(try outcome.finished?.get())
        XCTAssertEqual(reading.windows.map(\.label), ["Weekly limit"])
        XCTAssertEqual(reading.owner, UsageOwner(user: person("user-a", "acct-a"), snapshot: snapshot("acct-a")))
        XCTAssertEqual(outcome.identities, [person("user-a", "acct-a")], "identity is emitted before the reading")
    }

    func testCodexLimitsReplyBeforeAccountRead() throws {
        let outcome = codex(handshake + [limitsReply(owner: "acct-a"), "~0.2", account("user-a", "acct-a")])
        let reading = try XCTUnwrap(try outcome.finished?.get())
        XCTAssertEqual(reading.owner.user, person("user-a", "acct-a"), "the reply waited for its connection's identity")
        guard case .identity = outcome.events.first else { return XCTFail("identity first") }
    }

    func testCodexSignOutBetweenTheRepliesDiscardsTheLimitsReply() {
        let outcome = codex(handshake + [account("user-a", "acct-a"), signOut, limitsReply(owner: "acct-a")])
        XCTAssertEqual(outcome.identities, [person("user-a", "acct-a"), .signedOut])
        XCTAssertEqual(outcome.finished?.failureValue?.failure, .signedOut)
    }

    func testCodexReplyNamingANewOwnerReplacesTheCache() throws {
        let cached = UsageOwner(user: person("user-a", "acct-a"), snapshot: snapshot("acct-a"))
        let outcome = codex(handshake + [account("user-b", "acct-b"), limitsReply(owner: "acct-b")], cachedOwner: cached)
        XCTAssertEqual(outcome.identities, [person("user-b", "acct-b")])
        XCTAssertEqual(try outcome.finished?.get().owner.snapshot, snapshot("acct-b"))
    }

    func testCodexSwitchLeavingAnOwnerlessReplyAmbiguousDiscardsIt() {
        let cached = UsageOwner(user: person("user-a", "acct-a"), snapshot: snapshot("acct-a"))
        XCTAssertEqual(codex(handshake + [account("user-b", "acct-b"), limitsReply(owner: nil)], cachedOwner: cached).finished?.failureValue?.failure, .accountChanged)
        XCTAssertEqual(codex(handshake + [account("user-a", "acct-a"), limitsReply(owner: "acct-z")]).finished?.failureValue?.failure, .accountChanged,
                       "a reply naming an owner other than the one in force is discarded")
        let unrouted = #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus","reason":null}}"#
        XCTAssertEqual(codex(handshake + [account("user-a", "acct-a"), unrouted, limitsReply(owner: nil)]).finished?.failureValue?.failure, .accountChanged)
        XCTAssertNotNil(try? codex(handshake + [account("user-a", "acct-a"), unrouted, limitsReply(owner: "acct-a")]).finished?.get())
    }

    func testCodexSignedOutErrorAndOlderServer() throws {
        let signedOut = codex(handshake + [#"{"id":1,"result":{"account":null,"requiresOpenaiAuth":true,"userId":null,"workspaceRouting":null}}"#,
                                           #"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#])
        XCTAssertEqual(signedOut.identities.first, .signedOut)
        XCTAssertEqual(signedOut.finished?.failureValue?.failure, .signedOut)
        let older = codex(handshake + [#"{"id":1,"error":{"code":-32601,"message":"unknown method"}}"#, limitsReply(owner: nil)])
        XCTAssertEqual(try older.finished?.get().owner, UsageOwner(user: .unknown, snapshot: nil), "identity is delivered even when it is unknown")
        let offline = codex(handshake + [account("user-a", "acct-a"), #"{"id":2,"error":{"code":-32603,"message":"stream disconnected"}}"#])
        XCTAssertEqual(offline.identities, [person("user-a", "acct-a")], "identity arrives even when the limits read fails")
        XCTAssertEqual(offline.finished?.failureValue?.failure, .offlineOrEmpty)
        let apiKey = codex(handshake + [#"{"id":1,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#, #"{"id":2,"error":{"code":-32600,"message":"chatgpt account required"}}"#])
        XCTAssertEqual(apiKey.finished?.failureValue?.failure, .noSubscriptionLimits)
    }

    func testCodexMissingClientTimeoutAndEarlyExit() {
        XCTAssertEqual(codex([], executable: directory.appendingPathComponent("missing")).finished?.failureValue?.failure, .missingClient)
        XCTAssertEqual(codex(["<", "~5"], limits: HelperLimits(runtime: 0.5, maximumOutputBytes: 1000)).finished?.failureValue?.failure, .timeout)
        let exits = directory.appendingPathComponent("exits")
        try! "#!/bin/sh\nexit 3\n".write(to: exits, atomically: true, encoding: .utf8); chmod(exits.path, 0o755)
        XCTAssertEqual(codex([], executable: exits).finished?.failureValue?.failure, .offlineOrEmpty)
    }

    // MARK: Claude fixtures

    private func claudeInit(version: String = "2.1.330", capabilities: String = #"["get_usage_detached_v1"]"#,
                            account: String = #"{"email":"person@example.com","organization":"Example Org","subscriptionType":"max","apiProvider":"firstParty"}"#) -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"claude_code_version":"\#(version)","capabilities":\#(capabilities),"account":\#(account),"commands":[]}}}"#
    }
    private func claudeUsage(behaviors: String = "null") -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":40,"resets_at":"2026-11-24T22:59:59.915702+00:00"}},"behaviors":\#(behaviors)}}}"#
    }
    private let systemLine = #"{"type":"system","subtype":"init","session_id":"fixture"}"#
    private let otherResponse = #"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"#

    func testClaudeReadSendsExactlyTheTwoRequests() throws {
        let outcome = claude(["<", systemLine, claudeInit(), "<", otherResponse, systemLine, claudeUsage()])
        XCTAssertEqual(outcome.received, [String(decoding: ClaudeUsage.initializeRequest.dropLast(), as: UTF8.self),
                                          String(decoding: ClaudeUsage.usageRequest.dropLast(), as: UTF8.self)])
        let reading = try XCTUnwrap(try outcome.finished?.get())
        XCTAssertEqual(reading.windows.map(\.label), ["Weekly limit"])
        guard case .known = outcome.identities.first else { return XCTFail("identity from initialize") }
    }

    func testClaudePreflightFailureSendsNoUsageRequest() {
        for (version, capabilities) in [("2.1.300", #"["other_v1"]"#), ("garbage", "null"), ("", "{}")] {
            let outcome = claude(["<", claudeInit(version: version, capabilities: capabilities), "<", claudeUsage()])
            XCTAssertEqual(outcome.finished?.failureValue?.failure, .incompatible, version)
            XCTAssertEqual(outcome.received, [String(decoding: ClaudeUsage.initializeRequest.dropLast(), as: UTF8.self)],
                           "zero usage requests to \(version)")
        }
        let inspected = claude(["<", claudeInit(version: "2.1.325", capabilities: "[]"), "<", claudeUsage()])
        XCTAssertNotNil(try? inspected.finished?.get(), "an inspected older build passes preflight")
        XCTAssertEqual(inspected.received.count, 2)
    }

    func testClaudeBehaviorsRegressionStopsFurtherRequests() {
        let gate = ClaudeUsageGate()
        let first = claude(["<", claudeInit(version: "2.1.777"), "<", claudeUsage(behaviors: #"{"day":{},"week":{}}"#)], gate: gate)
        XCTAssertEqual(first.finished?.failureValue?.failure, .incompatible)
        let second = claude(["<", claudeInit(version: "2.1.777"), "<", claudeUsage()], gate: gate)
        XCTAssertEqual(second.finished?.failureValue?.failure, .incompatible)
        XCTAssertEqual(second.received.count, 1, "no further usage request to that client version")
    }

    func testClaudeSignedOutAndIdentityKinds() {
        let signedOut = claude(["<", claudeInit(account: #"{"apiProvider":"firstParty","tokenSource":"none"}"#), "<", claudeUsage()])
        XCTAssertEqual(signedOut.identities, [.signedOut])
        XCTAssertEqual(signedOut.finished?.failureValue?.failure, .signedOut)
        XCTAssertEqual(signedOut.received.count, 1)
        let unknown = claude(["<", claudeInit(account: #"{"organization":"Example Org","apiProvider":"firstParty"}"#), "<", claudeUsage()])
        XCTAssertEqual(unknown.identities, [.unknown])
        XCTAssertEqual(try? unknown.finished?.get().owner.user, .unknown, "an unknown read owns its reading as unknown")
    }

    func testClaudeNullSuccessAndTimeout() {
        let empty = #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":null,"behaviors":null}}}"#
        XCTAssertEqual(claude(["<", claudeInit(), "<", empty]).finished?.failureValue?.failure, .offlineOrEmpty)
        XCTAssertEqual(claude(["<", claudeInit(), "<", "~5"], limits: HelperLimits(runtime: 0.6, maximumOutputBytes: 100_000)).finished?.failureValue?.failure, .timeout)
    }

    func testClaudeResolutionAndEnvNodeShim() throws {
        let home = directory.appendingPathComponent("home")
        let pathDirectory = directory.appendingPathComponent("path-bin")
        for folder in [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local"), pathDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A directory named claude, then a non-executable file, are both skipped.
        try "x".write(to: home.appendingPathComponent(".claude/local/claude"), atomically: true, encoding: .utf8)
        let target = directory.appendingPathComponent("real-claude")
        try "#!/bin/sh\n".write(to: target, atomically: true, encoding: .utf8); chmod(target.path, 0o755)
        try FileManager.default.createSymbolicLink(at: pathDirectory.appendingPathComponent("claude"), withDestinationURL: target)
        let path = "relative/bin:\(pathDirectory.path)"
        XCTAssertEqual(ClaudeUsage.resolveExecutable(home: home, path: path)?.path, pathDirectory.appendingPathComponent("claude").path)
        XCTAssertEqual(ClaudeUsage.candidates(home: home, path: path).prefix(3),
                       [home.appendingPathComponent(".local/bin/claude").path, home.appendingPathComponent(".claude/local/claude").path,
                        pathDirectory.appendingPathComponent("claude").path], "relative PATH entries are ignored")
        chmod(home.appendingPathComponent(".claude/local/claude").path, 0o755)
        XCTAssertEqual(ClaudeUsage.resolveExecutable(home: home, path: path)?.path, home.appendingPathComponent(".claude/local/claude").path)

        // A `#!/usr/bin/env node` shim beside its node starts under a minimal PATH.
        let shimDirectory = directory.appendingPathComponent("node-bin")
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        let node = shimDirectory.appendingPathComponent("node")
        try "#!/bin/sh\nexec /bin/sh \(standIn.path)\n".write(to: node, atomically: true, encoding: .utf8); chmod(node.path, 0o755)
        let shim = shimDirectory.appendingPathComponent("claude")
        try "#!/usr/bin/env node\n// fixture\n".write(to: shim, atomically: true, encoding: .utf8); chmod(shim.path, 0o755)
        XCTAssertTrue(ClaudeUsage.environment(base: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/fixture"], executable: shim)["PATH"]!
            .split(separator: ":").contains(Substring(shimDirectory.path)))
        XCTAssertEqual(ClaudeUsage.environment(base: ["CLAUDE_CONFIG_DIR": "/fixture"], executable: shim)["CLAUDE_CONFIG_DIR"], "/fixture",
                       "account selection is inherited")
        XCTAssertNotNil(try? claude(["<", claudeInit(), "<", claudeUsage()], executable: shim).finished?.get())
        let lonely = directory.appendingPathComponent("no-node")
        try FileManager.default.createDirectory(at: lonely, withIntermediateDirectories: true)
        let orphan = lonely.appendingPathComponent("claude")
        try "#!/usr/bin/env node-missing-fixture\n".write(to: orphan, atomically: true, encoding: .utf8); chmod(orphan.path, 0o755)
        XCTAssertEqual(claude([], executable: orphan).finished?.failureValue?.failure, .missingClient, "a shim that cannot start")
        XCTAssertEqual(claude([], executable: directory.appendingPathComponent("absent")).finished?.failureValue?.failure, .missingClient)
    }
}
