#if os(macOS)
import AppKit
import SwiftUI

/// A native selectable list with heights measured from the same SwiftUI row it displays.
/// macOS's SwiftUI List can leave newly inserted rows at its 24-point estimate.
struct MacLedgerList: NSViewRepresentable {
    let items: [LedgerItem]
    @Binding var selection: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResizingTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .controlBackgroundColor
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityIdentifier("ledger-items")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        table.widthChanged = { [weak coordinator = context.coordinator] in coordinator?.resizeRows() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(items: items, selection: $selection, environment: context.environment)
    }

    @MainActor
    final class ResizingTable: NSTableView {
        var widthChanged: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            let changed = abs(frame.width - newSize.width) > 0.5
            super.setFrameSize(newSize)
            if changed { widthChanged?() }
        }
    }

    /// Rows contain display-only content; let the table own pointer and keyboard input.
    @MainActor
    final class RowHost: NSHostingView<AnyView> {
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct RowAppearance: Equatable {
        let textSize: DisplayTextSize
        let dynamicTypeSize: DynamicTypeSize
        let locale: Locale
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let legibility: LegibilityWeight?
        let direction: LayoutDirection

        init(_ environment: EnvironmentValues) {
            textSize = environment.displayTextSize
            dynamicTypeSize = environment.dynamicTypeSize
            locale = environment.locale
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            legibility = environment.legibilityWeight
            direction = environment.layoutDirection
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var selection: Binding<UUID?>
        private var items: [LedgerItem] = []
        private var environment = EnvironmentValues()
        private var appearance: RowAppearance?
        private var hosts: [UUID: RowHost] = [:]
        private var heights: [UUID: CGFloat] = [:]
        private var applying = false
        private var resizePending = false

        init(selection: Binding<UUID?>) { self.selection = selection }

        func update(items newItems: [LedgerItem], selection: Binding<UUID?>, environment: EnvironmentValues) {
            guard let table else { return }
            self.selection = selection
            let currentAppearance = RowAppearance(environment)
            let changed = items.map(\.versions) != newItems.map(\.versions) || appearance != currentAppearance
            appearance = currentAppearance
            self.environment = environment
            let anchor = scrollAnchor()
            items = newItems
            applying = true
            defer { applying = false }
            if changed {
                let ids = Set(items.map(\.id))
                hosts = hosts.filter { ids.contains($0.key) }
                heights.removeAll()
                for item in items { configureHost(for: item) }
                table.reloadData()
                restoreScroll(anchor)
            }
            let index = items.firstIndex { $0.id == selection.wrappedValue }
            let indexes = index.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            return host(for: items[row])
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard items.indices.contains(row) else { return tableView.rowHeight }
            let item = items[row]
            if let height = heights[item.id] { return height }
            let height = ceil(host(for: item).fittingSize.height)
            heights[item.id] = height
            return height
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            selection.wrappedValue = items.indices.contains(table.selectedRow) ? items[table.selectedRow].id : nil
        }

        func resizeRows() {
            guard !resizePending else { return }
            resizePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.resizePending = false
                let anchor = self.scrollAnchor()
                self.heights.removeAll()
                for item in self.items { self.configureHost(for: item) }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.items.count))
                }
                self.restoreScroll(anchor)
            }
        }

        private func host(for item: LedgerItem) -> RowHost {
            if let host = hosts[item.id] { return host }
            configureHost(for: item)
            return hosts[item.id]!
        }

        private func configureHost(for item: LedgerItem) {
            let width = max(1, table?.tableColumns.first?.width ?? 240)
            let content = AnyView(LedgerItemRow(item: item)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .ledgerFont(.body)
                .environment(\.displayTextSize, environment.displayTextSize)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.locale, environment.locale)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.legibilityWeight, environment.legibilityWeight)
                .accessibilityIdentifier("ledger-item-\(item.id.uuidString)"))
            if let host = hosts[item.id] { host.rootView = content }
            else { hosts[item.id] = RowHost(rootView: content) }
        }

        private func scrollAnchor() -> (id: UUID, offset: CGFloat)? {
            guard let table else { return nil }
            let y = table.visibleRect.minY
            guard y > 0.5 else { return nil }
            let row = table.row(at: NSPoint(x: 1, y: y))
            guard items.indices.contains(row) else { return nil }
            return (items[row].id, y - table.rect(ofRow: row).minY)
        }

        private func restoreScroll(_ anchor: (id: UUID, offset: CGFloat)?) {
            guard let table, let anchor, let row = items.firstIndex(where: { $0.id == anchor.id }),
                  let scroll = table.enclosingScrollView else { return }
            let point = NSPoint(x: 0, y: table.rect(ofRow: row).minY + anchor.offset)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: point, size: scroll.contentSize)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
#endif
