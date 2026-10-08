import XCTest
@testable import SampleCore

final class GreetingTests: XCTestCase {
    func testGreeting() { XCTAssertEqual(greet("tCode"),"Hello, tCode!") }
}
