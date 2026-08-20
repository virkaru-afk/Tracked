import SwiftUI
import PDFKit
import UIKit

/// Produce the calibration target, before lens calibration can happen.
///
/// This screen exists because the checkerboard is the one part of the setup
/// the app cannot supply. Every other prerequisite is software; this one is a
/// piece of paper the user has to make, and getting it wrong is both easy and
/// silent — a curled sheet or a "fit to page" print produces a calibration
/// that converges happily to the wrong answer.
public struct CheckerboardSetupView: View {

    @State private var paper: CheckerboardGenerator.PaperSize = .a4
    @State private var spec = CheckerboardSpec()
    @State private var pdfURL: URL?
    @State private var showingShare = false
    @State private var errorMessage: String?

    /// Requested square size. `nil` means "whatever fills one sheet", which is
    /// the old single-page behaviour.
    @State private var squareSizeChoice: Double?

    public init() {}

    private var singlePageSquareSize: Double {
        CheckerboardGenerator.largestFittingSquareSize(spec: spec, paper: paper)
    }

    private var squareSize: Double { squareSizeChoice ?? singlePageSquareSize }

    private var layout: CheckerboardGenerator.TileLayout {
        CheckerboardGenerator.tileLayout(spec: spec, paper: paper,
                                         squareMillimetres: squareSize)
    }

    private var usableDistance: Double {
        CheckerboardGenerator.usableDistanceMetres(spec: spec,
                                                   squareMillimetres: squareSize)
    }

    /// Offered sizes, one page up to roughly a metre of board.
    ///
    /// Presented as working distances rather than millimetres because that is
    /// the decision actually being made. Nobody wants 80 mm squares; they want
    /// to calibrate at two metres, which is where the tripod has to stand for
    /// the runway to be in focus at the same time.
    private var sizeOptions: [Double?] {
        [nil, 60, 80, 100].filter { candidate in
            guard let candidate else { return true }
            return candidate > singlePageSquareSize
        }
    }

    public var body: some View {
        List {
            Section {
                Picker("Paper", selection: $paper) {
                    ForEach(CheckerboardGenerator.PaperSize.all, id: \.name) { size in
                        Text(size.name).tag(size)
                    }
                }
                LabeledContent("Grid", value: "\(spec.columns) × \(spec.rows) inner corners")

                Picker("Board size", selection: $squareSizeChoice) {
                    ForEach(sizeOptions, id: \.self) { option in
                        if let option {
                            Text(String(format: "%.0f mm squares — %d sheets",
                                        option,
                                        CheckerboardGenerator.tileLayout(
                                            spec: spec, paper: paper,
                                            squareMillimetres: option).pageCount))
                                .tag(Optional(option))
                        } else {
                            Text(String(format: "Single sheet — %.0f mm squares",
                                        singlePageSquareSize))
                                .tag(Optional<Double>.none)
                        }
                    }
                }

                LabeledContent("Board", value: layout.summary)
                LabeledContent("Works out to",
                               value: String(format: "%.1f m", usableDistance))
            } header: {
                Text("Target")
            } footer: {
                Text("\"Works out to\" is the furthest the app will still accept this "
                     + "board — beyond it the board covers under 6% of the frame and "
                     + "capture is refused.\n\nThat number is the whole reason to print "
                     + "more than one sheet. Focus has to be pinned somewhere that keeps "
                     + "both the board and the runway sharp, and a single sheet only "
                     + "reaches about a metre, which is far closer than any tripod will "
                     + "stand. Multi-sheet targets trim and butt together — cut on the "
                     + "hairline, do not overlap — and must be mounted dead flat.")
            }

            Section {
                if let pdfURL {
                    PDFPreview(url: pdfURL)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                }
                Button {
                    generate()
                } label: {
                    Label(pdfURL == nil ? "Generate target" : "Regenerate",
                          systemImage: "doc.badge.gearshape")
                }
                if pdfURL != nil {
                    Button {
                        showingShare = true
                    } label: {
                        Label("Print or save", systemImage: "printer")
                    }
                }
            } header: {
                Text("Preview")
            }

            printingRules
            whatMattersSection
        }
        .navigationTitle("Calibration target")
        .navigationBarTitleDisplayMode(.inline)
        .task { if pdfURL == nil { generate() } }
        .sheet(isPresented: $showingShare) {
            if let pdfURL {
                ShareSheet(items: [pdfURL])
            }
        }
        .alert("Could not generate", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var printingRules: some View {
        Section {
            rule(number: 1,
                 title: "Print at 100%",
                 detail: "Turn off \"fit to page\" and \"scale to fit\". Then check "
                       + "the ruler printed at the bottom measures exactly 100 mm. "
                       + "A scaled page is usually scaled unevenly, and uneven "
                       + "scaling makes the squares non-square — which the solver "
                       + "absorbs into a false lens aspect ratio.")
            rule(number: 2,
                 title: "Mount it on something rigid",
                 detail: "Glue or tape the sheet to foam board, stiff card, or a "
                       + "clipboard. A page held in the hand curls by a few "
                       + "millimetres, which breaks the flat-plane assumption the "
                       + "whole method rests on. This is the largest practical "
                       + "error source and it leaves no trace in the result.")
            rule(number: 3,
                 title: "Matte paper, not glossy",
                 detail: "Glossy stock throws specular highlights that the corner "
                       + "detector reads as real structure.")
        } header: {
            Text("Printing")
        }
    }

    private var whatMattersSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("You do not need to measure the squares")
                        .font(.subheadline.weight(.semibold))
                    Text("The recovered focal length does not depend on the printed "
                         + "square size. Uniformly scaling the board is absorbed into "
                         + "the board's apparent distance, which nothing downstream "
                         + "uses. Flatness and even scaling are what matter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }

            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("You do need to measure the reference pipe")
                        .font(.subheadline.weight(.semibold))
                    Text("That one is the opposite case. The pipe's height sets the "
                         + "scale of every distance the app reports, so a 1% error "
                         + "there is 1% on every hop and step. Measure it with a tape "
                         + "and enter the real number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("What accuracy actually depends on")
        }
    }

    private func rule(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func generate() {
        do {
            pdfURL = try CheckerboardGenerator.writeTemporaryPDF(
                spec: spec,
                paper: paper,
                squareSizeMillimetres: squareSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Inline PDF preview.
struct PDFPreview: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// Share sheet, used for printing and for exporting session data.
struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
