import SwiftUI

struct BlankDoodleView: View {
    let doodle: Doodle
    
    var body: some View {
        GeometryReader { geometry in
            let rect = geometry.frame(in: .local)
            // One frame for the whole drawing, built from every point in it. Each colour segment
            // and both markers are placed through it, so they share a single scale and origin.
            let referencePoints = doodle.renderPoints
            let frame = PathRenderer.frame(for: referencePoints, in: rect)
            
            ZStack {
                // Pure white background
                Color.white

                // Scenery first, so the route is drawn over its own decoration. Positioned
                // through the same frame as the path, and at the same size the finished-walk
                // snapshot uses, so reopening a doodle shows the drawing that was saved.
                if !doodle.scenery.isEmpty, let frame {
                    SceneryView(
                        positionedScenery: PathRenderer.positionScenery(doodle.scenery, in: frame),
                        itemSize: 20
                    )
                }

                // Handle single point vs path doodles
                if doodle.points.count > 1, let frame {
                    if doodle.segments.isEmpty {
                        PathRenderer.makePath(from: doodle.points, in: frame, smoothness: 1.0)
                            .stroke(Color.primaryColor, lineWidth: 8)
                    } else {
                        ForEach(doodle.segments.indices, id: \.self) { idx in
                            let seg = doodle.segments[idx]
                            PathRenderer.makePath(from: seg.points, in: frame, smoothness: 1.0)
                                .stroke(Color(hex: seg.colorHex), lineWidth: 8)
                        }
                    }
                    
                    // Start/End markers, through the same frame as the path they sit on.
                    if let first = referencePoints.first {
                        Circle()
                            .fill(doodle.startColor)
                            .frame(width: 12, height: 12)
                            .position(PathRenderer.point(for: first, in: frame))
                    }
                    if let last = referencePoints.last {
                        Circle()
                            .stroke(Color.black, lineWidth: 2)
                            .frame(width: 12, height: 12)
                            .position(PathRenderer.point(for: last, in: frame))
                    }
                } else if doodle.points.first != nil {
                    // Single point doodle - draw as a prominent marker
                    let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
                    
                    // Outer ring
                    Circle()
                        .stroke(Color.black, lineWidth: 3)
                        .frame(width: 48, height: 48)
                        .position(centerPoint)
                    
                    // Inner filled circle
                    Circle()
                        .fill(doodle.startColor)
                        .frame(width: 36, height: 36)
                        .position(centerPoint)
                    
                    // Small center dot
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .position(centerPoint)
                }

                // The real places found along the walk, through the same frame as the path.
                if !doodle.illustrations.isEmpty, let frame {
                    ContextualIllustrationView(
                        positionedIllustrations: PathRenderer.positionIllustrations(doodle.illustrations, in: frame),
                        iconSize: 20
                    )
                }
            }
        }
        .background(Color.white)
        .colorScheme(.light)
        .preferredColorScheme(.light)
    }
}

#Preview {
    BlankDoodleView(doodle: Doodle(
        points: [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.1, longitude: 0.1),
            Coordinate(latitude: 0.2, longitude: 0.05)
        ],
        distance: 1234,
        duration: 1800
    ))
} 