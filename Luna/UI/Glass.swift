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

// MARK: - Focus ring (native macOS keyboard-focus treatment for input bars)

/// A hairline accent stroke shown only while the field has keyboard focus,
/// matching the system focus ring. No glow, no animation beyond a quick fade.
struct FocusRing<S: InsettableShape>: View {
    var shape: S
    var isActive: Bool

    var body: some View {
        shape
            .strokeBorder(Color.accentColor.opacity(isActive ? 0.55 : 0), lineWidth: 1)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: isActive)
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
