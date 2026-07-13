@testable import CollaborationKit
import Foundation
import Testing

/// Tests the `_ckStringify` shim the macro emits around tool return values.
struct CollaborationResultTests {

    // MARK: - Fixtures

    private struct EncodableRow: Encodable {
        let id: String
        let value: Int
    }

    private struct CustomFormatted: CollaborationResultConvertible {
        let name: String
        func collaborationResultString() -> String { "hi from \(name)" }
    }

    /// Conforms to neither protocol — must throw.
    private struct Opaque {
        let x: Int
    }

    // MARK: - Preferred paths

    @Test
    func customConvertibleTakesPrecedence() throws {
        let out = try _ckStringify(CustomFormatted(name: "world"))
        #expect(out == "hi from world")
    }

    @Test
    func encodableSerialisesAsJSON() throws {
        let out = try _ckStringify(EncodableRow(id: "n1", value: 42))
        // Sorted-keys mode makes the output stable to test.
        #expect(out == #"{"id":"n1","value":42}"#)
    }

    /// Regression: an array of `Encodable` values would throw
    /// `noKnownFormatter("Array<Row>")` at runtime because `value as? any
    /// Encodable` in the unconstrained generic overload can fail across module
    /// boundaries. The `T: Encodable` overload sidesteps the dynamic cast.
    @Test
    func arrayOfEncodableSerialisesAsJSON() throws {
        let rows = [EncodableRow(id: "n1", value: 1), EncodableRow(id: "n2", value: 2)]
        let out = try _ckStringify(rows)
        #expect(out == #"[{"id":"n1","value":1},{"id":"n2","value":2}]"#)
    }

    @Test
    func stringReturnsItself() throws {
        #expect(try _ckStringify("plain") == "plain")
    }

    @Test
    func primitivesRoundTrip() throws {
        #expect(try _ckStringify(true) == "true")
        #expect(try _ckStringify(42) == "42")
        #expect(try _ckStringify(3.5) == "3.5")
    }

    // MARK: - The fix (#39)

    @Test
    func unknownReturnTypeThrowsInsteadOfDebugDescription() {
        #expect(throws: CollaborationResultError.self) {
            try _ckStringify(Opaque(x: 1))
        }
    }

    @Test
    func unknownReturnErrorNamesTheType() {
        do {
            _ = try _ckStringify(Opaque(x: 1))
            Issue.record("expected _ckStringify to throw")
        } catch let error as CollaborationResultError {
            switch error {
            case .noKnownFormatter(let typeName):
                // The associated value should mention the offending type so
                // the developer can immediately see what to conform.
                #expect(typeName.contains("Opaque"))
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}