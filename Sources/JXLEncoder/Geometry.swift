//
//  Geometry.swift
//  JXLEncoder
//
//  The tiling the reference encoder walks, from encoder/common.h and the
//  `ImageDim` / `RectT` helpers in encoder/enc_frame.cc and encoder/image.h.
//
//  This is not an implementation detail that can be papered over: the adaptive
//  quant field is computed per tile with overlapping context, so the quant
//  values depend on how the image is divided. Anything computed whole-plane
//  will not match the reference.
//

public enum Geometry {
	public static let blockDim = 8
	public static let dctBlockSize = blockDim * blockDim
	public static let groupDim = 256
	public static let groupDimInBlocks = groupDim / blockDim
	public static let dcGroupDim = groupDim * blockDim

	/// 64 when chroma-from-luma is enabled upstream; this port drops CfL, which
	/// is the `#else` branch of the reference's `kTileDim`.
	public static let tileDim = 16
	public static let tileDimInBlocks = tileDim / blockDim
	public static let groupDimInTiles = groupDim / tileDim

	public static func divCeil(_ value: Int, _ divisor: Int) -> Int {
		(value + divisor - 1) / divisor
	}

	public static func roundUp(_ value: Int, to align: Int) -> Int {
		divCeil(value, align) * align
	}
}

/// A window into an image. Windows are `sizeMax` wide except at the right and
/// bottom edges, where they are clipped to the image bounds.
public struct Rect: Equatable, Sendable {
	public let x0: Int
	public let y0: Int
	public let width: Int
	public let height: Int

	public init(x0: Int, y0: Int, width: Int, height: Int) {
		self.x0 = x0
		self.y0 = y0
		self.width = width
		self.height = height
	}

	public init(x0: Int, y0: Int, maxWidth: Int, maxHeight: Int, xEnd: Int, yEnd: Int) {
		self.x0 = x0
		self.y0 = y0
		width = Self.clampedSize(begin: x0, maxSize: maxWidth, end: xEnd)
		height = Self.clampedSize(begin: y0, maxSize: maxHeight, end: yEnd)
	}

	static func clampedSize(begin: Int, maxSize: Int, end: Int) -> Int {
		begin + maxSize <= end ? maxSize : (end > begin ? end - begin : 0)
	}

	public var isEmpty: Bool { width == 0 || height == 0 }
}

/// Derived tiling for one image size.
public struct ImageDim: Equatable, Sendable {
	public let width: Int
	public let height: Int
	public let widthInBlocks: Int
	public let heightInBlocks: Int
	public let widthInTiles: Int
	public let heightInTiles: Int
	public let widthInGroups: Int
	public let heightInGroups: Int
	public let widthInDCGroups: Int
	public let heightInDCGroups: Int

	public var groupCount: Int { widthInGroups * heightInGroups }
	public var dcGroupCount: Int { widthInDCGroups * heightInDCGroups }

	/// `blockAlignment` rounds the block grid up to a whole MCU, which chroma
	/// subsampling requires so the chroma planes divide evenly. The pixel path
	/// passes (1, 1) and gets the plain ceiling.
	public init(width: Int, height: Int, blockAlignment: (x: Int, y: Int) = (1, 1)) {
		self.width = width
		self.height = height
		widthInBlocks =
			Geometry.divCeil(
				Geometry.divCeil(width, Geometry.blockDim), blockAlignment.x)
			* blockAlignment.x
		heightInBlocks =
			Geometry.divCeil(
				Geometry.divCeil(height, Geometry.blockDim), blockAlignment.y)
			* blockAlignment.y
		widthInTiles = Geometry.divCeil(width, Geometry.tileDim)
		heightInTiles = Geometry.divCeil(height, Geometry.tileDim)
		widthInGroups = Geometry.divCeil(width, Geometry.groupDim)
		heightInGroups = Geometry.divCeil(height, Geometry.groupDim)
		widthInDCGroups = Geometry.divCeil(width, Geometry.dcGroupDim)
		heightInDCGroups = Geometry.divCeil(height, Geometry.dcGroupDim)
	}

	public func pixelRect(ix: Int, iy: Int, width dimX: Int, height dimY: Int) -> Rect {
		Rect(
			x0: ix * dimX, y0: iy * dimY, maxWidth: dimX, maxHeight: dimY,
			xEnd: width, yEnd: height)
	}

	public func pixelRect(ix: Int, iy: Int, dim: Int) -> Rect {
		pixelRect(ix: ix, iy: iy, width: dim, height: dim)
	}

	public func blockRect(ix: Int, iy: Int, width dimX: Int, height dimY: Int) -> Rect {
		Rect(
			x0: ix * dimX, y0: iy * dimY, maxWidth: dimX, maxHeight: dimY,
			xEnd: widthInBlocks, yEnd: heightInBlocks)
	}

	public func blockRect(ix: Int, iy: Int, dim: Int) -> Rect {
		blockRect(ix: ix, iy: iy, width: dim, height: dim)
	}

	public func tileRect(ix: Int, iy: Int, width dimX: Int, height dimY: Int) -> Rect {
		Rect(
			x0: ix * dimX, y0: iy * dimY, maxWidth: dimX, maxHeight: dimY,
			xEnd: widthInTiles, yEnd: heightInTiles)
	}

	/// The stripes the encoder walks: a group's width by one tile's height.
	/// The reference notes these must run in order, as later stripes depend on
	/// context from earlier ones, so only whole groups may run concurrently.
	public func stripeRect(groupX: Int, tileY: Int) -> Rect {
		pixelRect(ix: groupX, iy: tileY, width: Geometry.groupDim, height: Geometry.tileDim)
	}
}
