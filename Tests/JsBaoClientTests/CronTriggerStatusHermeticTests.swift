import XCTest
@testable import JsBaoClient

/// #2803 — a cron trigger's availability is one server-owned `status`.
///
/// Swift decodes strictly, so a wire field that changes name is not a soft
/// break here: `CronTriggerInfo` would fail to decode outright. That makes this
/// suite the parity gate for the phase — the server stops emitting `state` and
/// stops accepting it on `update`, and the client has to move in the same
/// change or every `list`/`get` call throws.
///
/// Server-free (`*HermeticTests`): decoding and encoding are entirely
/// client-side, so the payloads are literals.
final class CronTriggerStatusHermeticTests: XCTestCase {

    private func infoJSON(status: String) -> Data {
        """
        {
          "triggerId": "cron_1",
          "triggerKey": "nightly",
          "displayName": "Nightly",
          "description": null,
          "cron": "0 3 * * *",
          "timezone": "UTC",
          "workflowKey": "reindex",
          "overlapPolicy": "skip",
          "rootInput": null,
          "inputMapping": null,
          "status": "\(status)",
          "lastError": null,
          "lastTriggeredAt": null,
          "lastTriggeredRunId": null,
          "nextFireAt": null,
          "skippedCount": 0,
          "firedCount": 0,
          "createdBy": "admin_1",
          "createdAt": "2026-08-20T00:00:00.000Z",
          "modifiedAt": "2026-08-20T00:00:00.000Z"
        }
        """.data(using: .utf8)!
    }

    func testDecodesTheCanonicalStatusVocabulary() throws {
        for raw in ["active", "inactive", "archived"] {
            let info = try JSONDecoder().decode(
                CronTriggerInfo.self, from: infoJSON(status: raw)
            )
            XCTAssertEqual(info.status.rawValue, raw)
        }
    }

    func testKeepsLastErrorSoTheReasonSurvives() throws {
        // `error_paused` used to carry both "not running" and "because of
        // this". The availability half moved to `status`; the why stays here,
        // and `enable` clears it.
        let json = """
        {
          "triggerId": "cron_1",
          "triggerKey": "nightly",
          "displayName": "Nightly",
          "description": null,
          "cron": "0 3 * * *",
          "timezone": "UTC",
          "workflowKey": "reindex",
          "overlapPolicy": "skip",
          "rootInput": null,
          "inputMapping": null,
          "status": "inactive",
          "lastError": "WORKFLOW_NOT_FOUND",
          "lastTriggeredAt": null,
          "lastTriggeredRunId": null,
          "nextFireAt": null,
          "skippedCount": 0,
          "firedCount": 0,
          "createdBy": "admin_1",
          "createdAt": "2026-08-20T00:00:00.000Z",
          "modifiedAt": "2026-08-20T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(CronTriggerInfo.self, from: json)
        XCTAssertEqual(info.status, .inactive)
        XCTAssertEqual(info.lastError, "WORKFLOW_NOT_FOUND")
    }

    func testUpdateParamsCannotCarryAvailability() throws {
        // The generic update route rejects `state` and never accepts `status`:
        // availability has exactly one writer pair, and a config-shaped write
        // must not change it as a side effect.
        var params = UpdateCronTriggerParams()
        params.displayName = "Renamed"
        let encoded = try JSONEncoder().encode(params)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["state"])
        XCTAssertNil(object["status"])
        XCTAssertEqual(object["displayName"] as? String, "Renamed")
    }
}
