import XCTest
import Security

private struct TestKeychainAPI: LGWebOSKeychainAPI {
    var readStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var data: Data? = Data("test-key".utf8)

    func read(host: String) -> (OSStatus, Data?) {
        XCTAssertFalse(Thread.isMainThread)
        return (readStatus, data)
    }
    func update(host: String, data: Data) -> OSStatus { XCTAssertFalse(Thread.isMainThread); return updateStatus }
    func add(host: String, data: Data) -> OSStatus { XCTAssertFalse(Thread.isMainThread); return addStatus }
    func delete(host: String) -> OSStatus { XCTAssertFalse(Thread.isMainThread); return deleteStatus }
}

final class LGWebOSKeyStoreTests: XCTestCase {
    func testMissingKeyAndDeleteAreNormal() async throws {
        let store = LGWebOSKeychainStore(api: TestKeychainAPI(readStatus: errSecItemNotFound, deleteStatus: errSecItemNotFound))
        let key = try await store.read(host: "test")
        XCTAssertNil(key)
        try await store.delete(host: "test")
    }

    func testReadSuccessRunsOffMainThread() async throws {
        let key = try await LGWebOSKeychainStore(api: TestKeychainAPI()).read(host: "test")
        XCTAssertEqual(key, "test-key")
    }

    func testReadFailureAndInvalidDataAreNotMissingKeys() async {
        for api in [TestKeychainAPI(readStatus: errSecAuthFailed), TestKeychainAPI(data: nil)] {
            do {
                _ = try await LGWebOSKeychainStore(api: api).read(host: "test")
                XCTFail("Expected read error")
            } catch { XCTAssertTrue(error is LGWebOSKeychainError) }
        }
    }

    func testSaveUpdateAndAddErrorsPropagate() async {
        for api in [TestKeychainAPI(updateStatus: errSecAuthFailed),
                    TestKeychainAPI(updateStatus: errSecItemNotFound, addStatus: errSecAuthFailed)] {
            do {
                try await LGWebOSKeychainStore(api: api).save("test-key", host: "test")
                XCTFail("Expected save error")
            } catch { XCTAssertEqual((error as? LGWebOSKeychainError)?.status, errSecAuthFailed) }
        }
    }

    func testSuccessfulUpdateAndAddRunOffMainThread() async throws {
        try await LGWebOSKeychainStore(api: TestKeychainAPI()).save("test-key", host: "test")
        try await LGWebOSKeychainStore(api: TestKeychainAPI(updateStatus: errSecItemNotFound)).save("test-key", host: "test")
    }

    func testDeleteFailurePropagates() async {
        do {
            try await LGWebOSKeychainStore(api: TestKeychainAPI(deleteStatus: errSecAuthFailed)).delete(host: "test")
            XCTFail("Expected delete error")
        } catch { XCTAssertEqual((error as? LGWebOSKeychainError)?.status, errSecAuthFailed) }
    }
}
