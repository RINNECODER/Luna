// Luna — Liquid Glass UI foundation.
// Uses the native .glassEffect APIs on macOS 26+ (Tahoe) and degrades to
// material blur + hairline stroke on macOS 15, so one call site serves both.
import SwiftUI
import AppKit

// MARK: - Shared glass tint (dark grey glassmorphism; opaque but see-through)

let startPageGlassTint = Color(red: 0.09, green: 0.09, blue: 0.10)
let startPageGlassTintOpacity: Double = 0.88

// MARK: - VisualEffectView (NSVisualEffectView wrapper)

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Liquid Glass surface modifier

/// Applies native Liquid Glass on macOS 26+, or a material-blur fallback below.
/// `interactive` enables the live-warp variant (use for surfaces the user touches).
struct LunaGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill(Color.white.opacity(0.06)))
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Liquid Glass capsule (the default shape across the app's controls).
    func lunaGlassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LunaGlass(shape: Capsule(style: .continuous), interactive: interactive, tint: tint))
    }

    /// Liquid Glass rounded rectangle.
    func lunaGlass(cornerRadius: CGFloat, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LunaGlass(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            interactive: interactive,
            tint: tint
        ))
    }

    /// Groups sibling glass shapes so they share one sampling region and can
    /// morph together (no-op below macOS 26).
    @ViewBuilder
    func lunaGlassContainer(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

// MARK: - Aurora glow (ChatGPT-style animated multicolor rim for input bars)

/// A soft animated angular gradient that hugs a capsule/rounded-rect edge.
/// Apple's Siri and the ChatGPT macOS app use this treatment on their input
/// fields; the hue drift is slow and the light sits mostly at the rim.
struct AuroraGlow<S: InsettableShape>: View {
    var shape: S
    var isActive: Bool
    var lineWidth: CGFloat = 2

    @State private var angle: Double = 0

    private var gradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 0.36, green: 0.63, blue: 1.0),   // blue
                Color(red: 0.68, green: 0.47, blue: 1.0),   // violet
                Color(red: 1.0, green: 0.52, blue: 0.62),   // pink
                Color(red: 1.0, green: 0.72, blue: 0.45),   // amber
                Color(red: 0.42, green: 0.85, blue: 0.70),  // teal
                Color(red: 0.36, green: 0.63, blue: 1.0),   // wrap to blue
            ]),
            center: .center,
            angle: .degrees(angle)
        )
    }

    var body: some View {
        ZStack {
            // Wide, blurred halo behind the rim
            shape
                .strokeBorder(gradient, lineWidth: lineWidth * 4)
                .blur(radius: 14)
                .opacity(isActive ? 0.55 : 0.28)
            // Crisp rim light
            shape
                .strokeBorder(gradient, lineWidth: lineWidth)
                .blur(radius: 0.6)
                .opacity(isActive ? 0.9 : 0.5)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isActive)
    }
}

// MARK: - Glass icon button (circular, toolbar-grade)

/// Circular icon button with a Liquid Glass background — the standard toolbar
/// control shape on macOS 26.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 12
    var isEnabled: Bool = true
    var accessibilityLabel: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.primary.opacity(isHovering && isEnabled ? 0.12 : 0))
        )
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - HairlineDivider (1px, very low opacity)

struct HairlineDivider: View {
    var opacity: Double = 0.2

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(opacity))
            .frame(height: 1)
    }
}
