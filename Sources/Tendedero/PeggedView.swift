import SwiftUI

/// One photo with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line
    var reportsHitRect = true

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }

    private var pressed: Bool { line.pressedID == item.id }
    private var expanded: Bool { item.isTextNote && line.expandedNoteID == item.id }
    private let expansionMotion = Animation.spring(response: 0.58, dampingFraction: 0.76)

    var body: some View {
        VStack(spacing: -12) {
            Clothespin(pinned: item.kept)
                .zIndex(1)
            // Held in your hand: a faded trace of it waits on its clip.
            card
                .saturation(item.held ? 0 : 1)
                .opacity(item.held ? 0.3 : 1)
                .animation(.easeOut(duration: 0.25), value: item.held)
        }
        .rotationEffect(.degrees(expanded ? 0 : swing + item.tilt), anchor: .top)
        .animation(expansionMotion, value: expanded)
        .offset(y: arrived ? 0 : -46)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - 14, maxH = Layout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    /// Distance from the top of the hanging view (the clip) to the card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var photoSize: CGSize { Self.photoSize(for: item.thumb.size) }
    private var displaySize: CGSize {
        expanded ? CGSize(width: max(1, line.expandedNoteSize.width - Frame.inset * 2),
                          height: max(1, line.expandedNoteSize.height - Frame.inset * 2)) : photoSize
    }

    private var card: some View {
        Group {
            if item.isTextNote {
                InlineNoteEditor(url: item.url, expanded: expanded,
                    fontSize: NoteExpansionLayout.fontSize(scale: Layout.size.scale),
                    remarkRequest: line.remarkEditingID == item.id ? line.remarkRequestSerial : 0,
                    kind: item.noteKind, showKindMark: !hovering || expanded,
                    onSaved: { line.reloadThumbnail(for: item.url) },
                    onCollapse: { line.onCollapseNote?() })
            } else {
                Image(nsImage: item.thumb).resizable().interpolation(.high)
            }
        }
            .frame(width: displaySize.width, height: displaySize.height)
            // Concentric corners: the photo's radius is the frame's minus the
            // inset, the way macOS rounds nested shapes.
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(item.isTextNote ? 0 : 0.18), lineWidth: 0.5)
            )
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                }
            }
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius, frostedNote: item.isTextNote, ideaColor: IdeaPalette.color(item.ideaColorHex))
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // Holding presses the photo in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(item.isTextNote ? 1 : (pressed ? 0.95 : (hovering ? 1.035 : 1)), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // GrabView handles the archive button drawn here.
                Image(systemName: "archivebox")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .glassFrame(circle: true)
                    .padding(3)
                    .opacity(hovering && !expanded && !dragging && !item.held ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay {
                if !expanded { GrabArea(item: item, line: line) }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isTextNote && !item.held && !item.falling {
                    Button { line.onEditRemark?(item.id) } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.45))
                            .frame(width: 23, height: 23)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Add or edit remark"))
                    .accessibilityLabel(L("Add or edit remark"))
                    .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if copied {
                    Label(L("Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        // Wider than a narrow card rather than broken over several lines.
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .animation(expansionMotion, value: expanded)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling || !reportsHitRect ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        guard !expanded else { return }
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false,
                    frostedNote: Bool = false, ideaColor: NSColor? = nil) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background {
            if frostedNote { FrostedNoteBackground(tint: ideaColor).clipShape(shape) }
            else { shape.fill(.ultraThinMaterial) }
        }
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(frostedNote ? 0.22 : 0.55),
                                            Color.white.opacity(frostedNote ? 0 : 0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(frostedNote ? 0.05 : 0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// A minimal aluminium clip: a brushed metal pill with a slot where it
/// grips the line, and a soft shadow so it reads on any background.
struct Clothespin: View {
    /// Silver for what comes and goes, space grey for what you pinned, the
    /// way Macs come in both: what stays on the line reads at a glance.
    var pinned = false

    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    private let spaceGrey = LinearGradient(
        stops: [
            .init(color: Color(white: 0.30), location: 0),
            .init(color: Color(white: 0.47), location: 0.35),
            .init(color: Color(white: 0.38), location: 0.65),
            .init(color: Color(white: 0.24), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(pinned ? spaceGrey : metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(pinned ? 0.45 : 0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(pinned ? 0.55 : 0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
