import Foundation

struct HeadPosition: Codable, Equatable, Sendable {
    var point: CGPoint
    var screenID: UInt32

    init(point: CGPoint = .zero, screenID: UInt32 = 0) {
        self.point = point
        self.screenID = screenID
    }
}
