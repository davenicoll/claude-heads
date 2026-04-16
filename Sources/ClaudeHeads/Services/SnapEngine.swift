import Foundation

// MARK: - SnapEngine

/// Provides magnetic snapping behaviour between floating heads, allowing them to snap
/// edge-to-edge and move as a group when dragged.
struct SnapEngine {

    // MARK: - Snap Position

    /// Returns an adjusted position that snaps the head to nearby heads if within range.
    ///
    /// Snapping is evaluated independently on each axis so that a head can snap
    /// horizontally, vertically, or both at the same time.
    ///
    /// - Parameters:
    ///   - headID: The ID of the head being moved.
    ///   - proposedPosition: Where the user is dragging the head.
    ///   - allHeads: All current heads (including the one being moved).
    ///   - headSize: Diameter of a head (assumed uniform).
    ///   - snapDistance: Maximum distance (in points) at which snapping activates.
    /// - Returns: The snapped position, or the proposed position if no snap applies.
    func snapPosition(
        for headID: UUID,
        proposedPosition: CGPoint,
        allHeads: [HeadInstance],
        headSize: CGFloat,
        snapDistance: CGFloat
    ) -> CGPoint {
        var resultX = proposedPosition.x
        var resultY = proposedPosition.y
        var bestDX = snapDistance
        var bestDY = snapDistance

        for other in allHeads where other.id != headID {
            let ox = other.position.x
            let oy = other.position.y

            // Vertical alignment check (centres within snap distance on Y)
            let dy = abs(proposedPosition.y - oy)
            if dy < headSize + snapDistance {
                // Snap to the right edge of `other`
                let snapRight = ox + headSize
                let dxRight = abs(proposedPosition.x - snapRight)
                if dxRight < bestDX {
                    bestDX = dxRight
                    resultX = snapRight
                }

                // Snap to the left edge of `other`
                let snapLeft = ox - headSize
                let dxLeft = abs(proposedPosition.x - snapLeft)
                if dxLeft < bestDX {
                    bestDX = dxLeft
                    resultX = snapLeft
                }
            }

            // Horizontal alignment check (centres within snap distance on X)
            let dx = abs(proposedPosition.x - ox)
            if dx < headSize + snapDistance {
                // Snap below `other`
                let snapBelow = oy + headSize
                let dyBelow = abs(proposedPosition.y - snapBelow)
                if dyBelow < bestDY {
                    bestDY = dyBelow
                    resultY = snapBelow
                }

                // Snap above `other`
                let snapAbove = oy - headSize
                let dyAbove = abs(proposedPosition.y - snapAbove)
                if dyAbove < bestDY {
                    bestDY = dyAbove
                    resultY = snapAbove
                }
            }

            // Also allow snapping to the same centre axis for neat stacking
            if dy < snapDistance {
                let dyCentre = abs(proposedPosition.y - oy)
                if dyCentre < bestDY {
                    bestDY = dyCentre
                    resultY = oy
                }
            }
            if dx < snapDistance {
                let dxCentre = abs(proposedPosition.x - ox)
                if dxCentre < bestDX {
                    bestDX = dxCentre
                    resultX = ox
                }
            }
        }

        return CGPoint(x: resultX, y: resultY)
    }

    // MARK: - Snap Groups

    /// Recalculates snap groups after a drag ends. Two heads are in the same group if their
    /// edges are touching (distance between centres equals `headSize` on one axis while the
    /// other axis centres differ by at most `headSize`).
    func updateSnapGroups(
        _ heads: inout [HeadInstance],
        headSize: CGFloat,
        snapDistance: CGFloat
    ) {
        let tolerance = snapDistance * 0.5 // Allow a small tolerance for floating-point
        let count = heads.count

        // Build an adjacency list
        var adjacency = [[Int]](repeating: [], count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                if areTouching(heads[i].position, heads[j].position, headSize: headSize, tolerance: tolerance) {
                    adjacency[i].append(j)
                    adjacency[j].append(i)
                }
            }
        }

        // BFS / connected-components to assign group IDs
        var visited = [Bool](repeating: false, count: count)

        for i in 0..<count {
            guard !visited[i] else { continue }

            var component = [Int]()
            var queue = [i]
            visited[i] = true

            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.append(current)
                for neighbor in adjacency[current] where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }

            if component.count > 1 {
                let groupID = UUID()
                for index in component {
                    heads[index].snapGroupID = groupID
                }
            } else {
                heads[component[0]].snapGroupID = nil
            }
        }
    }

    // MARK: - Group Movement

    /// Moves all heads in the same snap group as `anchorID` by the given delta.
    func moveGroup(
        anchorID: UUID,
        delta: CGVector,
        heads: inout [HeadInstance]
    ) {
        guard let anchor = heads.first(where: { $0.id == anchorID }),
              let groupID = anchor.snapGroupID
        else { return }

        for head in heads where head.snapGroupID == groupID {
            head.position = CGPoint(
                x: head.position.x + delta.dx,
                y: head.position.y + delta.dy
            )
        }
    }

    // MARK: - Helpers

    /// Determines whether two heads are touching (edge-to-edge) given their centre positions.
    private func areTouching(
        _ a: CGPoint,
        _ b: CGPoint,
        headSize: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        let dx = abs(a.x - b.x)
        let dy = abs(a.y - b.y)

        // Touching horizontally: centres are exactly headSize apart on X, and
        // within headSize on Y (allowing diagonal-adjacent)
        let touchH = abs(dx - headSize) <= tolerance && dy <= headSize + tolerance

        // Touching vertically
        let touchV = abs(dy - headSize) <= tolerance && dx <= headSize + tolerance

        return touchH || touchV
    }
}
