import Foundation
import UIKit
import PDFKit

/// Generates a printable calibration target at exact physical size.
///
/// A subtlety worth stating plainly, because it is the opposite of what most
/// people assume: **the printed square size does not affect the recovered
/// focal length.** Zhang's method recovers the intrinsics from constraints on
/// the orthonormality of the board's rotation columns, and uniformly scaling
/// the object points is absorbed entirely into the per-view translation. A
/// board printed 4% small yields the same focal length in pixels; only the
/// board's apparent distance changes, and nothing downstream uses that.
///
/// What *does* matter, in order:
///
///   1. **Flatness.** A curled page makes the board non-planar, which breaks
///      the homography the whole method rests on. This is the single biggest
///      practical error source and it is invisible in the resulting numbers.
///   2. **Uniform scaling.** A printer that scales X and Y differently — some
///      do, at "fit to page" — makes the squares non-square, which the solver
///      absorbs into a false aspect ratio between fx and fy.
///   3. **Contrast and matte finish.** Glossy paper produces specular
///      highlights that the corner detector reads as structure.
///
/// So the printing advice is "100% scale, no fit-to-page, matte paper, mount
/// it rigid" — and *not* "measure the squares precisely", which is the advice
/// people expect and which would waste their time here. Contrast this with
/// the reference pipe, where the measured height feeds directly into scale
/// and a 1% error is a 1% error on every distance the app reports.
public enum CheckerboardGenerator {

    public struct PaperSize: Sendable, Equatable, Hashable {
        public let name: String
        /// Width and height in millimetres, portrait orientation.
        public let widthMillimetres: Double
        public let heightMillimetres: Double

        public static let a4 = PaperSize(name: "A4",
                                         widthMillimetres: 210,
                                         heightMillimetres: 297)
        public static let usLetter = PaperSize(name: "US Letter",
                                               widthMillimetres: 215.9,
                                               heightMillimetres: 279.4)
        public static let a3 = PaperSize(name: "A3",
                                         widthMillimetres: 297,
                                         heightMillimetres: 420)

        public static let all: [PaperSize] = [.a4, .usLetter, .a3]
    }

    /// Points per millimetre. PDF user space is 1/72 inch.
    private static let pointsPerMillimetre = 72.0 / 25.4

    /// How a tiled target will be laid out across sheets.
    ///
    /// The reason tiling exists at all: the app refuses to capture a view
    /// whose board covers less than 6% of the frame, and a single A3 sheet
    /// holds only 39 mm squares, so it falls under that floor beyond about a
    /// metre. Focus, meanwhile, has to be pinned somewhere that also renders
    /// the runway sharp — several metres out. A one-page target cannot
    /// satisfy both, and the gap is closed by making the board physically
    /// bigger rather than by lowering the floor, which would trade a printing
    /// inconvenience for a permanent accuracy loss.
    public struct TileLayout: Sendable, Equatable {
        public let columnsOfPages: Int
        public let rowsOfPages: Int
        /// Printable area per sheet, millimetres, in the orientation used.
        public let pageContentWidth: Double
        public let pageContentHeight: Double
        public let squareMillimetres: Double
        public let boardWidthMillimetres: Double
        public let boardHeightMillimetres: Double

        public var pageCount: Int { columnsOfPages * rowsOfPages }

        public var summary: String {
            let w = boardWidthMillimetres / 1000, h = boardHeightMillimetres / 1000
            return String(format: "%d sheets · %.2f × %.2f m board · %.0f mm squares",
                          pageCount, w, h, squareMillimetres)
        }
    }

    /// Distance at which a board of this square size still meets the 6%
    /// coverage floor, for the default 16:9 frame.
    ///
    /// Approximate and deliberately conservative: the real horizontal field of
    /// view depends on how much the selected high-frame-rate mode crops the
    /// sensor, which varies by device and is not knowable here. The wider
    /// assumption is used, so the figure understates reach rather than
    /// promising range the camera may not have.
    public static func usableDistanceMetres(spec: CheckerboardSpec,
                                            squareMillimetres: Double) -> Double {
        // Bounding box of the inner corners, which is what the detector
        // measures coverage from — one square short of the board in each
        // direction on both sides.
        let innerWidth = Double(spec.columns - 1) * squareMillimetres / 1000
        let innerHeight = Double(spec.rows - 1) * squareMillimetres / 1000
        let horizontalFieldOfView = 69.0 * .pi / 180
        // frameArea(d) = w * (w * 9/16), w = 2 d tan(hfov/2)
        let widthPerMetre = 2 * tan(horizontalFieldOfView / 2)
        let areaPerMetreSquared = widthPerMetre * widthPerMetre * 9 / 16
        return (innerWidth * innerHeight / (0.06 * areaPerMetreSquared)).squareRoot()
    }

    /// Plan a tiled target for a requested square size.
    public static func tileLayout(spec: CheckerboardSpec,
                                  paper: PaperSize,
                                  squareMillimetres: Double,
                                  marginMillimetres: Double = 10) -> TileLayout {
        let squaresAcross = Double(spec.columns + 1)
        let squaresDown = Double(spec.rows + 1)
        let boardWidth = squaresAcross * squareMillimetres
        let boardHeight = squaresDown * squareMillimetres

        // Quiet zone travels with the board, so the outermost corners sit
        // against plain white rather than against whatever the sheet was
        // taped to.
        let totalWidth = boardWidth + 2 * quietZoneMillimetres
        let totalHeight = boardHeight + 2 * quietZoneMillimetres

        // Sheets are used landscape when the board is wider than tall, which
        // it is for every spec this app ships.
        let landscape = boardWidth >= boardHeight
        let sheetWide = landscape
            ? max(paper.widthMillimetres, paper.heightMillimetres)
            : min(paper.widthMillimetres, paper.heightMillimetres)
        let sheetTall = landscape
            ? min(paper.widthMillimetres, paper.heightMillimetres)
            : max(paper.widthMillimetres, paper.heightMillimetres)

        let contentWidth = sheetWide - 2 * marginMillimetres
        let contentHeight = sheetTall - 2 * marginMillimetres

        return TileLayout(
            columnsOfPages: max(Int((totalWidth / contentWidth).rounded(.up)), 1),
            rowsOfPages: max(Int((totalHeight / contentHeight).rounded(.up)), 1),
            pageContentWidth: contentWidth,
            pageContentHeight: contentHeight,
            squareMillimetres: squareMillimetres,
            boardWidthMillimetres: boardWidth,
            boardHeightMillimetres: boardHeight)
    }

    private static let quietZoneMillimetres = 15.0

    /// Largest square size that fits a spec on a sheet, rounded down to a
    /// whole millimetre.
    ///
    /// Larger squares are better: corner localisation error is roughly fixed
    /// in pixels, so a bigger square means a smaller relative error, and a
    /// board that fills more of the frame gives the solver more to work with.
    public static func largestFittingSquareSize(spec: CheckerboardSpec,
                                                paper: PaperSize,
                                                marginMillimetres: Double = 12)
        -> Double {
        // Inner corners are one fewer than squares in each direction.
        let squaresAcross = Double(spec.columns + 1)
        let squaresDown = Double(spec.rows + 1)

        // Landscape gives the wider dimension to the longer side of the grid.
        let usableLong = max(paper.widthMillimetres, paper.heightMillimetres)
            - 2 * marginMillimetres
        let usableShort = min(paper.widthMillimetres, paper.heightMillimetres)
            - 2 * marginMillimetres

        let byLong = usableLong / max(squaresAcross, squaresDown)
        let byShort = usableShort / min(squaresAcross, squaresDown)

        return (min(byLong, byShort) * 1000).rounded(.down) / 1000
    }

    /// Render the target as a PDF at exact physical size.
    public static func makePDF(spec: CheckerboardSpec,
                               paper: PaperSize = .a4,
                               squareSizeMillimetres: Double? = nil) -> Data {

        let square = squareSizeMillimetres
            ?? largestFittingSquareSize(spec: spec, paper: paper)

        let squaresAcross = spec.columns + 1
        let squaresDown = spec.rows + 1

        // Landscape when the grid is wider than tall, which it is for the
        // default 9x6.
        let landscape = squaresAcross >= squaresDown
        let pageWidthMM = landscape
            ? max(paper.widthMillimetres, paper.heightMillimetres)
            : min(paper.widthMillimetres, paper.heightMillimetres)
        let pageHeightMM = landscape
            ? min(paper.widthMillimetres, paper.heightMillimetres)
            : max(paper.widthMillimetres, paper.heightMillimetres)

        let pageRect = CGRect(x: 0, y: 0,
                              width: pageWidthMM * pointsPerMillimetre,
                              height: pageHeightMM * pointsPerMillimetre)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext

            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(pageRect)

            let squarePoints = square * pointsPerMillimetre
            let gridWidth = Double(squaresAcross) * squarePoints
            let gridHeight = Double(squaresDown) * squarePoints
            let originX = (pageRect.width - gridWidth) / 2
            // Leave room at the bottom for the verification ruler.
            let originY = (pageRect.height - gridHeight) / 2 - 10 * pointsPerMillimetre

            cg.setFillColor(UIColor.black.cgColor)
            for row in 0..<squaresDown {
                for column in 0..<squaresAcross where (row + column) % 2 == 0 {
                    cg.fill(CGRect(x: originX + Double(column) * squarePoints,
                                   y: originY + Double(row) * squarePoints,
                                   width: squarePoints,
                                   height: squarePoints))
                }
            }

            // A quiet zone around the board. The corner detector fits a
            // lattice and needs the outermost corners to sit against plain
            // background; a board printed to the page edge loses its outer
            // ring to whatever is behind the sheet.
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.25).cgColor)
            cg.setLineWidth(0.5)
            cg.stroke(CGRect(x: originX - 8 * pointsPerMillimetre,
                             y: originY - 8 * pointsPerMillimetre,
                             width: gridWidth + 16 * pointsPerMillimetre,
                             height: gridHeight + 16 * pointsPerMillimetre))

            drawVerificationRuler(in: cg,
                                  pageRect: pageRect,
                                  squareMillimetres: square,
                                  spec: spec,
                                  paper: paper)
        }
    }

    /// A 100 mm ruler and a legend printed under the board.
    ///
    /// The ruler is not for measuring the squares — it is for catching a
    /// printer that silently scaled the page. If the printed ruler is not
    /// 100 mm, the page was scaled, and a scaled page usually means a
    /// *non-uniformly* scaled page, which does corrupt the calibration.
    private static func drawVerificationRuler(in cg: CGContext,
                                              pageRect: CGRect,
                                              squareMillimetres: Double,
                                              spec: CheckerboardSpec,
                                              paper: PaperSize) {
        let rulerLength = 100.0 * pointsPerMillimetre
        let x = (pageRect.width - rulerLength) / 2
        let y = pageRect.height - 22 * pointsPerMillimetre

        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: x, y: y))
        cg.addLine(to: CGPoint(x: x + rulerLength, y: y))
        cg.strokePath()

        for millimetre in stride(from: 0.0, through: 100.0, by: 10.0) {
            let tickX = x + millimetre * pointsPerMillimetre
            let height = millimetre.truncatingRemainder(dividingBy: 50) == 0 ? 5.0 : 3.0
            cg.move(to: CGPoint(x: tickX, y: y))
            cg.addLine(to: CGPoint(x: tickX, y: y - height * pointsPerMillimetre))
            cg.strokePath()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.black,
        ]
        let caption = "This line must measure exactly 100 mm. If it does not, the "
                    + "page was scaled — reprint at 100% with no fit-to-page."
        caption.draw(at: CGPoint(x: x, y: y + 3 * pointsPerMillimetre),
                     withAttributes: attributes)

        let legend = String(format: "%d × %d inner corners · %.1f mm squares · %@",
                            spec.columns, spec.rows, squareMillimetres, paper.name)
        legend.draw(at: CGPoint(x: x, y: y + 9 * pointsPerMillimetre),
                    withAttributes: attributes)
    }

    /// Render a large board tiled across several sheets.
    ///
    /// Pages are **trim-and-butt**, not overlap-and-tape. Each sheet carries a
    /// hairline trim rectangle at its exact share of the board; you cut on the
    /// line and butt the cut edges together. Overlapping would be more
    /// forgiving to assemble and worse to assemble *correctly* — the seam
    /// hides underneath the upper sheet, so a two-millimetre misregistration
    /// is invisible, and a misregistered seam does not merely look untidy. It
    /// shifts every corner on one side of it, and the solver has no way to
    /// know: it fits a homography to a lattice it assumes is perfect and
    /// quietly returns intrinsics distorted by the error.
    ///
    /// Seams are allowed to fall wherever the page size puts them, including
    /// mid-square. That is deliberate. A seam that lands on a square boundary
    /// butts black against black and hides its own misalignment; one that
    /// crosses a square shows any error as a visible step in an edge that
    /// should be straight, which makes the assembly self-checking.
    public static func makeTiledPDF(spec: CheckerboardSpec,
                                    paper: PaperSize,
                                    squareMillimetres: Double,
                                    marginMillimetres: Double = 10) -> Data {

        let layout = tileLayout(spec: spec, paper: paper,
                                squareMillimetres: squareMillimetres,
                                marginMillimetres: marginMillimetres)

        let landscape = layout.boardWidthMillimetres >= layout.boardHeightMillimetres
        let pageWidthMM = landscape
            ? max(paper.widthMillimetres, paper.heightMillimetres)
            : min(paper.widthMillimetres, paper.heightMillimetres)
        let pageHeightMM = landscape
            ? min(paper.widthMillimetres, paper.heightMillimetres)
            : max(paper.widthMillimetres, paper.heightMillimetres)

        let pageRect = CGRect(x: 0, y: 0,
                              width: pageWidthMM * pointsPerMillimetre,
                              height: pageHeightMM * pointsPerMillimetre)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let squaresAcross = spec.columns + 1
        let squaresDown = spec.rows + 1
        let squarePoints = squareMillimetres * pointsPerMillimetre
        let quietPoints = quietZoneMillimetres * pointsPerMillimetre
        let marginPoints = marginMillimetres * pointsPerMillimetre
        let contentWidth = layout.pageContentWidth * pointsPerMillimetre
        let contentHeight = layout.pageContentHeight * pointsPerMillimetre

        return renderer.pdfData { context in
            for pageRow in 0..<layout.rowsOfPages {
                for pageColumn in 0..<layout.columnsOfPages {
                    context.beginPage()
                    let cg = context.cgContext

                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fill(pageRect)

                    cg.saveGState()

                    // Clip to this sheet's share of the board, then draw the
                    // whole board shifted so the correct window shows through.
                    // Drawing the entire board every page and clipping is both
                    // simpler and less error-prone than working out which
                    // squares intersect this tile.
                    let window = CGRect(x: marginPoints, y: marginPoints,
                                        width: contentWidth, height: contentHeight)
                    cg.clip(to: window)

                    // Board origin in page space: quiet zone first, then step
                    // back by the tiles already placed.
                    let originX = marginPoints + quietPoints
                        - Double(pageColumn) * contentWidth
                    let originY = marginPoints + quietPoints
                        - Double(pageRow) * contentHeight

                    cg.setFillColor(UIColor.black.cgColor)
                    for row in 0..<squaresDown {
                        for column in 0..<squaresAcross where (row + column) % 2 == 0 {
                            cg.fill(CGRect(x: originX + Double(column) * squarePoints,
                                           y: originY + Double(row) * squarePoints,
                                           width: squarePoints,
                                           height: squarePoints))
                        }
                    }
                    cg.restoreGState()

                    drawTrimGuides(in: cg, window: CGRect(x: marginPoints,
                                                          y: marginPoints,
                                                          width: contentWidth,
                                                          height: contentHeight))
                    drawTileLegend(in: cg,
                                   pageRect: pageRect,
                                   marginPoints: marginPoints,
                                   pageRow: pageRow,
                                   pageColumn: pageColumn,
                                   layout: layout,
                                   spec: spec)
                }
            }
        }
    }

    /// Corner crop marks, drawn *outside* the cut.
    ///
    /// No rectangle is stroked along the trim line itself. That was the first
    /// attempt and it is wrong for a reason that only shows up after
    /// assembly: cutting along a printed line leaves half its ink on the
    /// sheet, so every seam carries a hairline. Those hairlines land on the
    /// board, meet at tile corners, and give the corner detector X-junctions
    /// that belong to the paper rather than the pattern. Marks outside the cut
    /// define the same line and leave nothing behind — align a straight edge
    /// between opposing ticks.
    private static func drawTrimGuides(in cg: CGContext, window: CGRect) {
        let tick = 4.0 * pointsPerMillimetre
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(0.6)
        for (x, y, dx, dy) in [
            (window.minX, window.minY, -1.0, 0.0), (window.minX, window.minY, 0.0, -1.0),
            (window.maxX, window.minY, 1.0, 0.0), (window.maxX, window.minY, 0.0, -1.0),
            (window.minX, window.maxY, -1.0, 0.0), (window.minX, window.maxY, 0.0, 1.0),
            (window.maxX, window.maxY, 1.0, 0.0), (window.maxX, window.maxY, 0.0, 1.0),
        ] {
            cg.move(to: CGPoint(x: x, y: y))
            cg.addLine(to: CGPoint(x: x + dx * tick, y: y + dy * tick))
        }
        cg.strokePath()
    }

    /// Sheet position, assembly order, and the scale check, printed in the
    /// margin that gets cut off.
    private static func drawTileLegend(in cg: CGContext,
                                       pageRect: CGRect,
                                       marginPoints: Double,
                                       pageRow: Int,
                                       pageColumn: Int,
                                       layout: TileLayout,
                                       spec: CheckerboardSpec) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 7),
            .foregroundColor: UIColor.black,
        ]
        let index = pageRow * layout.columnsOfPages + pageColumn + 1
        let label = String(
            format: "Sheet %d of %d — row %d, column %d · %.0f mm squares · "
                  + "trim on the hairline, butt edges, do not overlap",
            index, layout.pageCount, pageRow + 1, pageColumn + 1,
            layout.squareMillimetres)
        label.draw(at: CGPoint(x: marginPoints, y: marginPoints * 0.25),
                   withAttributes: attributes)

        // Scale check on every sheet rather than only the first: sheets can be
        // printed in separate runs, and a target assembled from two different
        // scalings is non-uniform in a way nothing downstream can detect.
        let rulerLength = 50.0 * pointsPerMillimetre
        let y = pageRect.height - marginPoints * 0.45
        let x = marginPoints
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(0.8)
        cg.move(to: CGPoint(x: x, y: y))
        cg.addLine(to: CGPoint(x: x + rulerLength, y: y))
        for millimetre in stride(from: 0.0, through: 50.0, by: 10.0) {
            let tickX = x + millimetre * pointsPerMillimetre
            cg.move(to: CGPoint(x: tickX, y: y))
            cg.addLine(to: CGPoint(x: tickX, y: y - 2 * pointsPerMillimetre))
        }
        cg.strokePath()
        "50 mm — check on every sheet, all sheets must match"
            .draw(at: CGPoint(x: x + rulerLength + 4, y: y - 7),
                  withAttributes: attributes)
    }

    /// Write the PDF to a temporary file for sharing or printing.
    ///
    /// Tiles automatically whenever the requested square size does not fit one
    /// sheet, so callers do not have to decide which renderer to use.
    public static func writeTemporaryPDF(spec: CheckerboardSpec,
                                         paper: PaperSize = .a4,
                                         squareSizeMillimetres: Double? = nil) throws
        -> URL {
        let singlePageMaximum = largestFittingSquareSize(spec: spec, paper: paper)
        let requested = squareSizeMillimetres ?? singlePageMaximum

        let data = requested > singlePageMaximum
            ? makeTiledPDF(spec: spec, paper: paper, squareMillimetres: requested)
            : makePDF(spec: spec, paper: paper, squareSizeMillimetres: requested)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-target.pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
