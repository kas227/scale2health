#if canImport(XCTest)
import XCTest
@testable import Scale2HealthCore

final class PackageSmokeTests: XCTestCase {
    func testCoreChecksAreRepresentedByTheSwiftPMTarget() {
        XCTAssertEqual(BS444Protocol.weightFrameLength, 19)
        XCTAssertEqual(BS444Protocol.featureFrameLength, 19)
    }
}
#endif
