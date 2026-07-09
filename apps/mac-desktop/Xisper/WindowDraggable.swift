import SwiftUI

// MARK: - Window drag modifier

/// Makes a region draggable for moving the window.
/// Interactive child views (TextField, Button) naturally take gesture priority.
struct WindowDragModifier: ViewModifier {
    @State private var dragOffset: CGPoint?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        guard let window = NSApp.keyWindow else { return }
                        let mouse = NSEvent.mouseLocation
                        if dragOffset == nil {
                            dragOffset = CGPoint(
                                x: mouse.x - window.frame.origin.x,
                                y: mouse.y - window.frame.origin.y
                            )
                        }
                        guard let off = dragOffset else { return }
                        window.setFrameOrigin(CGPoint(
                            x: mouse.x - off.x,
                            y: mouse.y - off.y
                        ))
                    }
                    .onEnded { _ in dragOffset = nil }
            )
    }
}

extension View {
    func windowDrag() -> some View {
        modifier(WindowDragModifier())
    }
}

