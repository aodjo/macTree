import AppKit

/**
 * Table / outline row that outlines itself in red while its item is marked
 * for permanent deletion.
 */
final class MarkableRowView: NSTableRowView {
    /** Whether the row's item is marked for deletion; redraws on change. */
    var isMarked = false {
        didSet { if isMarked != oldValue { needsDisplay = true } }
    }

    /**
     * Draws the standard row, then a red rounded border when marked.
     *
     * The border sits inside the row bounds so neighbouring rows never
     * overlap it, and it is drawn over the selection highlight so a marked
     * row stays recognisable while selected.
     *
     * @param {NSRect} dirtyRect - The area AppKit asks to redraw.
     *
     * @example
     * rowView.isMarked = true // AppKit then calls draw(_:)
     */
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isMarked else { return }
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        NSColor.systemRed.setStroke()
        border.stroke()
    }
}

extension NSEvent {
    /**
     * Whether this key event is Delete (⌫) or Forward Delete (⌦) without ⌘, ⌥, ⌃ or ⇧.
     *
     * ⌘⌫ stays reserved for Move to Trash through the menu. The Fn / keypad
     * flags that Forward Delete sets on some keyboards are ignored.
     *
     * @returns {Bool} True for a plain Delete key press.
     *
     * @example
     * if event.isPlainDeleteKey { owner?.toggleDeletionMark() }
     */
    var isPlainDeleteKey: Bool {
        guard keyCode == 51 || keyCode == 117 else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        return modifiers.isEmpty
    }
}
