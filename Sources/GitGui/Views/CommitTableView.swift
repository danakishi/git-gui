import AppKit
import GitCore
import GraphLayout
import Hosting
import SwiftUI

/// Commit table built on NSTableView.
///
/// SwiftUI `List` and `Table` behave poorly with thousands of graph rows:
/// padding breaks the lines, and `List` next to the inspector makes the layout loop.
/// Here the row height and graph drawing are fully under our control.
struct CommitTableView: NSViewRepresentable {
    let commits: [Commit]
    let graphRows: [String: GraphLayout.Row]
    let refsByCommit: [String: [Ref]]
    let headSHA: String?
    /// PRs by commit sha and CI statuses; `hostingVersion` grows when they change.
    var pullRequestsByCommit: [String: [PullRequest]] = [:]
    var ciStatus: [String: CIStatus] = [:]
    var hostingVersion = 0
    /// 0 means the graph column is hidden.
    let visibleLanes: Int
    @Binding var selection: Commit.ID?
    let onReachEnd: () -> Void
    /// Row context menu; `nil` means no menu.
    var contextMenu: ((Commit) -> NSMenu?)?

    nonisolated static let rowHeight: CGFloat = 24

    func makeNSView(context: Context) -> NSScrollView {
        let table = ContextMenuTableView()
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            guard let c = coordinator, row >= 0, row < c.parent.commits.count else { return nil }
            return c.parent.contextMenu?(c.parent.commits[row])
        }
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        for spec in Column.allCases {
            let column = NSTableColumn(identifier: spec.id)
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec == .graph ? 0 : 40
            column.resizingMask = spec == .message ? [.autoresizingMask, .userResizingMask]
                : spec == .graph ? [] : [.userResizingMask]
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self

        let graphColumn = c.table.tableColumns[Column.graph.rawValue]
        let graphWidth = visibleLanes == 0 ? 0 : GraphStyle.width(lanes: visibleLanes)
        if graphColumn.width != graphWidth {
            graphColumn.width = graphWidth
            graphColumn.isHidden = visibleLanes == 0
        }

        // The message column takes whatever width is left: otherwise the table is
        // wider than the window, and the date and sha get pushed past the edge.
        let available = scroll.contentSize.width
        if available > 0 {
            let others = c.table.tableColumns.filter { $0.identifier != Column.message.id && !$0.isHidden }
                .reduce(0) { $0 + $1.width }
            let message = c.table.tableColumns[Column.message.rawValue]
            let wanted = max(message.minWidth, available - others)
            if abs(message.width - wanted) > 1 { message.width = wanted }
        }

        // Reload only when the set of rows changes, otherwise the table
        // jitters on every state update.
        let signature = DataSignature(count: commits.count, first: commits.first?.id, last: commits.last?.id,
                                      lanes: visibleLanes, head: headSHA, refs: refsByCommit.count,
                                      hosting: hostingVersion)
        if c.signature != signature {
            c.signature = signature
            c.table.reloadData()
        }

        // Sync the selection from the model (for example, a click on a parent in the inspector).
        let wanted = selection.flatMap { id in commits.firstIndex { $0.id == id } }
        let current = c.table.selectedRow >= 0 ? c.table.selectedRow : nil
        if wanted != current {
            c.isSyncingSelection = true
            if let wanted {
                c.table.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
                c.table.scrollRowToVisible(wanted)
            } else {
                c.table.deselectAll(nil)
            }
            c.isSyncingSelection = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    struct DataSignature: Equatable {
        let count: Int
        let first: String?
        let last: String?
        let lanes: Int
        let head: String?
        let refs: Int
        let hosting: Int
    }

    enum Column: Int, CaseIterable {
        case graph, message, author, date, sha

        var id: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("col.\(self)") }

        var title: String {
            switch self {
            case .graph: ""
            case .message: "Message"
            case .author: "Author"
            case .date: "Date"
            case .sha: "SHA"
            }
        }

        var width: CGFloat {
            switch self {
            case .graph: 150
            case .message: 400
            case .author: 110
            case .date: 104
            case .sha: 66
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CommitTableView
        var table: NSTableView!
        var signature: DataSignature?
        var isSyncingSelection = false

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "d MMM HH:mm"
            return f
        }()

        init(parent: CommitTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.commits.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < parent.commits.count,
                  let column = Column.allCases.first(where: { $0.id == tableColumn.identifier }) else { return nil }
            let commit = parent.commits[row]

            if row == parent.commits.count - 1 {
                let reach = parent.onReachEnd
                DispatchQueue.main.async { reach() }
            }

            switch column {
            case .graph:
                let cell = tableView.makeView(withIdentifier: column.id, owner: nil) as? GraphCellView
                    ?? { let v = GraphCellView(); v.identifier = column.id; return v }()
                cell.row = parent.graphRows[commit.id]
                cell.isHead = commit.id == parent.headSHA
                cell.isMerge = commit.isMerge
                cell.needsDisplay = true
                return cell

            case .message:
                let cell = tableView.makeView(withIdentifier: column.id, owner: nil) as? MessageCellView
                    ?? { let v = MessageCellView(); v.identifier = column.id; return v }()
                cell.configure(commit: commit, refs: parent.refsByCommit[commit.id] ?? [],
                               pullRequests: parent.pullRequestsByCommit[commit.id] ?? [],
                               ci: parent.ciStatus[commit.id])
                return cell

            case .author, .date, .sha:
                let cell = tableView.makeView(withIdentifier: column.id, owner: nil) as? TextCellView
                    ?? { let v = TextCellView(); v.identifier = column.id; return v }()
                switch column {
                case .author:
                    cell.set(commit.authorName, secondary: false, mono: false)
                case .date:
                    cell.set(dateFormatter.string(from: commit.authorDate), secondary: true, mono: false)
                default:
                    cell.set(commit.shortID, secondary: true, mono: true)
                }
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            let row = table.selectedRow
            let id = row >= 0 && row < parent.commits.count ? parent.commits[row].id : nil
            // Don't change SwiftUI state straight from the delegate: that is exactly the
            // "reentrant operation" AppKit complains about.
            DispatchQueue.main.async { [self] in
                if parent.selection != id { parent.selection = id }
            }
        }
    }
}

// MARK: Context menu

/// NSTableView that builds the menu for the row under the cursor and selects it.
final class ContextMenuTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

/// Menu item with a closure instead of target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, destructive: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if destructive {
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: Cells

/// Graph cell: lines and node; sizes and palette are in GraphStyle.
final class GraphCellView: NSView {
    var row: GraphLayout.Row?
    var isHead = false
    var isMerge = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let h = bounds.height
        let mid = h / 2
        let lane = GraphStyle.laneWidth
        let r = min(lane / 2, h / 4)
        func x(_ l: Int) -> CGFloat { CGFloat(l) * lane + lane / 2 + 2 }
        let nodeX = x(row.lane)
        let lw = GraphStyle.lineWidth

        func stroke(_ path: NSBezierPath, _ color: Int) {
            path.lineWidth = lw
            path.lineCapStyle = .round
            NSColor(GraphStyle.color(color)).setStroke()
            path.stroke()
        }

        for line in row.passing {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: x(line.lane), y: 0))
            p.line(to: CGPoint(x: x(line.lane), y: h))
            stroke(p, line.color)
        }
        for line in row.incoming {
            let p = NSBezierPath()
            let lx = x(line.lane)
            p.move(to: CGPoint(x: lx, y: 0))
            if line.lane == row.lane {
                p.line(to: CGPoint(x: nodeX, y: mid))
            } else {
                let dir: CGFloat = nodeX > lx ? 1 : -1
                p.line(to: CGPoint(x: lx, y: mid - r))
                p.curve(to: CGPoint(x: lx + dir * r, y: mid), controlPoint1: CGPoint(x: lx, y: mid), controlPoint2: CGPoint(x: lx, y: mid))
                p.line(to: CGPoint(x: nodeX, y: mid))
            }
            stroke(p, line.color)
        }
        for line in row.outgoing.sorted(by: { abs($0.lane - row.lane) > abs($1.lane - row.lane) }) {
            let p = NSBezierPath()
            let lx = x(line.lane)
            p.move(to: CGPoint(x: nodeX, y: mid))
            if line.lane == row.lane {
                p.line(to: CGPoint(x: lx, y: h))
            } else {
                let dir: CGFloat = lx > nodeX ? 1 : -1
                p.line(to: CGPoint(x: lx - dir * r, y: mid))
                p.curve(to: CGPoint(x: lx, y: mid + r), controlPoint1: CGPoint(x: lx, y: mid), controlPoint2: CGPoint(x: lx, y: mid))
                p.line(to: CGPoint(x: lx, y: h))
            }
            stroke(p, line.color)
        }

        let radius: CGFloat = isHead ? 4.5 : 3.5
        let dot = NSBezierPath(ovalIn: CGRect(x: nodeX - radius, y: mid - radius, width: 2 * radius, height: 2 * radius))
        let color = NSColor(GraphStyle.color(row.color))
        if isMerge {
            NSColor.controlBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = lw
            color.setStroke()
            dot.stroke()
        } else {
            color.setFill()
            dot.fill()
        }
        if isHead {
            let ring = NSBezierPath(ovalIn: CGRect(x: nodeX - radius - 2.5, y: mid - radius - 2.5,
                                                   width: 2 * radius + 5, height: 2 * radius + 5))
            ring.lineWidth = 1.5
            color.withAlphaComponent(0.45).setStroke()
            ring.stroke()
        }
    }
}

/// Commit message with branch and tag labels. The labels are SwiftUI via NSHostingView.
final class MessageCellView: NSTableCellView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Labels must not spill out of the column over their neighbors.
        wantsLayer = true
        layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(commit: Commit, refs: [Ref], pullRequests: [PullRequest], ci: CIStatus?) {
        hosting.rootView = AnyView(
            HStack(spacing: 4) {
                RefBadges(refs: refs)
                ForEach(pullRequests) { PullRequestBadge(pullRequest: $0) }
                Text(commit.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(commit.isMerge ? .secondary : .primary)
                Spacer(minLength: 0)
                // On the right so the text doesn't shift: the icons line up in an even column.
                if let ci { CIStatusIcon(status: ci) }
            }
            .font(.system(size: 12))
        )
    }
}

/// Plain text cell.
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, secondary: Bool, mono: Bool) {
        label.stringValue = text
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
    }
}
