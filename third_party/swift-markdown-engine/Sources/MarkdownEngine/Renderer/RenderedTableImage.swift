//
//  RenderedTableImage.swift
//  MarkdownEngine
//
//  Dieter extension: a rendered GFM table remembers where its cell links
//  were drawn, so clicks on the image (inline or in a wide-table overlay)
//  can follow them, and read-only views can copy the table as Markdown or
//  tab-separated values.
//

import AppKit

extension NSAttributedString.Key {
    /// The original Markdown destination of a link drawn inside a table cell.
    static let tableCellLinkDestination = NSAttributedString.Key("TableCellLinkDestination")
}

/// A table image with the rects (top-down image coordinates) of its links.
/// The table image cache keeps the subclass, so cached images keep them too.
final class RenderedTableImage: NSImage {
    struct LinkRegion: Equatable {
        let rect: CGRect
        let destination: String
    }

    /// Set once, right after rendering, before the image is cached or shared.
    nonisolated(unsafe) var linkRegions: [LinkRegion] = []

    /// The destination of the link under `point` (top-down image coordinates),
    /// allowing a little slack around the glyphs.
    func linkDestination(at point: CGPoint) -> String? {
        linkRegions.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.destination
    }
}

extension MarkdownStyler {

    /// A table's rows as tab-separated values: one line per row (header
    /// first), cells as their visible text with Markdown markers stripped.
    static func tableTSV(from source: String, registry: ExtensionRegistry = .empty) -> String? {
        guard let table = parseTableSource(source) else { return nil }
        func line(_ cells: [String]) -> String {
            cells.map { cell in
                plainCellText(cell, registry: registry)
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }
        return ([line(table.header)] + table.rows.map(line)).joined(separator: "\n")
    }

    /// A cell's visible text: what `formattedCellString` draws, without fonts.
    static func plainCellText(_ raw: String, registry: ExtensionRegistry = .empty) -> String {
        let raw = expandCellLineBreaks(raw)
        let ns = raw as NSString
        var out = ""
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .text(let range):
                    out += ns.substring(with: range)
                case .escape(_, let character, _):
                    out += ns.substring(with: character)
                case .emphasis(_, _, _, let children):
                    walk(children)
                case .ext(let ext):
                    if ext.children.isEmpty { out += ns.substring(with: ext.contentRange) } else { walk(ext.children) }
                case .code(_, let content):
                    out += ns.substring(with: content)
                case .link(let range, _, _, _, let children):
                    let before = out.count
                    walk(children)
                    if out.count == before { out += ns.substring(with: range) }
                case .inlineLatex(let range, _, _),
                     .image(let range, _, _, _),
                     .wikiLink(let range, _, _, _),
                     .imageEmbed(let range, _, _):
                    out += ns.substring(with: range)
                }
            }
        }
        walk(InlineParser.parse(raw, registry: registry))
        return out
    }
}
