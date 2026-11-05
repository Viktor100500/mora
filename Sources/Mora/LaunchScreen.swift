import AppKit
import SwiftUI

struct LaunchScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let background = Color(red: 0.025, green: 0.055, blue: 0.044)
    private let ivory = Color(red: 0.90, green: 0.95, blue: 0.88)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background
                RadialGradient(colors: [Color(red: 0.07, green: 0.18, blue: 0.13), background],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.7)
                LaunchParticles(reduceMotion: reduceMotion)
                RadialGradient(stops: [.init(color: background.opacity(0.94), location: 0),
                                       .init(color: background.opacity(0.78), location: 0.40),
                                       .init(color: .clear, location: 1)],
                               center: .center, startRadius: 0, endRadius: 330)
                VStack(spacing: 0) {
                    LaunchLeaf()
                        .fill(LinearGradient(colors: [ivory, Color(red: 0.44, green: 0.72, blue: 0.56)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                        .shadow(color: Color(red: 0.35, green: 0.78, blue: 0.51).opacity(0.2), radius: 30)
                        .padding(.bottom, 23)
                    Text("mora")
                        .font(.system(size: 64, weight: .medium, design: .rounded))
                        .tracking(-2.5)
                        .foregroundStyle(ivory)
                    Text("yar.thedeveloper")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(ivory.opacity(0.42))
                        .padding(.top, 12)
                    HStack(spacing: 10) {
                        LaunchLoadingDots(reduceMotion: reduceMotion)
                        Text(L("Открываем ваши финансы…"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(ivory.opacity(0.6))
                    }.padding(.top, 54)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mora")
        .accessibilityValue(L("Открываем ваши финансы…"))
    }
}

private struct LaunchLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        // The same leaf silhouette as the macOS app icon, without its tile.
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + (1 - y) * rect.height)
        }
        path.move(to: point(0.18, 0.13))
        path.addCurve(to: point(0.88, 0.85), control1: point(-0.04, 0.75), control2: point(0.57, 0.97))
        path.addCurve(to: point(0.18, 0.13), control1: point(0.98, 0.32), control2: point(0.68, -0.04))
        path.closeSubpath()
        // An open vein cut out of the leaf gives it the familiar Mora shape.
        var vein = Path()
        vein.move(to: point(0.14, 0.08))
        vein.addCurve(to: point(0.69, 0.66), control1: point(0.38, 0.37), control2: point(0.53, 0.46))
        return path.subtracting(vein.strokedPath(StrokeStyle(lineWidth: rect.width * 0.045, lineCap: .round)))
    }
}

private struct LaunchLoadingDots: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { timeline in
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(Color(red: 0.51, green: 0.77, blue: 0.60))
                        .frame(width: 3, height: 3)
                        .opacity(reduceMotion ? 0.65 : 0.3 + 0.7 * (sin(timeline.date.timeIntervalSinceReferenceDate * 3 - Double(index) * 0.8) + 1) / 2)
                }
            }
        }.frame(width: 17, height: 8).accessibilityHidden(true)
    }
}

private struct LaunchParticles: NSViewRepresentable {
    let reduceMotion: Bool
    func makeNSView(context: Context) -> LaunchParticleView { LaunchParticleView() }
    func updateNSView(_ view: LaunchParticleView, context: Context) { view.reduceMotion = reduceMotion }
    static func dismantleNSView(_ view: LaunchParticleView, coordinator: ()) { view.stop() }
}

final class LaunchParticleView: NSView {
    var reduceMotion = false {
        didSet {
            guard oldValue != reduceMotion else { return }
            if reduceMotion { stop() } else { start() }
            needsDisplay = true
        }
    }
    private var field = LaunchParticleField(size: .zero)
    private var timer: Timer?
    private var lastFrame: TimeInterval?
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
        setAccessibilityElement(false)
    }

    override func layout() {
        super.layout()
        field.resize(to: bounds.size)
        needsDisplay = true
    }

    private func start() {
        guard window != nil, !reduceMotion, timer == nil else { return }
        lastFrame = nil
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 1.0 / 240
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil; lastFrame = nil
    }

    @objc private func tick() {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else {
            lastFrame = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastFrame.map { now - $0 } ?? 1.0 / 60
        lastFrame = now
        // Native window coordinates also work when the cursor is already inside at launch.
        let mouse = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        field.advance(by: dt, cursor: bounds.contains(mouse) ? mouse : nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let particles = field.particles, limit = field.connectionDistance
        context.setLineWidth(0.65)
        for first in particles.indices {
            for second in particles.indices where second > first {
                let a = particles[first].position, b = particles[second].position
                let distance = hypot(a.x - b.x, a.y - b.y)
                let opacity = LaunchParticleField.connectionOpacity(distance: distance, limit: limit)
                guard opacity > 0 else { continue }
                context.setStrokeColor(CGColor(red: 0.49, green: 0.77, blue: 0.62, alpha: opacity))
                context.move(to: a); context.addLine(to: b); context.strokePath()
            }
        }
        for particle in particles {
            let brightness = 0.6 + 0.18 * sin(field.elapsed * 0.7 + particle.phase)
            let radius = particle.radius, position = particle.position
            context.setFillColor(CGColor(red: 0.40, green: 0.80, blue: 0.56, alpha: 0.055))
            context.fillEllipse(in: CGRect(x: position.x - radius * 3, y: position.y - radius * 3, width: radius * 6, height: radius * 6))
            context.setFillColor(CGColor(red: 0.72, green: 0.91, blue: 0.77, alpha: brightness))
            context.fillEllipse(in: CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}
