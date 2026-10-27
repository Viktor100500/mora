import SwiftUI

/// Visuals for connecting to a Mac: a radar while searching, a beam while the
/// devices exchange keys, a glowing edge while waiting for approval and a light
/// burst once connected. Reduce Motion keeps them still.
enum PairingPalette {
    static let glow: [Color] = [.moraGreen, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .orange, .yellow, .moraGreen]
}

/// Rings rippling out from the iPhone, like AirDrop looking for devices.
struct PairingRadar: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.moraGreen.opacity(0.22), .clear], center: .center, startRadius: 10, endRadius: 160))
                ForEach(0..<4, id: \.self) { ring in
                    let progress = reduceMotion ? Double(ring) / 4 : (time / 3 + Double(ring) / 4).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(LinearGradient(colors: [.moraGreen, .teal.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                        .scaleEffect(0.3 + progress * 0.95)
                        .opacity((1 - progress) * 0.75)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The device in the middle of the radar or at one end of the beam.
struct PairingDevice: View {
    var symbol: String
    var size: CGFloat = 84
    var glowing = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.3, green: 0.62, blue: 0.48), Color(red: 0.09, green: 0.33, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Color.moraGreen.opacity(glowing ? 0.55 : 0), radius: 22)
    }
}

/// A Mac found nearby, floating on the radar.
struct PairingMacBubble: View {
    var name: String
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let bob = reduceMotion ? 0 : sin(context.date.timeIntervalSinceReferenceDate * 1.6 + Double(index) * 1.3) * 4
            VStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.moraGreen)
                    .frame(width: 62, height: 62)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.moraGreen.opacity(0.5), lineWidth: 1.5))
                    .shadow(color: Color.moraGreen.opacity(0.35), radius: 12)
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
            }
            .offset(y: bob)
        }
    }
}

/// Particles travelling both ways between the iPhone and the Mac.
struct PairingBeam: View {
    var fast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate * (fast ? 1.4 : 0.55)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.moraGreen.opacity(0.15), Color.teal.opacity(0.35), Color.moraGreen.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                    ForEach(0..<8, id: \.self) { dot in
                        let forward = dot.isMultiple(of: 2)
                        let raw = (time + Double(dot) / 8).truncatingRemainder(dividingBy: 1)
                        let progress = forward ? raw : 1 - raw
                        Circle()
                            .fill(forward ? Color.moraGreen : Color.teal)
                            .frame(width: forward ? 7 : 5, height: forward ? 7 : 5)
                            .shadow(color: (forward ? Color.moraGreen : Color.teal).opacity(0.8), radius: 4)
                            .offset(x: progress * (width - 7))
                            .opacity(reduceMotion ? 0.6 : sin(progress * .pi))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// The six digits, revealed one after another.
struct PairingCode: View {
    var code: String
    @State private var revealed = 0

    var body: some View {
        let digits = Array(code.filter(\.isNumber))
        HStack(spacing: 8) {
            ForEach(Array(digits.enumerated()), id: \.offset) { index, digit in
                if index == 3 { Spacer().frame(width: 6) }
                Text(String(digit))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 42, height: 56)
                    .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.moraGreen.opacity(0.35), lineWidth: 1))
                    .scaleEffect(index < revealed ? 1 : 0.4)
                    .opacity(index < revealed ? 1 : 0)
                    .rotation3DEffect(.degrees(index < revealed ? 0 : -80), axis: (x: 1, y: 0, z: 0))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(digits))
        .onAppear {
            for index in digits.indices {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65).delay(0.08 * Double(index))) { revealed = index + 1 }
            }
        }
    }
}

/// A slowly rotating rainbow glow along the screen edge while the Mac decides.
struct PairingEdgeGlow: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let angle = Angle.degrees((context.date.timeIntervalSinceReferenceDate * 70).truncatingRemainder(dividingBy: 360))
            let gradient = AngularGradient(colors: PairingPalette.glow, center: .center, angle: angle)
            ZStack {
                RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(gradient, lineWidth: 14).blur(radius: 18)
                RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(gradient, lineWidth: 3).blur(radius: 2).opacity(0.8)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: active)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A wave of light with sparks, then a check mark, like NameDrop finishing.
struct PairingBurst: View {
    @State private var wave = false
    @State private var check = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), Color.moraGreen.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 100))
                    .frame(width: 200, height: 200)
                    .scaleEffect(wave ? 7 : 0.1).opacity(wave ? 0 : 1).blur(radius: 16)
                Circle()
                    .strokeBorder(AngularGradient(colors: PairingPalette.glow, center: .center), lineWidth: 8)
                    .frame(width: 200, height: 200)
                    .scaleEffect(wave ? 5 : 0.2).opacity(wave ? 0 : 1).blur(radius: 3)
                ForEach(0..<16, id: \.self) { spark in
                    let angle = Double(spark) / 16 * 2 * .pi + 0.2
                    let distance: Double = spark.isMultiple(of: 2) ? 170 : 120
                    Circle()
                        .fill(PairingPalette.glow[spark % (PairingPalette.glow.count - 1)])
                        .frame(width: spark.isMultiple(of: 3) ? 8 : 5, height: spark.isMultiple(of: 3) ? 8 : 5)
                        .shadow(color: .white.opacity(0.8), radius: 3)
                        .offset(x: wave ? cos(angle) * distance : 0, y: wave ? sin(angle) * distance : 0)
                        .opacity(wave ? 0 : 1)
                }
            }
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.3, green: 0.62, blue: 0.48), Color(red: 0.09, green: 0.33, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 112, height: 112)
                    .shadow(color: Color.moraGreen.opacity(0.6), radius: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: check)
            }
            .scaleEffect(check ? 1 : 0.3)
            .opacity(check ? 1 : 0)
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) { wave = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.15)) { check = true }
        }
    }
}
