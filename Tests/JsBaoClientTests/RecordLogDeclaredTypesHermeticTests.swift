import XCTest
@testable import JsBaoClient

/// #5020 behavior 18 and E6 (the Swift half) — a typed db3's declarations
/// judged on the device, the twin of js-bao's `declared-types`.
///
/// `recordLogDeclaredTypeProblem` answers what the room's
/// `RecordType.entryProblem` answers: the table below is the room's own
/// answer for each case (code and message, verbatim, `null` where it takes
/// the entry), generated from `src/rooms/record-room/type.ts` over the same
/// declarations. On a binding holding the declarations, `codegen.save`,
/// `increment`, a `transact` and a save of a model the type does not declare
/// throw the room's code and message, are reported as a
/// `Db3WriteRefusedEvent` with `scope: "local"`, and commit nothing; a
/// binding holding none judges nothing.
final class RecordLogDeclaredTypesHermeticTests: XCTestCase {

    /// The room's answers: `{ declarations, cases: [{ label, mutations, expected }] }`.
    private static let roomAnswers = #"""
{
 "declarations": {"Account": {"name": "string", "balance": "number", "open": "boolean", "owner": "id", "closedAt": "date", "tags": "stringset"}, "Draft": {}},
 "cases": [
  {"label": "create name=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": ""}}], "expected": null},
  {"label": "create name=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "2026-02-30"}}], "expected": null},
  {"label": "create name=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "not-a-date"}}], "expected": null},
  {"label": "create name=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "10/29/2026"}}], "expected": null},
  {"label": "create name=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "October 29, 2026"}}], "expected": null},
  {"label": "create name=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "2026-10-29"}}], "expected": null},
  {"label": "create name=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "2026-10-29T12:00:00.000Z"}}], "expected": null},
  {"label": "create name=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "2026-10-29 12:00:00"}}], "expected": null},
  {"label": "create name=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": 1793000000000}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote number"}},
  {"label": "create name=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": 0}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote number"}},
  {"label": "create name=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": 8640000000000001}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote number"}},
  {"label": "create name=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": true}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote boolean"}},
  {"label": "create name=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": null}}], "expected": null},
  {"label": "create name=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote an array"}},
  {"label": "create name={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote object"}},
  {"label": "create name=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": null},
  {"label": "create balance=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": ""}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "2026-02-30"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "not-a-date"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "10/29/2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "October 29, 2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "2026-10-29"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "2026-10-29T12:00:00.000Z"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "2026-10-29 12:00:00"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create balance=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": 1793000000000}}], "expected": null},
  {"label": "create balance=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": 0}}], "expected": null},
  {"label": "create balance=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": 8640000000000001}}], "expected": null},
  {"label": "create balance=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": true}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote boolean"}},
  {"label": "create balance=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": null}}], "expected": null},
  {"label": "create balance=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote an array"}},
  {"label": "create balance={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote object"}},
  {"label": "create balance=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"balance": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "create open=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": ""}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "2026-02-30"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "not-a-date"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "10/29/2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "October 29, 2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "2026-10-29"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "2026-10-29T12:00:00.000Z"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "2026-10-29 12:00:00"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create open=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": 1793000000000}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote number"}},
  {"label": "create open=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": 0}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote number"}},
  {"label": "create open=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": 8640000000000001}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote number"}},
  {"label": "create open=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": true}}], "expected": null},
  {"label": "create open=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": null}}], "expected": null},
  {"label": "create open=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote an array"}},
  {"label": "create open={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote object"}},
  {"label": "create open=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"open": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"open\" is declared boolean; the entry wrote string"}},
  {"label": "create owner=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": ""}}], "expected": null},
  {"label": "create owner=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "2026-02-30"}}], "expected": null},
  {"label": "create owner=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "not-a-date"}}], "expected": null},
  {"label": "create owner=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "10/29/2026"}}], "expected": null},
  {"label": "create owner=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "October 29, 2026"}}], "expected": null},
  {"label": "create owner=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "2026-10-29"}}], "expected": null},
  {"label": "create owner=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "2026-10-29T12:00:00.000Z"}}], "expected": null},
  {"label": "create owner=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "2026-10-29 12:00:00"}}], "expected": null},
  {"label": "create owner=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": 1793000000000}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote number"}},
  {"label": "create owner=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": 0}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote number"}},
  {"label": "create owner=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": 8640000000000001}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote number"}},
  {"label": "create owner=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": true}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote boolean"}},
  {"label": "create owner=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": null}}], "expected": null},
  {"label": "create owner=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote an array"}},
  {"label": "create owner={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"owner\" is declared id; the entry wrote object"}},
  {"label": "create owner=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"owner": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": null},
  {"label": "create closedAt=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": ""}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create closedAt=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "2026-02-30"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create closedAt=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "not-a-date"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create closedAt=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "10/29/2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create closedAt=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "October 29, 2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create closedAt=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "2026-10-29"}}], "expected": null},
  {"label": "create closedAt=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "2026-10-29T12:00:00.000Z"}}], "expected": null},
  {"label": "create closedAt=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "2026-10-29 12:00:00"}}], "expected": null},
  {"label": "create closedAt=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": 1793000000000}}], "expected": null},
  {"label": "create closedAt=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": 0}}], "expected": null},
  {"label": "create closedAt=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": 8640000000000001}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote number"}},
  {"label": "create closedAt=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": true}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote boolean"}},
  {"label": "create closedAt=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": null}}], "expected": null},
  {"label": "create closedAt=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote an array"}},
  {"label": "create closedAt={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote object"}},
  {"label": "create closedAt=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"closedAt": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"}},
  {"label": "create tags=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": ""}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "2026-02-30"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "not-a-date"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "10/29/2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "October 29, 2026"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "2026-10-29"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "2026-10-29T12:00:00.000Z"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "2026-10-29 12:00:00"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create tags=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": 1793000000000}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (number)"}},
  {"label": "create tags=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": 0}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (number)"}},
  {"label": "create tags=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": 8640000000000001}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (number)"}},
  {"label": "create tags=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": true}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (boolean)"}},
  {"label": "create tags=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": null}}], "expected": null},
  {"label": "create tags=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": ["a"]}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (an array)"}},
  {"label": "create tags={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": {"a": 1}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (object)"}},
  {"label": "create tags=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"tags": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (string)"}},
  {"label": "create undeclared=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": ""}}], "expected": null},
  {"label": "create undeclared=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "2026-02-30"}}], "expected": null},
  {"label": "create undeclared=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "not-a-date"}}], "expected": null},
  {"label": "create undeclared=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "10/29/2026"}}], "expected": null},
  {"label": "create undeclared=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "October 29, 2026"}}], "expected": null},
  {"label": "create undeclared=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "2026-10-29"}}], "expected": null},
  {"label": "create undeclared=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "2026-10-29T12:00:00.000Z"}}], "expected": null},
  {"label": "create undeclared=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "2026-10-29 12:00:00"}}], "expected": null},
  {"label": "create undeclared=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": 1793000000000}}], "expected": null},
  {"label": "create undeclared=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": 0}}], "expected": null},
  {"label": "create undeclared=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": 8640000000000001}}], "expected": null},
  {"label": "create undeclared=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": true}}], "expected": null},
  {"label": "create undeclared=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": null}}], "expected": null},
  {"label": "create undeclared=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": ["a"]}}], "expected": null},
  {"label": "create undeclared={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": {"a": 1}}}], "expected": null},
  {"label": "create undeclared=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"undeclared": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": null},
  {"label": "create id=\"\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": ""}}], "expected": null},
  {"label": "create id=\"2026-02-30\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "2026-02-30"}}], "expected": null},
  {"label": "create id=\"not-a-date\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "not-a-date"}}], "expected": null},
  {"label": "create id=\"10/29/2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "10/29/2026"}}], "expected": null},
  {"label": "create id=\"October 29, 2026\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "October 29, 2026"}}], "expected": null},
  {"label": "create id=\"2026-10-29\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "2026-10-29"}}], "expected": null},
  {"label": "create id=\"2026-10-29T12:00:00.000Z\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "2026-10-29T12:00:00.000Z"}}], "expected": null},
  {"label": "create id=\"2026-10-29 12:00:00\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "2026-10-29 12:00:00"}}], "expected": null},
  {"label": "create id=1793000000000", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": 1793000000000}}], "expected": null},
  {"label": "create id=0", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": 0}}], "expected": null},
  {"label": "create id=8640000000000001", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": 8640000000000001}}], "expected": null},
  {"label": "create id=true", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": true}}], "expected": null},
  {"label": "create id=null", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": null}}], "expected": null},
  {"label": "create id=[\"a\"]", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": ["a"]}}], "expected": null},
  {"label": "create id={\"a\":1}", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": {"a": 1}}}], "expected": null},
  {"label": "create id=\"01JA5020OWNERXXXXXXXXXXXXX\"", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"id": "01JA5020OWNERXXXXXXXXXXXXX"}}], "expected": null},
  {"label": "patch with a set delta on a scalar", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "patch", "fields": {}, "stringSetDeltas": {"name": {"a": true}}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote a string-set change"}},
  {"label": "patch with a set delta on a string set", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "patch", "fields": {}, "stringSetDeltas": {"tags": {"a": true, "b": false}}}], "expected": null},
  {"label": "increment of a date field", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "increment", "fields": {"closedAt": 1}}], "expected": null},
  {"label": "increment of a string field", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "increment", "fields": {"name": 1}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"name\" is declared string; the entry wrote number"}},
  {"label": "increment of a string set", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "increment", "fields": {"tags": 1}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "m: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"tags\" is declared stringset; the entry wrote a scalar (number)"}},
  {"label": "delete", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "delete"}], "expected": null},
  {"label": "delete of an undeclared model", "mutations": [{"model": "Ledger", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "delete"}], "expected": {"code": "DB3_MODEL_NOT_DECLARED", "message": "m: Ledger is not a model of the db3's type ledger; it declares Account, Draft"}},
  {"label": "create of an undeclared model", "mutations": [{"model": "Ledger", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "x"}}], "expected": {"code": "DB3_MODEL_NOT_DECLARED", "message": "m: Ledger is not a model of the db3's type ledger; it declares Account, Draft"}},
  {"label": "a model with no typed field", "mutations": [{"model": "Draft", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"anything": 1}}], "expected": null},
  {"label": "also[0] breaks a kind", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "ok"}}, {"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "patch", "fields": {"balance": "3"}}], "expected": {"code": "DOCUMENT_ENTRY_INVALID", "message": "also[0]: Account id=01JA5020CHECKERXXXXXXXXXXX: field \"balance\" is declared number; the entry wrote string"}},
  {"label": "also[1] names an undeclared model", "mutations": [{"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {"name": "ok"}}, {"model": "Account", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "patch", "fields": {"name": "ok"}}, {"model": "Ledger", "id": "01JA5020CHECKERXXXXXXXXXXX", "kind": "create", "fields": {}}], "expected": {"code": "DB3_MODEL_NOT_DECLARED", "message": "also[1]: Ledger is not a model of the db3's type ledger; it declares Account, Draft"}}
 ]
}
"""#

    func testTheCheckerAnswersWhatTheRoomAnswersForEveryCase() throws {
        let parsed = try XCTUnwrap(JSONValue(jsonText: Self.roomAnswers)?.objectValue)
        let declarations = try XCTUnwrap(parsed["declarations"]?.objectValue).mapValues { kinds in
            (kinds.objectValue ?? [:]).compactMapValues(\.stringValue)
        }
        XCTAssertEqual(declarations, [
            "Account": ["name": "string", "balance": "number", "open": "boolean", "owner": "id", "closedAt": "date", "tags": "stringset"],
            "Draft": [:],
        ])
        let type = RecordLogDeclaredType(name: "ledger", models: declarations)
        let cases = try XCTUnwrap(parsed["cases"]?.arrayValue)
        XCTAssertGreaterThan(cases.count, 100)
        var refused = 0
        for item in cases {
            let object = try XCTUnwrap(item.objectValue)
            let label = object["label"]?.stringValue ?? "?"
            let mutations = try (object["mutations"]?.arrayValue ?? []).map { try XCTUnwrap(RecordLogMutation(json: $0), label) }
            let problem = recordLogDeclaredTypeProblem(mutations, type)
            if let expected = object["expected"]?.objectValue {
                refused += 1
                XCTAssertEqual(problem?.code.rawValue, expected["code"]?.stringValue, label)
                XCTAssertEqual(problem?.message, expected["message"]?.stringValue, label)
            } else {
                XCTAssertNil(problem, label)
            }
        }
        XCTAssertGreaterThan(refused, 40)
    }

    func testANonFiniteNumberIsNoDateAndATypeDeclaringNoModelTakesEveryModel() {
        let type = RecordLogDeclaredType(name: "ledger", models: ["Account": ["closedAt": "date"]])
        let nan = RecordLogMutation(model: "Account", id: "a", kind: .create, fields: ["closedAt": .number(.nan)])
        XCTAssertEqual(
            recordLogDeclaredTypeProblem([nan], type)?.message, #"m: Account id=a: field "closedAt" is declared date; the entry wrote number"#
        )
        let anything = RecordLogMutation(model: "Anything", id: "a", kind: .create, fields: ["x": 1])
        XCTAssertNil(recordLogDeclaredTypeProblem([anything], RecordLogDeclaredType(name: "ledger", models: [:])))
        for value: Double in [0, 1_793_000_000_000, -8.64e15, 8.64e15] { XCTAssertTrue(recordLogIsRepresentableDate(.number(value)), "\(value)") }
        for value: Double in [.nan, .infinity, 8.64e15 + 1] { XCTAssertFalse(recordLogIsRepresentableDate(.number(value)), "\(value)") }
    }

    /// The room's `isRepresentableDate` answers, copied verbatim, for the
    /// calendar and clock edges (5020-C002): the proleptic Gregorian calendar
    /// across the 1582 cutover and year zero, and hour 24 only at exactly
    /// midnight, a fraction of zeros included.
    func testTheDateRuleIsTheRoomsAtTheCalendarAndClockEdges() {
        let roomAnswers: [(String, Bool)] = [
            ("1582-10-10", true), ("1582-10-04", true), ("1582-10-15", true),
            ("0000-01-01", true), ("0000-02-29", true), ("0001-02-29", false), ("0004-02-29", true),
            ("0100-02-29", false), ("0400-02-29", true), ("1900-02-29", false), ("2000-02-29", true),
            ("2026-10-29T24:00:00Z", true), ("2026-10-29T24:00:00.000Z", true), ("2026-10-29T24:00:00.001Z", false),
            ("2026-10-29T24:00:00.0Z", true), ("2026-10-29T24:00:00.0000Z", true), ("2026-10-29T24:00:00.0001Z", false),
            ("2026-10-29T24:00Z", true), ("2026-10-29T24:01Z", false), ("2026-10-29T24:00:01Z", false),
            ("2026-10-29T24:00:00", true), ("2026-12-31T24:00:00Z", true), ("2026-10-29T23:59:60Z", false),
            ("2026-10-29T10:00:00+24:00", false), ("2026-10-29T10:00:00+23:59", true), ("2026-10-29T10:00:00+0530", true),
            ("2026-10-29T10:00:00+05:60", false), ("2026-10-29 10:00:00", true), ("2026-10-29T10:00:00.123456789Z", true),
            ("9999-12-31T23:59:59.999Z", true), ("2026-00-10", false), ("2026-13-01", false), ("2026-01-00", false),
            ("2026-01-32", false), ("2026-10-29T25:00:00Z", false), ("2026-10-29T10:60:00Z", false),
            ("2026-10-29T24:00:00+01:00", true), ("2026-10-29T10:00:00-00:00", true), ("2026-10-29T24:00:00.000", true),
        ]
        for (value, room) in roomAnswers {
            XCTAssertEqual(recordLogIsRepresentableDate(.string(value)), room, value)
        }
    }

    // MARK: - Saves on a binding holding the declarations

    private static let db3Id = "01JD5020KINDSSW1FTXXXXXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static let account = PrimitiveSchema(
        name: "Account",
        fields: [
            "id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string),
            "closedAt": FieldDescriptor(type: .date), "memo": FieldDescriptor(type: .date),
        ]
    )
    private static let ledger = PrimitiveSchema(name: "Ledger", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)])

    /// A client with the db3 bound, and the room's answer for its type given to its store (or none).
    private func client(declared: Bool) async throws -> (JsBaoClient, RecordLogDocumentBinding, LockedBox<[Db3WriteRefusedEvent]>, EventSubscription) {
        let directory = NSTemporaryDirectory() + "/db3-declared-types-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-declared-types-5020",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.account, Self.ledger])
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        binding.createdLocally = true
        if declared {
            try binding.setState(type: .typed(
                name: "ledger", hash: "h1", models: ["Account": ["name": "string", "closedAt": "date"], "Draft": [:]]
            ))
        }
        let heard = LockedBox<[Db3WriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in heard.withValue { $0.append(event) } }
        return (client, binding, heard, subscription)
    }

    private func refusal(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> JsBaoError? {
        do {
            try await body()
            XCTFail("the write should be refused", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    func testASaveFailingADeclaredKindThrowsTheRoomsWordsAndCommitsNothing() async throws {
        let (client, binding, heard, subscription) = try await client(declared: true)
        let error = await refusal {
            _ = try client.codegen.save(Self.account, id: "a1", values: ["name": .string("a"), "closedAt": .string("")], in: Self.db3Id)
        }
        XCTAssertEqual(error?.code, .documentEntryInvalid)
        XCTAssertEqual(error?.message, #"m: Account id=a1: field "closedAt" is declared date; the entry wrote a string that is not an ISO date"#)
        XCTAssertEqual(error?.details?["scope"], "local")
        XCTAssertEqual(try binding.refreshMarks().pending, 0)
        XCTAssertNil(try binding.store.read(model: "Account", id: "a1"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(heard.value.count, 1)
        XCTAssertEqual(heard.value.first?.error.code, .documentEntryInvalid)
        withExtendedLifetime(subscription) {}
    }

    func testAnIsoDateAndAFieldTheTypeDoesNotDeclareCommit() async throws {
        let (client, binding, heard, subscription) = try await client(declared: true)
        _ = try client.codegen.save(Self.account, id: "a1", values: ["name": .string("a"), "closedAt": .string("2026-10-29T12:00:00.000Z")], in: Self.db3Id)
        _ = try client.codegen.save(Self.account, id: "a2", values: ["name": .string("b"), "memo": .string("")], in: Self.db3Id)
        XCTAssertEqual(try binding.refreshMarks().pending, 2)
        XCTAssertEqual(heard.value.count, 0)
        withExtendedLifetime(subscription) {}
    }

    func testAnIncrementTheDeclarationsRefuseAndAnUndeclaredModelThrowTheRoomsWords() async throws {
        let (client, binding, heard, subscription) = try await client(declared: true)
        _ = try client.codegen.save(Self.account, id: "a1", values: ["name": .string("a")], in: Self.db3Id)
        let increment = await refusal {
            _ = try await client.codegen.increment(Self.account, id: "a1", fields: ["name": 1], in: Self.db3Id)
        }
        XCTAssertEqual(increment?.code, .documentEntryInvalid)
        XCTAssertEqual(increment?.message, #"m: Account id=a1: field "name" is declared string; the entry wrote number"#)
        let undeclared = await refusal {
            _ = try client.codegen.save(Self.ledger, id: "l1", values: ["name": .string("x")], in: Self.db3Id)
        }
        XCTAssertEqual(undeclared?.code, .db3ModelNotDeclared)
        XCTAssertEqual(undeclared?.message, "m: Ledger is not a model of the db3's type ledger; it declares Account, Draft")
        XCTAssertEqual(undeclared?.details?["scope"], "local")
        XCTAssertEqual(try binding.refreshMarks().pending, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(heard.value.map(\.error.code), [.documentEntryInvalid, .db3ModelNotDeclared])
        withExtendedLifetime(subscription) {}
    }

    func testATransactionIsJudgedWholeWithEachRecordsPlace() async throws {
        let (client, binding, _, subscription) = try await client(declared: true)
        let error = await refusal {
            try binding.transaction {
                _ = try client.codegen.save(Self.account, id: "a1", values: ["name": .string("first")], in: Self.db3Id)
                _ = try client.codegen.save(Self.account, id: "a2", values: ["name": .string("second"), "closedAt": .string("not-a-date")], in: Self.db3Id)
            }
        }
        XCTAssertEqual(error?.code, .documentEntryInvalid)
        XCTAssertEqual(error?.message, #"also[0]: Account id=a2: field "closedAt" is declared date; the entry wrote a string that is not an ISO date"#)
        XCTAssertEqual(try binding.refreshMarks().pending, 0)
        withExtendedLifetime(subscription) {}
    }

    func testABindingHoldingNoDeclarationsJudgesNothing() async throws {
        let (client, binding, heard, subscription) = try await client(declared: false)
        XCTAssertNil(binding.declaredType)
        _ = try client.codegen.save(Self.account, id: "a1", values: ["name": .string("a"), "closedAt": .string("")], in: Self.db3Id)
        _ = try client.codegen.save(Self.ledger, id: "l1", values: ["name": .string("x")], in: Self.db3Id)
        XCTAssertEqual(try binding.refreshMarks().pending, 2)
        XCTAssertEqual(heard.value.count, 0)
        withExtendedLifetime(subscription) {}
    }
}
