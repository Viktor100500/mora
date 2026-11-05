import Foundation

/// Positions and velocities are in points and seconds, independent of display refresh rate.
struct LaunchParticleField {
    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var drift: CGVector
        let radius: CGFloat
        let phase: Double
    }

    private(set) var particles: [Particle] = []
    private(set) var size: CGSize = .zero
    private(set) var elapsed: Double = 0
    var connectionDistance: CGFloat { min(190, max(140, min(size.width, size.height) * 0.24)) }

    init(size: CGSize) { resize(to: size) }

    mutating func resize(to newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0, newSize != size else { return }
        if size.width > 0, size.height > 0 {
            for index in particles.indices {
                particles[index].position.x *= newSize.width / size.width
                particles[index].position.y *= newSize.height / size.height
            }
        }
        size = newSize
        let count = Int(min(140, max(54, newSize.width * newSize.height / 10_000)))
        if particles.count > count { particles.removeLast(particles.count - count) }
        while particles.count < count {
            let angle = Double.random(in: 0..<(2 * .pi)), speed = Double.random(in: 24...44)
            let drift = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
            particles.append(Particle(position: CGPoint(x: .random(in: 0...size.width), y: .random(in: 0...size.height)),
                                      velocity: drift, drift: drift, radius: .random(in: 1.1...2.1),
                                      phase: .random(in: 0..<(2 * .pi))))
        }
    }

    mutating func advance(by interval: TimeInterval, cursor: CGPoint?) {
        // Resuming a hidden window must not fling particles across the screen.
        let dt = min(max(interval, 0), 1.0 / 30)
        guard dt > 0 else { return }
        elapsed += dt
        let recovery = exp(-2.3 * dt)
        for index in particles.indices {
            var particle = particles[index]
            particle.velocity.dx = particle.drift.dx + (particle.velocity.dx - particle.drift.dx) * recovery
            particle.velocity.dy = particle.drift.dy + (particle.velocity.dy - particle.drift.dy) * recovery
            if let cursor {
                let dx = particle.position.x - cursor.x, dy = particle.position.y - cursor.y
                let distance = hypot(dx, dy), radius: CGFloat = 200
                if distance < radius {
                    let falloff = 1 - distance / radius
                    let force = 2_600 * falloff * falloff * dt
                    // A particle directly under the pointer still has a direction to escape.
                    let ux = distance > 0.01 ? dx / distance : cos(particle.phase)
                    let uy = distance > 0.01 ? dy / distance : sin(particle.phase)
                    particle.velocity.dx += ux * force
                    particle.velocity.dy += uy * force
                }
            }
            let speed = hypot(particle.velocity.dx, particle.velocity.dy)
            if speed > 320 {
                particle.velocity.dx *= 320 / speed
                particle.velocity.dy *= 320 / speed
            }
            particle.position.x += particle.velocity.dx * dt
            particle.position.y += particle.velocity.dy * dt
            let margin: CGFloat = 16
            if particle.position.x < -margin {
                particle.position.x = -margin; particle.velocity.dx = abs(particle.velocity.dx)
                particle.drift.dx = abs(particle.drift.dx)
            } else if particle.position.x > size.width + margin {
                particle.position.x = size.width + margin; particle.velocity.dx = -abs(particle.velocity.dx)
                particle.drift.dx = -abs(particle.drift.dx)
            }
            if particle.position.y < -margin {
                particle.position.y = -margin; particle.velocity.dy = abs(particle.velocity.dy)
                particle.drift.dy = abs(particle.drift.dy)
            } else if particle.position.y > size.height + margin {
                particle.position.y = size.height + margin; particle.velocity.dy = -abs(particle.velocity.dy)
                particle.drift.dy = -abs(particle.drift.dy)
            }
            particles[index] = particle
        }
    }

    static func connectionOpacity(distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0, distance < limit else { return 0 }
        let proximity = 1 - max(0, distance) / limit
        return proximity * proximity * 0.46
    }
}
