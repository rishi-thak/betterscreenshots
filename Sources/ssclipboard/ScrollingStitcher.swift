import CoreGraphics
import Foundation

enum ScrollingStitcher {
    static func stitch(frames images: [CGImage]) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let width = images[0].width

        let pixelData = images.compactMap { image -> (CGImage, [[UInt32]])? in
            guard image.width == width else { return nil }
            let rows = allRows(of: image)
            return (image, rows)
        }
        guard !pixelData.isEmpty else { return images.first }

        var tiles: [CGImage] = [pixelData[0].0]
        var uniqueRowCounts: [Int] = [pixelData[0].0.height]

        for index in 1 ..< pixelData.count {
            let (_, prevRows) = pixelData[index - 1]
            let (currentImage, currentRows) = pixelData[index]
            let overlap = findOverlap(prevRows: prevRows, currRows: currentRows)
            let uniqueRows = currentImage.height - overlap
            guard uniqueRows > 4 else { continue }
            tiles.append(currentImage)
            uniqueRowCounts.append(uniqueRows)
        }

        let totalHeight = pixelData[0].0.height + uniqueRowCounts.dropFirst().reduce(0, +)
        guard totalHeight > pixelData[0].0.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return images[0]
        }

        var yBottom = 0
        for (index, tile) in tiles.enumerated().reversed() {
            let drawHeight = uniqueRowCounts[index]
            let sourceY = index == 0 ? 0 : (tile.height - drawHeight)
            if let cropped = tile.cropping(to: CGRect(x: 0, y: sourceY, width: width, height: drawHeight)) {
                context.draw(cropped, in: CGRect(x: 0, y: yBottom, width: width, height: drawHeight))
            }
            yBottom += drawHeight
        }

        return context.makeImage()
    }

    static func imagesLookSame(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        let lhsRows = allRows(of: lhs)
        let rhsRows = allRows(of: rhs)
        guard lhsRows.count >= 4, rhsRows.count >= 4 else { return false }
        let sampleStride = max(1, lhs.width / 32)
        return (0 ..< 4).allSatisfy { rowsMatch(lhsRows[$0], rhsRows[$0], strideBy: sampleStride) }
    }

    private static func findOverlap(prevRows: [[UInt32]], currRows: [[UInt32]]) -> Int {
        let prevHeight = prevRows.count
        let currHeight = currRows.count
        let maxCheck = min(prevHeight, currHeight) / 2
        let sampleStride = max(1, (prevRows.first?.count ?? 1) / 32)

        for overlap in stride(from: maxCheck, through: 4, by: -1) {
            var matches = true
            for rowIndex in 0 ..< min(overlap, 8) {
                let prevRow = prevRows[prevHeight - overlap + rowIndex]
                let currRow = currRows[rowIndex]
                if !rowsMatch(prevRow, currRow, strideBy: sampleStride) {
                    matches = false
                    break
                }
            }
            if matches { return overlap }
        }
        return 0
    }

    private static func allRows(of image: CGImage) -> [[UInt32]] {
        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else {
            return []
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointer = data.bindMemory(to: UInt32.self, capacity: width * height)
        return (0 ..< height).map { visualRow in
            let memoryRow = height - 1 - visualRow
            return Array(UnsafeBufferPointer(start: pointer + memoryRow * width, count: width))
        }
    }

    private static func rowsMatch(_ lhs: [UInt32], _ rhs: [UInt32], strideBy stride: Int) -> Bool {
        var index = 0
        while index < lhs.count {
            if abs(Int32(bitPattern: lhs[index]) - Int32(bitPattern: rhs[index])) > 0x0A0A0A {
                return false
            }
            index += stride
        }
        return true
    }
}
