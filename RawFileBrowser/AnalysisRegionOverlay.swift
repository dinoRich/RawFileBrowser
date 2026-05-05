import SwiftUI

/// Draws the focus analysis overlays on top of the image:
///  • A soft dashed silhouette path tracing the detected subject (from foreground mask)
///  • A dashed scoring rect (eyes / head / AF point) with corner marks and label
///
/// All coordinates are in normalised 0-1 space (top-left origin) and are mapped
/// to screen space accounting for letterboxing when the image is scaledToFit.
struct AnalysisRegionOverlay: View {
    let normRect: CGRect
    let imageSize: CGSize
    let containerSize: CGSize
    let region: FocusResult.AnalysisRegion
    let scale: CGFloat
    var offset: CGSize = .zero
    /// Normalised subject silhouette contour points from the foreground mask.
    /// When present, drawn as a path instead of a bounding box.
    var subjectContour: [CGPoint]? = nil
    /// Species label shown below the contour (e.g. "Robin").
    var detectedLabel: String? = nil

    // MARK: - Coordinate mapping

    /// The actual rendered rect of the image inside the container,
    /// accounting for letterbox bars from scaledToFit.
    private var imageFrame: CGRect {
        let imageAspect     = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        let renderedW, renderedH: CGFloat
        if imageAspect > containerAspect {
            renderedW = containerSize.width
            renderedH = containerSize.width / imageAspect
        } else {
            renderedH = containerSize.height
            renderedW = containerSize.height * imageAspect
        }
        let offsetX = (containerSize.width  - renderedW) / 2
        let offsetY = (containerSize.height - renderedH) / 2
        return CGRect(x: offsetX, y: offsetY, width: renderedW, height: renderedH)
    }

    /// Map a single normalised point to screen space, applying zoom scale and pan offset.
    private func toScreen(_ normPt: CGPoint) -> CGPoint {
        let frame = imageFrame
        let baseX = frame.minX + normPt.x * frame.width
        let baseY = frame.minY + normPt.y * frame.height
        // Apply the same zoom/pan transform used by the image itself
        let cx = containerSize.width  / 2
        let cy = containerSize.height / 2
        return CGPoint(
            x: cx + (baseX - cx) * scale + offset.width,
            y: cy + (baseY - cy) * scale + offset.height
        )
    }

    private var screenRect: CGRect {
        imageFrame.projectedToScreen(normRect: normRect, scale: scale, offset: offset)
    }

    private var overlayColor: Color {
        switch region {
        case .animalEyes, .humanEyes:               return .green
        case .animalHead, .humanFace:               return .yellow
        case .animalBody:                           return .orange
        case .afOnSubject, .afPoint, .missedFocus:  return .cyan
        default:                                    return .white
        }
    }

    // MARK: - Body

    var body: some View {
        let r = screenRect
        ZStack(alignment: .topLeading) {

            // ── Subject silhouette contour ─────────────────────────────────────
            if let pts = subjectContour, pts.count > 2 {
                // Build screen-space path from the normalised contour points
                let screenPts = pts.map { toScreen($0) }
                let contourPath = Path { path in
                    path.move(to: screenPts[0])
                    for pt in screenPts.dropFirst() {
                        path.addLine(to: pt)
                    }
                    path.closeSubpath()
                }

                // Soft filled tint so the subject area is subtly highlighted
                contourPath
                    .fill(overlayColor.opacity(0.08))

                // Dashed stroke outline
                contourPath
                    .stroke(
                        overlayColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )

                // Species label — positioned below the contour's bounding box
                if let label = detectedLabel {
                    let maxY = screenPts.map(\.y).max() ?? r.maxY
                    let minX = screenPts.map(\.x).min() ?? r.minX
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(overlayColor.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(
                            x: minX,
                            y: min(maxY + 2, containerSize.height - 20)
                        )
                }
            }

            // ── Scoring region (eyes / head / AF point) ───────────────────────
            Rectangle()
                .strokeBorder(
                    overlayColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                )
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)

            CornerMarks(rect: r, color: overlayColor, size: 10)

            Text(region.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(overlayColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .offset(
                    x: r.minX,
                    y: max(0, r.minY - 18)
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Corner marks

private struct CornerMarks: View {
    let rect: CGRect
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Top-left
            CornerMark(corner: .topLeft, size: size, color: color)
                .offset(x: rect.minX, y: rect.minY)
            // Top-right
            CornerMark(corner: .topRight, size: size, color: color)
                .offset(x: rect.maxX - size, y: rect.minY)
            // Bottom-left
            CornerMark(corner: .bottomLeft, size: size, color: color)
                .offset(x: rect.minX, y: rect.maxY - size)
            // Bottom-right
            CornerMark(corner: .bottomRight, size: size, color: color)
                .offset(x: rect.maxX - size, y: rect.maxY - size)
        }
    }
}

private struct CornerMark: View {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    let corner: Corner
    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            switch corner {
            case .topLeft:
                path.move(to: CGPoint(x: 0, y: size))
                path.addLine(to: .zero)
                path.addLine(to: CGPoint(x: size, y: 0))
            case .topRight:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: size, y: 0))
                path.addLine(to: CGPoint(x: size, y: size))
            case .bottomLeft:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: size))
                path.addLine(to: CGPoint(x: size, y: size))
            case .bottomRight:
                path.move(to: CGPoint(x: size, y: 0))
                path.addLine(to: CGPoint(x: size, y: size))
                path.addLine(to: CGPoint(x: 0, y: size))
            }
            ctx.stroke(path, with: .color(color), lineWidth: 2)
        }
        .frame(width: size, height: size)
    }
}
