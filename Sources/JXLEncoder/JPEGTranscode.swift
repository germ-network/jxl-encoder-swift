//
//  JPEGTranscode.swift
//  JXLEncoder
//
//  Presents a parsed JPEG in the layout the VarDCT back-end expects, so its
//  quantized coefficients can be re-coded without an inverse DCT. Mirrors the
//  ingestion in libjxl's `enc_frame.cc` (`ComputeJPEGTranscodingData`);
//  libjxl-tiny has no JPEG path, so this stage has no counterpart there.
//
//  Nothing here requantizes. The coefficients are carried across exactly as
//  the JPEG stored them, which is what makes the transcode lossless — the
//  differences are all in layout and signalling.
//

/// A parsed JPEG viewed as JXL channels.
public struct JPEGTranscode {
	public let image: JPEGImage
	public let subsampling: ChromaSubsampling
	/// JXL channel index to JPEG component index.
	public let componentMap: [Int]
	/// A single-component source. JXL still codes three channels, and the two
	/// chroma ones carry zeros rather than a copy of the luma.
	public let isGrayscale: Bool

	public enum TranscodeError: Error, Equatable, Sendable {
		/// Sampling factors JXL cannot express: it carries a 2-bit mode per
		/// channel, not arbitrary factors.
		case unsupportedSubsampling
		case unsupportedComponentCount(Int)
		/// A component naming a quantization table the file never defined.
		case missingQuantTable(index: Int)
	}

	public init(_ image: JPEGImage) throws {
		let count = image.components.count
		switch count {
		case 1:
			// Grey. Only channel 1 reads the component; libjxl zero-fills the
			// other two rather than repeating luma into them, which would decode
			// as a strong colour cast.
			componentMap = [0, 0, 0]
			isGrayscale = true
			subsampling = ChromaSubsampling(channelMode: [0, 0, 0])
		case 3:
			// libjxl's `JpegOrder` for kYCbCr. JXL orders channels X, Y, B, and
			// under a YCbCr colour transform that reads as Cb, Y, Cr — so the
			// first two components swap.
			componentMap = [1, 0, 2]
			isGrayscale = false
			guard
				let subsampling = ChromaSubsampling.fromJPEG(
					horizontalSampling: image.components.map(
						\.horizontalSampling),
					verticalSampling: image.components.map(\.verticalSampling))
			else { throw TranscodeError.unsupportedSubsampling }
			self.subsampling = subsampling
		default:
			throw TranscodeError.unsupportedComponentCount(count)
		}

		for component in image.components
		where component.quantTableIndex >= image.quantTables.count
			|| image.quantTables[component.quantTableIndex].count != 64
		{
			throw TranscodeError.missingQuantTable(index: component.quantTableIndex)
		}
		self.image = image
	}

	public var width: Int { image.width }
	public var height: Int { image.height }

	public func component(_ channel: Int) -> JPEGComponent {
		image.components[componentMap[channel]]
	}

	// MARK: - Quantization

	/// The channel's quantization table, transposed.
	///
	/// JXL transposes the DCT relative to JPEG, so a table indexed `[y][x]`
	/// there is indexed `[x][y]` here.
	public func quantTable(channel: Int) -> [UInt16] {
		let table = image.quantTables[component(channel).quantTableIndex]
		var transposed = [UInt16](repeating: 0, count: 64)
		for y in 0..<8 {
			for x in 0..<8 {
				transposed[8 * x + y] = table[8 * y + x]
			}
		}
		return transposed
	}

	/// DC quantization step for this channel, as JXL expresses it.
	///
	/// JPEG stores a divisor; JXL wants the multiplier that undoes it, scaled by
	/// the 255 × 8 that separates the two conventions.
	public func dcQuantization(channel: Int) -> Float {
		let table = image.quantTables[component(channel).quantTableIndex]
		return 255 * 8 / Float(table[0])
	}

	// MARK: - Coefficients

	/// Blocks this channel carries, in its own subsampled grid.
	public func blocksPerLine(channel: Int) -> Int {
		component(channel).blocksPerLine
	}

	public func blocksPerColumn(channel: Int) -> Int {
		component(channel).blocksPerColumn
	}

	/// One block in JXL layout: transposed, DC included at index 0.
	///
	/// The DC is carried across untouched. libjxl offsets it by `1024 / qt[0]`
	/// only when the colour transform is `kNone`; under YCbCr — which is what a
	/// JPEG transcode signals — it takes the stored value as is.
	public func block(channel: Int, x: Int, y: Int) -> [Int32] {
		let component = component(channel)
		let offset = (y * component.blocksPerLine + x) * 64
		var block = [Int32](repeating: 0, count: 64)
		for row in 0..<8 {
			for column in 0..<8 {
				block[column * 8 + row] =
					component.coefficients[offset + row * 8 + column]
			}
		}
		return block
	}

	/// The channel's DC coefficient at a block position, unscaled.
	public func dc(channel: Int, x: Int, y: Int) -> Int32 {
		let component = component(channel)
		return component.coefficients[(y * component.blocksPerLine + x) * 64]
	}
}
