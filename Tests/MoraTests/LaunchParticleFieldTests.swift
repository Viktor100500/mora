import XCTest
@testable import Mora

final class LaunchParticleFieldTests: XCTestCase {
    func testNearbyConnectionsAreBrighterAndDistantConnectionsDisappear() {
        let close = LaunchParticleField.connectionOpacity(distance: 20, limit: 180)
        let far = LaunchParticleField.connectionOpacity(distance: 140, limit: 180)
        XCTAssertGreaterThan(close, far)
        XCTAssertGreaterThan(far, 0)
        XCTAssertEqual(LaunchParticleField.connectionOpacity(distance: 180, limit: 180), 0)
        XCTAssertEqual(LaunchParticleField.connectionOpacity(distance: 200, limit: 180), 0)
        XCTAssertEqual(LaunchParticleField.connectionOpacity(distance: 0, limit: 0), 0)
    }

    func testCursorRepelsParticleAndItReturnsToItsNormalDrift() throws {
        var field = LaunchParticleField(size: CGSize(width: 1320, height: 900))
        let original = try XCTUnwrap(field.particles.first)
        var undisturbed = field
        let cursor = CGPoint(x: original.position.x - 35, y: original.position.y)
        field.advance(by: 1.0 / 60, cursor: cursor)
        undisturbed.advance(by: 1.0 / 60, cursor: nil)
        XCTAssertGreaterThan(field.particles[0].velocity.dx, undisturbed.particles[0].velocity.dx)
        XCTAssertGreaterThan(field.particles[0].position.x, undisturbed.particles[0].position.x)

        let disturbedSpeed = abs(field.particles[0].velocity.dx - original.drift.dx)
        for _ in 0..<12 { field.advance(by: 1.0 / 60, cursor: nil) }
        XCTAssertLessThan(abs(field.particles[0].velocity.dx - original.drift.dx), disturbedSpeed)
        XCTAssertEqual(field.particles[0].velocity.dy, original.drift.dy, accuracy: 0.001)
    }

    func testPointerDirectlyOnParticleAndLongFramePauseStayFiniteAndBounded() throws {
        var field = LaunchParticleField(size: CGSize(width: 1040, height: 700))
        let original = try XCTUnwrap(field.particles.first)
        field.advance(by: 60, cursor: original.position)
        let moved = field.particles[0]
        XCTAssertTrue(moved.position.x.isFinite && moved.position.y.isFinite)
        XCTAssertLessThanOrEqual(hypot(moved.position.x - original.position.x, moved.position.y - original.position.y), 10.67)
        for _ in 0..<600 { field.advance(by: 1.0 / 60, cursor: CGPoint(x: 520, y: 350)) }
        for particle in field.particles {
            XCTAssertTrue((-16...1056).contains(particle.position.x))
            XCTAssertTrue((-16...716).contains(particle.position.y))
            XCTAssertLessThanOrEqual(hypot(particle.velocity.dx, particle.velocity.dy), 320.01)
        }
    }

    func testResizeScalesExistingPositionsAndCapsWorkForLargeWindows() throws {
        var field = LaunchParticleField(size: CGSize(width: 1040, height: 700))
        let original = try XCTUnwrap(field.particles.first)
        field.resize(to: CGSize(width: 2080, height: 1400))
        XCTAssertEqual(field.particles[0].position.x, original.position.x * 2, accuracy: 0.001)
        XCTAssertEqual(field.particles[0].position.y, original.position.y * 2, accuracy: 0.001)
        XCTAssertEqual(field.particles.count, 140)
        field.resize(to: .zero)
        XCTAssertEqual(field.size, CGSize(width: 2080, height: 1400))
    }
}
