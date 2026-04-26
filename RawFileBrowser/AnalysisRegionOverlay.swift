import SwiftUI

/// Draws a labelled rectangle over the region used for focus analysis.
/// normRect is in normalised 0-1 coords (top-left origin).
/// The overlay correctly accounts for letterboxing when the image is
/// scaledToFit inside its container.
struct AnalysisRegionOverlay: View {
    let normRect: CGRect
    let imageSize: CGSize
    let containerSize: CGSize
    let region: FocusResult.AnalysisRegion
    let scale: CGFloat
    var offset: CGSize = .zero

    /// Compute the actual pixel rect of the image inside the container,
    /// accounting for letterbox bars added by scaledToFit.
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

    private var screenRect: CGRect {
        imageFrame.projectedToScreen(normRect: normRect, scale: scale, offset: offset)
    }

    private var overlayColor: Color {
        switch region {
        case .animalEyes, .humanEyes:  return .green
        case .animalHead, .humanFace:  return .yellow
        case .animalBody:              return .orange
        case .afPoint, .afAndSubject:  return .cyan
        default:                       return .white
        }
    }

    var body: some View {
        let r = screenRect
        ZStack(alignment: .topLeading) {
            // Dashed border
            Rectangle()
                .strokeBorder(
                    overlayColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                )
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)

            // Corner marks for clarity
            CornerMarks(rect: r, color: overlayColor, size: 10)

            // Label
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
        .allowsHitTesting(false)  // Don't intercept touch gestures
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
