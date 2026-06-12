import SwiftUI

/// Compact slot selector for list rows: a mini screen diagram (~64×40) showing
/// where the current slot lives on screen. Clicking opens a popover with one
/// diagram per slot — a single clickable diagram can't work because slot
/// regions overlap spatially (`.full` covers everything, `.leftHalf` covers
/// both left quarters), so each choice gets its own cell instead.
@MainActor
struct SlotPicker: View {
    @Binding var slot: Slot

    var body: some View {
        SlotPickerCore(
            // Bridge the non-optional binding into the shared core. The core
            // never produces nil when allowsInherit is false, so the `if let`
            // only guards against a logic bug, not a real path.
            selection: Binding(
                get: { slot },
                set: { if let newValue = $0 { slot = newValue } },
            ),
            allowsInherit: false,
        )
    }
}

/// Same as SlotPicker, but nil = "inherit" (window matchers fall back to the
/// parent rule's slot). Inherit is rendered as a dashed empty screen both
/// inline and as an extra popover cell that clears the override.
@MainActor
struct OptionalSlotPicker: View {
    @Binding var slot: Slot?

    var body: some View {
        SlotPickerCore(selection: $slot, allowsInherit: true)
    }
}

// MARK: - Shared implementation

@MainActor
private struct SlotPickerCore: View {
    @Binding var selection: Slot?
    let allowsInherit: Bool
    @State private var showPopover = false
    @State private var hovering = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            SlotDiagram(slot: selection, isSelected: true)
                // Hover hint: subtle dimming signals "this is clickable" since
                // a plain-style button gives no visual feedback of its own.
                .opacity(hovering ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(selection?.displayName ?? "Inherit from app rule")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            SlotGrid(
                selection: $selection,
                allowsInherit: allowsInherit,
                dismiss: { showPopover = false },
            )
            .padding(10)
        }
    }
}

/// The popover content: every slot as a selectable diagram + caption.
@MainActor
private struct SlotGrid: View {
    @Binding var selection: Slot?
    let allowsInherit: Bool
    let dismiss: () -> Void

    private static let columns = Array(
        repeating: GridItem(.fixed(80), spacing: 6),
        count: 3,
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 6) {
            if allowsInherit {
                cell(for: nil)
            }
            ForEach(Slot.allCases) { slot in
                cell(for: slot)
            }
        }
    }

    private func cell(for slot: Slot?) -> some View {
        SlotCell(
            slot: slot,
            isSelected: slot == selection,
            select: {
                selection = slot
                dismiss()
            },
        )
    }
}

@MainActor
private struct SlotCell: View {
    let slot: Slot?
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                SlotDiagram(slot: slot, isSelected: isSelected)
                Text(slot?.displayName ?? "Inherit")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0)),
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(slot?.displayName ?? "Use the app rule's default slot")
    }
}

// MARK: - Diagram drawing

/// Mini screen: rounded-rect "monitor" with the slot's region filled where it
/// actually lives on screen. nil slot = inherit → empty screen with a dashed
/// outline so "no own value" reads at a glance.
@MainActor
private struct SlotDiagram: View {
    let slot: Slot?
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
            if let slot {
                SlotRegionShape(slot: slot)
                    .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.45))
            }
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: slot == nil ? [3, 2] : []),
                )
        }
        .frame(width: 64, height: 40)
    }
}

/// Shape (nonisolated by design — Shape.path must be callable off-main) that
/// scales the slot's unit-square region into the diagram's rect.
private struct SlotRegionShape: Shape {
    let slot: Slot

    func path(in rect: CGRect) -> Path {
        let u = slotUnitRect(slot)
        let region = CGRect(
            x: rect.minX + u.minX * rect.width,
            y: rect.minY + u.minY * rect.height,
            width: u.width * rect.width,
            height: u.height * rect.height,
        ).insetBy(dx: 1.5, dy: 1.5)
        return Path(roundedRect: region, cornerRadius: 2)
    }
}

/// Unit-square region (top-left origin, matching SwiftUI drawing space) each
/// slot occupies on a screen. Kept as a file-private free function instead of
/// a Slot extension so this lane doesn't grow the shared model type's API
/// surface (Slot lives in UISettingsStore.swift, read-only for lane B).
private func slotUnitRect(_ slot: Slot) -> CGRect {
    switch slot {
        case .full:        return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leftHalf:    return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:   return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf:     return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf:  return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft:     return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight:    return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft:  return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    }
}

// MARK: - Previews

// PreviewProvider (not #Preview) because the package targets macOS 13 and the
// #Preview macro requires macOS 14.
private struct SlotPickerPreviewHost: View {
    @State private var slot: Slot = .leftHalf
    @State private var override: Slot? = nil

    var body: some View {
        Form {
            LabeledContent("Default slot") { SlotPicker(slot: $slot) }
            LabeledContent("Matcher override") { OptionalSlotPicker(slot: $override) }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}

struct SlotPicker_Previews: PreviewProvider {
    static var previews: some View {
        SlotPickerPreviewHost()
    }
}
