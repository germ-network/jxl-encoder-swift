//
//  StreamingPlan.swift
//  JXLEncoder
//
//  How libjxl lays out a pixel frame at -e 4: one-shot, or streaming with one
//  DC group processed at a time (enc_frame.cc CanDoStreamingEncoding
//  1801-1867, EncodeFrameStreaming 2047-2306). Swift's configuration is fixed
//  at XYB VarDCT with default buffering and no noise, patches, progressive
//  passes, lossy palette or modular colour, so of CanDoStreamingEncoding's
//  conditions only resampling and the group count can vary on the pixel path;
//  JPEG frames never stream (enc_frame.cc:1831).
//

/// The frame-level layout decision every pixel driver must share.
enum FramePlan: Equatable, Sendable {
	/// At most eight AC groups, or a resampled frame: one histogram set.
	case oneShot
	/// One histogram set per DC group, in raster order (output_mode 0, so the
	/// sections themselves keep canonical order).
	case streaming(dcGroups: [DCGroupLifecycle])

	/// `dim` is the frame as coded, after any resampling.
	init(dim: ImageDim, upsampling: Int) {
		guard upsampling == 1, dim.groupCount > Self.maxOneShotGroups else {
			self = .oneShot
			return
		}
		let size = Geometry.dcGroupDim
		self = .streaming(
			dcGroups: (0..<dim.dcGroupCount).map { index in
				let crop = dim.pixelRect(
					ix: index % dim.widthInDCGroups,
					iy: index / dim.widthInDCGroups,
					dim: size)
				let border = Geometry.blockDim
				let x0 = max(crop.x0 - border, 0)
				let y0 = max(crop.y0 - border, 0)
				let patch = Rect(
					x0: x0, y0: y0,
					width: min(crop.x0 + crop.width + border, dim.width) - x0,
					height: min(crop.y0 + crop.height + border, dim.height) - y0
				)
				return DCGroupLifecycle(index: index, crop: crop, patch: patch)
			})
	}

	private static let maxOneShotGroups = 8

	/// Empty when one-shot: the reference has no per-DC-group lifecycle then.
	var dcGroups: [DCGroupLifecycle] {
		if case .streaming(let groups) = self { return groups }
		return []
	}

	/// libjxl `num_histograms` (enc_frame.cc:2076).
	var histogramSetCount: Int {
		max(dcGroups.count, 1)
	}

	/// libjxl `histo_selector_bits`, CeilLog2Nonzero(num_histograms)
	/// (enc_group.cc:543-561).
	var selectorBits: Int {
		FrameAssembly.ceilLog2(histogramSetCount)
	}

	/// The histogram set an AC group selects: the index of the DC group that
	/// contains it, or 0 when one-shot.
	func histogramIndex(groupX: Int, groupY: Int) -> Int {
		let x = groupX * Geometry.groupDim
		let y = groupY * Geometry.groupDim
		return dcGroups.first {
			x >= $0.crop.x0 && x < $0.crop.x0 + $0.crop.width && y >= $0.crop.y0
				&& y < $0.crop.y0 + $0.crop.height
		}?.index ?? 0
	}
}

/// One DC group's pass through EncodeFrameStreaming: the pixels it owns and
/// the bordered patch it is processed from (enc_frame.cc:1563-1567,
/// 1633-1634).
struct DCGroupLifecycle: Equatable, Sendable {
	/// Raster index, which is also its histogram set.
	let index: Int
	/// The DC group's own pixels.
	let crop: Rect
	/// `crop` extended by `Geometry.blockDim` on every side, clipped to the
	/// frame.
	let patch: Rect

	/// Only the first DC group computes frame-global state.
	var initializesGlobalState: Bool { index == 0 }

	/// `patch` rounded up to whole blocks.
	var paddedWidth: Int { Geometry.roundUp(patch.width, to: Geometry.blockDim) }

	var paddedHeight: Int { Geometry.roundUp(patch.height, to: Geometry.blockDim) }

	/// `crop` relative to `patch`, its size rounded up to whole blocks.
	var groupRect: Rect {
		Rect(
			x0: crop.x0 - patch.x0, y0: crop.y0 - patch.y0,
			width: Geometry.roundUp(crop.width, to: Geometry.blockDim),
			height: Geometry.roundUp(crop.height, to: Geometry.blockDim))
	}

	var widthInBlocks: Int { groupRect.width / Geometry.blockDim }

	var heightInBlocks: Int { groupRect.height / Geometry.blockDim }
}
