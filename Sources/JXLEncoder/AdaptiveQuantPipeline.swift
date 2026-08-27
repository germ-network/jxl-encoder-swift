//
//  AdaptiveQuantPipeline.swift
//  JXLEncoder
//

enum AdaptiveQuantPipeline {
	/// Converts a padded stripe of linear samples to planar XYB.
	static func toXYB(_ stripe: PaddedStripe) -> PaddedStripe {
		let count = stripe.width * stripe.height
		var interleaved = [Float](repeating: 0, count: count * 3)
		for i in 0..<count {
			for c in 0..<3 { interleaved[i * 3 + c] = stripe.planes[c][i] }
		}
		let xyb = XYB.toXYB(linearRGB: interleaved, pixelCount: count)
		return PaddedStripe(
			width: stripe.width, height: stripe.height,
			planes: [xyb.x, xyb.y, xyb.b])
	}
}
