import Foundation
import Testing

@testable import JXLEncoder

@Suite("Automatic pixel resampling")
struct PixelResamplingTests {
	private final class CallCounter: @unchecked Sendable {
		private let lock = NSLock()
		private var value = 0

		func increment() {
			lock.lock()
			value += 1
			lock.unlock()
		}

		var count: Int {
			lock.lock()
			defer { lock.unlock() }
			return value
		}
	}

	@Test func sharperKernelPreservesConstantsAndBoundsRinging() {
		let constants = PaddedStripe(
			width: 16, height: 16,
			planes: [
				[Float](repeating: 0.5, count: 256),
				[Float](repeating: -0.125, count: 256),
				[Float](repeating: 2, count: 256),
			])
		let constantResult = PixelDownsampler.downsample2(constants)
		#expect(constantResult.width == 8 && constantResult.height == 8)
		#expect(
			constantResult.planes.allSatisfy { plane in
				plane.allSatisfy { $0 == plane[0] }
			})
		#expect(constantResult.planes.map { $0[0] } == [0.5, -0.125, 2])

		var impulse = [Float](repeating: 0, count: 24 * 24)
		impulse[12 * 24 + 12] = 1
		let impulseResult = PixelDownsampler.downsample2(
			PaddedStripe(
				width: 24, height: 24,
				planes: [
					impulse, [Float](repeating: 0, count: 576),
					[Float](repeating: 0, count: 576),
				]))
		let centerIndex = 6 * impulseResult.width + 6
		let center = impulseResult.planes[0][centerIndex]
		#expect(abs(center - 0.4146601) < 0.000001)
		#expect(center >= 0 && center <= 1)
		let maxLobe =
			impulseResult.planes[0].enumerated()
			.filter { $0.offset != centerIndex }
			.map { abs($0.element) }
			.max() ?? 0
		#expect(maxLobe < 0.001)

		var asymmetric: [Float] = []
		for y in 0..<24 {
			for x in 0..<24 {
				let sample = ((x * 17 + y * 31) % 23) - 11
				asymmetric.append(Float(sample) * 0.125)
			}
		}
		let asymmetricResult = PixelDownsampler.downsample2(
			PaddedStripe(
				width: 24, height: 24,
				planes: [asymmetric, asymmetric, asymmetric]))
		#expect(
			asymmetricResult.planes[0][6 * asymmetricResult.width + 6].bitPattern
				== 0xBF20_2D23)
	}

	@Test
	func preprocessingPadsBeforeFilteringAndKeepsCodedGeometry() throws {
		let singletonCounter = CallCounter()
		let singleton = Encoder.preparePixelFrame(
			stripeAt: { rect in
				singletonCounter.increment()
				return PlaneBuffer.copyAndPad(
					source: [Float](repeating: 0.5, count: 3),
					sourceWidth: 1, rect: rect)
			},
			width: 1, height: 1, params: try DistanceParams(distance: 10))
		#expect(singleton.dim.width == 1 && singleton.dim.height == 1)
		#expect(singletonCounter.count == 1)
		let singletonStorage = singleton.xybAt(Rect(x0: 0, y0: 0, width: 1, height: 1))
		#expect(singletonStorage.width == 8 && singletonStorage.height == 8)
		#expect(singletonStorage.planes.allSatisfy { Set($0).count == 1 })

		let width = 9
		let height = 9
		let pixels = (0..<(width * height * 3)).map { Float(($0 * 37) % 251) / 250 }
		let calls = CallCounter()
		let prepared = Encoder.preparePixelFrame(
			stripeAt: { rect in
				calls.increment()
				return PlaneBuffer.copyAndPad(
					source: pixels, sourceWidth: width, rect: rect)
			},
			width: width, height: height, params: try DistanceParams(distance: 10))
		#expect(prepared.dim.width == 5 && prepared.dim.height == 5)
		#expect(calls.count == 1)
		let actual = prepared.xybAt(Rect(x0: 0, y0: 0, width: 5, height: 5))
		#expect(actual.width == 8 && actual.height == 8)
		#expect(calls.count == 1)

		let originalRect = Rect(x0: 0, y0: 0, width: width, height: height)
		let padded = PlaneBuffer.copyAndPad(
			source: pixels, sourceWidth: width, rect: originalRect)
		let expected = PixelDownsampler.downsample2(
			AdaptiveQuantPipeline.toXYB(padded))
		#expect(actual.planes == expected.planes)

		let lazyCalls = CallCounter()
		let lazy = Encoder.preparePixelFrame(
			stripeAt: { rect in
				lazyCalls.increment()
				return PlaneBuffer.copyAndPad(
					source: pixels, sourceWidth: width, rect: rect)
			},
			width: width, height: height,
			params: try DistanceParams(distance: Float(10).nextDown))
		#expect(lazy.dim.width == width && lazy.dim.height == height)
		#expect(lazyCalls.count == 0)
		_ = lazy.xybAt(Rect(x0: 0, y0: 0, width: 8, height: 8))
		#expect(lazyCalls.count == 1)
	}

	@Test
	func frameHeaderSignalsFactorTwoAndLeavesJPEGUnchanged() {
		var pixel = BitWriter()
		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: 3),
			loopFilter: .init(gaborish: false, epfIterations: 2),
			upsampling: 2, writer: &pixel)
		pixel.zeroPadToByte()
		var pixelReader = YCbCrHeaderTests.BitReader(bytes: pixel.take())
		_ = pixelReader.read(6)
		#expect(pixelReader.read(2) == 1)

		var jpeg = BitWriter()
		FrameAssembly.writeFrameHeader(
			colorMode: .ycbcr(subsampling: .none),
			loopFilter: .init(gaborish: false, epfIterations: 2), writer: &jpeg)
		jpeg.zeroPadToByte()
		var jpegReader = YCbCrHeaderTests.BitReader(bytes: jpeg.take())
		_ = jpegReader.read(6 + 8 + 1 + 6)
		#expect(jpegReader.read(2) == 0)
	}

	@Test
	func serialConcurrentRGBAndGrayUseTheSameCodedGrid() async throws {
		#expect(try DistanceParams(distance: Float(10).nextDown).upsampling == 1)
		#expect(try DistanceParams(distance: 10).upsampling == 2)
		#expect(try DistanceParams(distance: Float(10).nextUp).upsampling == 2)

		for (width, height, channels, gray) in [
			(513, 257, 4, false), (257, 513, 3, true),
		] {
			var samples = [UInt8](repeating: 0, count: width * height * channels)
			for y in 0..<height {
				for x in 0..<width {
					let offset = (y * width + x) * channels
					let grayValue = UInt8((x * 17 + y * 29) % 256)
					samples[offset] =
						gray ? grayValue : UInt8((x * 37 + y * 11) % 256)
					samples[offset + 1] =
						gray ? grayValue : UInt8((x * 3 + y * 29) % 256)
					samples[offset + 2] =
						gray ? grayValue : UInt8((x * 17 + y * 7) % 256)
					if channels == 4 {
						samples[offset + 3] = UInt8((x + y) % 256)
					}
				}
			}
			let image = try ImageBuffer(
				width: width, height: height, samples: samples, channels: channels)
			let params = try DistanceParams(distance: 10)
			let pixelFrame = Encoder.preparePixelFrame(
				stripeAt: Encoder.linearizingStripeSource(image),
				width: width, height: height, params: params)
			let codedWidth = (width + 1) / 2
			let codedHeight = (height + 1) / 2
			#expect(pixelFrame.dim.width == codedWidth)
			#expect(pixelFrame.dim.height == codedHeight)
			#expect(pixelFrame.dim.groupCount == 2)

			let global = pixelFrame.xybAt(
				Rect(x0: 0, y0: 0, width: codedWidth, height: codedHeight))
			let groupRects =
				codedWidth > Geometry.groupDim
				? [
					Rect(
						x0: 0, y0: 0, width: Geometry.groupDim,
						height: codedHeight),
					Rect(
						x0: Geometry.groupDim, y0: 0,
						width: codedWidth - Geometry.groupDim,
						height: codedHeight),
				]
				: [
					Rect(
						x0: 0, y0: 0, width: codedWidth,
						height: Geometry.groupDim),
					Rect(
						x0: 0, y0: Geometry.groupDim, width: codedWidth,
						height: codedHeight - Geometry.groupDim),
				]
			for rect in groupRects {
				let group = pixelFrame.xybAt(rect)
				for channel in 0..<3 {
					if let index = (0..<(group.width * group.height)).first(
						where: { index in
							let x = index % group.width
							let y = index / group.width
							return group.planes[channel][index]
								!= global.planes[channel][
									(rect.y0 + y) * global.width
										+ rect.x0 + x]
						})
					{
						let x = index % group.width
						let y = index / group.width
						let globalValue = global.planes[channel][
							(rect.y0 + y) * global.width + rect.x0 + x]
						Issue.record(
							"group slice mismatch at (\(rect.x0 + x), \(rect.y0 + y), c\(channel)): \(group.planes[channel][index]) vs \(globalValue)"
						)
					}
				}
			}
			let groupComputes = (0..<pixelFrame.dim.groupCount).map { index in
				Encoder.computeACGroup(
					xybAt: pixelFrame.xybAt, dim: pixelFrame.dim,
					groupX: index % pixelFrame.dim.widthInGroups,
					groupY: index / pixelFrame.dim.widthInGroups, params: params
				)
			}
			#expect(
				groupComputes.reduce(0) {
					$0 + $1.widthInBlocks * $1.heightInBlocks
				} == pixelFrame.dim.widthInBlocks * pixelFrame.dim.heightInBlocks)
			if width == 513 {
				let decisions = try SwiftSemanticEncoding.encode(
					image, distance: 10
				).decisions
				guard let dump = try? SemanticDump(swiftDecisions: decisions) else {
					Issue.record(
						"semantic dump rejected the coded pixel groups")
					continue
				}
				#expect(dump.fields["frame.groups"] == .integers([2]))
				#expect(dump.fields["frame.dc_groups"] == .integers([1]))
				if case .integers(let quantField)? = dump.fields["quant_field.raw"]
				{
					#expect(quantField.count == 561)
				} else {
					Issue.record("missing coded quant-field traversal")
				}
			}

			for optimizeCodes in [false, true] {
				let serial = try Encoder.encode(
					image, distance: 10, optimizeCodes: optimizeCodes)
				let concurrent = try await Encoder.encodeConcurrently(
					image, distance: 10, optimizeCodes: optimizeCodes)
				#expect(serial == concurrent)
			}
		}
	}
}
