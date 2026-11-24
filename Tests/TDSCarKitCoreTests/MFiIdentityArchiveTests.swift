import XCTest
@testable import TDSCarKitCore

final class MFiIdentityArchiveTests: XCTestCase {
    private var stored: Data { Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2J0ZXN0LWNoYWluUEsDBBQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlcnRlc3QtbGVhZlBLAwQUAAAAAAAAACFceR/bMggAAAAIAAAAHQAAAFBheWxvYWQvVGVzdC5hcHAvcHJpdmF0ZS54OTYzdGVzdC1rZXlQSwECFAMUAAAAAAAAACFcCxI2/AoAAAAKAAAAIAAAAAAAAAAAAAAAgAEAAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2JQSwECFAMUAAAAAAAAACFch5n0QAkAAAAJAAAAGQAAAAAAAAAAAAAAgAFIAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlclBLAQIUAxQAAAAAAAAAIVx5H9syCAAAAAgAAAAdAAAAAAAAAAAAAACAAYgAAABQYXlsb2FkL1Rlc3QuYXBwL3ByaXZhdGUueDk2M1BLBQYAAAAAAwADAOAAAADLAAAAAAA=")! }
    private var deflated: Data { Data(base64Encoded: "UEsDBBQAAAAIAAAAIVwLEjb8DAAAAAoAAAAgAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2IrSS0u0U3OSMzMAwBQSwMEFAAAAAgAAAAhXIeZ9EALAAAACQAAABkAAABQYXlsb2FkL1Rlc3QuYXBwL2xlYWYuY2VyK0ktLtHNSU1MAwBQSwMEFAAAAAgAAAAhXHkf2zIKAAAACAAAAB0AAABQYXlsb2FkL1Rlc3QuYXBwL3ByaXZhdGUueDk2MytJLS7RzU6tBABQSwECFAMUAAAACAAAACFcCxI2/AwAAAAKAAAAIAAAAAAAAAAAAAAAgAEAAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2JQSwECFAMUAAAACAAAACFch5n0QAsAAAAJAAAAGQAAAAAAAAAAAAAAgAFKAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlclBLAQIUAxQAAAAIAAAAIVx5H9syCgAAAAgAAAAdAAAAAAAAAAAAAACAAYwAAABQYXlsb2FkL1Rlc3QuYXBwL3ByaXZhdGUueDk2M1BLBQYAAAAAAwADAOAAAADRAAAAAAA=")! }
    private var missing: Data { Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2J0ZXN0LWNoYWluUEsDBBQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlcnRlc3QtbGVhZlBLAQIUAxQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAAAAAAAAAAACAAQAAAABQYXlsb2FkL1Rlc3QuYXBwL2NlcnRpZmljYXRlLnA3YlBLAQIUAxQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAAAAAAAAAAACAAUgAAABQYXlsb2FkL1Rlc3QuYXBwL2xlYWYuY2VyUEsFBgAAAAACAAIAlQAAAIgAAAAAAA==")! }
    private var duplicate: Data { Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2J0ZXN0LWNoYWluUEsDBBQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlcnRlc3QtbGVhZlBLAwQUAAAAAAAAACFceR/bMggAAAAIAAAAHQAAAFBheWxvYWQvVGVzdC5hcHAvcHJpdmF0ZS54OTYzdGVzdC1rZXlQSwMEFAAAAAAA52B4XRuBRxIJAAAACQAAABkAAABQYXlsb2FkL1Rlc3QuYXBwL2xlYWYuY2VyZHVwbGljYXRlUEsBAhQDFAAAAAAAAAAhXAsSNvwKAAAACgAAACAAAAAAAAAAAAAAAIABAAAAAFBheWxvYWQvVGVzdC5hcHAvY2VydGlmaWNhdGUucDdiUEsBAhQDFAAAAAAAAAAhXIeZ9EAJAAAACQAAABkAAAAAAAAAAAAAAIABSAAAAFBheWxvYWQvVGVzdC5hcHAvbGVhZi5jZXJQSwECFAMUAAAAAAAAACFceR/bMggAAAAIAAAAHQAAAAAAAAAAAAAAgAGIAAAAUGF5bG9hZC9UZXN0LmFwcC9wcml2YXRlLng5NjNQSwECFAMUAAAAAADnYHhdG4FHEgkAAAAJAAAAGQAAAAAAAAAAAAAAgAHLAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlclBLBQYAAAAABAAEACcBAAALAQAAAAA=")! }
    private var multiple: Data { Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAUGF5bG9hZC9UZXN0LmFwcC9jZXJ0aWZpY2F0ZS5wN2J0ZXN0LWNoYWluUEsDBBQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAUGF5bG9hZC9UZXN0LmFwcC9sZWFmLmNlcnRlc3QtbGVhZlBLAwQUAAAAAAAAACFceR/bMggAAAAIAAAAHQAAAFBheWxvYWQvVGVzdC5hcHAvcHJpdmF0ZS54OTYzdGVzdC1rZXlQSwMEFAAAAAAA52B4XQsSNvwKAAAACgAAACEAAABQYXlsb2FkL090aGVyLmFwcC9jZXJ0aWZpY2F0ZS5wN2J0ZXN0LWNoYWluUEsDBBQAAAAAAOdgeF2HmfRACQAAAAkAAAAaAAAAUGF5bG9hZC9PdGhlci5hcHAvbGVhZi5jZXJ0ZXN0LWxlYWZQSwMEFAAAAAAA52B4XXkf2zIIAAAACAAAAB4AAABQYXlsb2FkL090aGVyLmFwcC9wcml2YXRlLng5NjN0ZXN0LWtleVBLAQIUAxQAAAAAAAAAIVwLEjb8CgAAAAoAAAAgAAAAAAAAAAAAAACAAQAAAABQYXlsb2FkL1Rlc3QuYXBwL2NlcnRpZmljYXRlLnA3YlBLAQIUAxQAAAAAAAAAIVyHmfRACQAAAAkAAAAZAAAAAAAAAAAAAACAAUgAAABQYXlsb2FkL1Rlc3QuYXBwL2xlYWYuY2VyUEsBAhQDFAAAAAAAAAAhXHkf2zIIAAAACAAAAB0AAAAAAAAAAAAAAIABiAAAAFBheWxvYWQvVGVzdC5hcHAvcHJpdmF0ZS54OTYzUEsBAhQDFAAAAAAA52B4XQsSNvwKAAAACgAAACEAAAAAAAAAAAAAAIABywAAAFBheWxvYWQvT3RoZXIuYXBwL2NlcnRpZmljYXRlLnA3YlBLAQIUAxQAAAAAAOdgeF2HmfRACQAAAAkAAAAaAAAAAAAAAAAAAACAARQBAABQYXlsb2FkL090aGVyLmFwcC9sZWFmLmNlclBLAQIUAxQAAAAAAOdgeF15H9syCAAAAAgAAAAeAAAAAAAAAAAAAACAAVUBAABQYXlsb2FkL090aGVyLmFwcC9wcml2YXRlLng5NjNQSwUGAAAAAAYABgDDAQAAmQEAAAAA")! }

    private func centralOffset(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        return (0..<(bytes.count - 3)).first { Array(bytes[$0..<($0 + 4)]) == [0x50, 0x4b, 1, 2] }!
    }

    func testStoredIdentityFilesAreExtracted() throws {
        let files = try MFiIdentityArchive.extract(from: stored)
        XCTAssertEqual(files.certificateChain, Data("test-chain".utf8))
        XCTAssertEqual(files.leafCertificate, Data("test-leaf".utf8))
        XCTAssertEqual(files.privateKey, Data("test-key".utf8))
    }

    func testDeflatedIdentityFilesAreExtracted() throws {
        let files = try MFiIdentityArchive.extract(from: deflated)
        XCTAssertEqual(files.certificateChain, Data("test-chain".utf8))
        XCTAssertEqual(files.leafCertificate, Data("test-leaf".utf8))
        XCTAssertEqual(files.privateKey, Data("test-key".utf8))
    }

    func testMissingDuplicateAndMultipleIdentitiesAreRejected() {
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: missing))
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: duplicate))
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: multiple))
    }

    func testCorruptFileIsRejectedByCRC() {
        var archive = stored
        archive[65] ^= 1
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
    }

    func testOversizedExpandedEntryIsRejectedBeforeAllocation() {
        var archive = stored
        let offset = centralOffset(archive)
        archive.replaceSubrange((offset + 24)..<(offset + 28), with: [1, 0, 1, 0]) // 65,537 bytes
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
    }

    func testEncryptedAndUnsupportedCompressionAreRejected() {
        var archive = stored
        let offset = centralOffset(archive)
        archive[offset + 8] |= 1
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
        archive = stored
        archive[offset + 10] = 99
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
    }

    func testCentralOffsetAndTruncatedArchivesAreRejected() {
        var archive = stored
        let end = archive.count - 22
        archive.replaceSubrange((end + 16)..<(end + 20), with: [0xff, 0xff, 0xff, 0x7f])
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: stored.prefix(20)))
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: stored.dropLast()))
    }

    func testPartialOrEmptySelectedFilesAreRejected() {
        XCTAssertThrowsError(try MFiIdentityFiles(files: ["leaf.cer": Data([1])]))
        XCTAssertThrowsError(try MFiIdentityFiles(files: [
            "certificate.p7b": Data([1]), "leaf.cer": Data([2]), "private.x963": Data()
        ]))
    }

    func testStoredEntryPathMustMatchCentralDirectory() {
        var archive = stored
        archive[30] = 0x58
        XCTAssertThrowsError(try MFiIdentityArchive.extract(from: archive))
    }
}
