import SwiftUI

/// Sizes and palette of the commit graph. Drawn by GraphCellView in CommitTableView.
enum GraphStyle {
    static let laneWidth: CGFloat = 12
    static let rowHeight: CGFloat = 24
    static let lineWidth: CGFloat = 1.6

    static let palette: [Color] = [
        Color(red: 0.26, green: 0.52, blue: 0.96),
        Color(red: 0.20, green: 0.70, blue: 0.40),
        Color(red: 0.95, green: 0.55, blue: 0.15),
        Color(red: 0.62, green: 0.40, blue: 0.90),
        Color(red: 0.90, green: 0.35, blue: 0.55),
        Color(red: 0.15, green: 0.68, blue: 0.72),
        Color(red: 0.85, green: 0.30, blue: 0.25),
        Color(red: 0.55, green: 0.55, blue: 0.20),
    ]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }

    /// Width of the graph column for the given number of lanes.
    static func width(lanes: Int) -> CGFloat {
        CGFloat(max(lanes, 1)) * laneWidth + 4
    }
}
