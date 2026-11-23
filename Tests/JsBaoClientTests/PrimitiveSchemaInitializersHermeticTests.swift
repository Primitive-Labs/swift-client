import XCTest
@testable import JsBaoClient

/// #6023 — `PrimitiveSchema` keeps the four-argument initializer every
/// earlier generated model calls, beside the one that takes a renamed
/// model's `fieldNames`. Code compiled against an earlier client keeps
/// building and linking.
final class PrimitiveSchemaInitializersHermeticTests: XCTestCase {

    func testTheFourArgumentInitializerIsStillDeclaredAndRenamesNothing() {
        let make: (
            String, [String: FieldDescriptor], [String: ConstraintDescriptor], [String: RelationshipDescriptor]
        ) -> PrimitiveSchema = PrimitiveSchema.init(name:fields:constraints:relationships:)
        let schema = make("tasks", ["title": FieldDescriptor(type: .string)], [:], [:])
        XCTAssertEqual(schema.name, "tasks")
        XCTAssertEqual(schema.fieldNames, [:])
        XCTAssertEqual(schema.fieldNameTypes, [])
    }

    func testTheRenamedModelInitializerCarriesTheMapAndItsTypes() {
        let make: (
            String, [String: FieldDescriptor], [String: ConstraintDescriptor], [String: RelationshipDescriptor],
            [String: String], [String]
        ) -> PrimitiveSchema = PrimitiveSchema.init(name:fields:constraints:relationships:fieldNames:fieldNameTypes:)
        let schema = make("tasks", ["due": FieldDescriptor(type: .number)], [:], [:], ["dueAt": "due"], ["workspace"])
        XCTAssertEqual(schema.fieldNames, ["dueAt": "due"])
        XCTAssertEqual(schema.fieldNameTypes, ["workspace"])
    }

    func testAShortCallStillReadsAsAModelThatRenamesNothing() {
        let schema = PrimitiveSchema(name: "tasks", fields: ["title": FieldDescriptor(type: .string)])
        XCTAssertEqual(schema.fieldNames, [:])
        XCTAssertEqual(schema.fieldNameTypes, [])
    }
}
